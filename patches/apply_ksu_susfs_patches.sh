#!/usr/bin/env bash
# Chimera Mk9 — curated patch stack applied in CI onto the ExyHyperBrick base tree.
# Run from the kernel repo root (working-directory: kernel). Idempotent: every
# block is grep-guarded so `force_repatch=false` reruns are safe no-ops.
#
# Order matters:
#   1. SUSFS core (fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h)
#   2. SUSFS sus_path hooks (fs/namei.c)
#   3. SUSFS sus_map hook (fs/proc/base.c)
#   4. KSU non-kprobe hooks (fs/open.c, fs/exec.c, kernel/sys.c)
#   5. Kconfig / Makefile glue
#
set -Eeuo pipefail
LOG="${ABS_LOG:-.}/patch-apply.log"
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. SUSFS core — pull from Chimera Mk8 reference remote (already fetched as
#    `chimera/chimera-mk8` by the "Fetch Chimera Mk8 reference" workflow step),
#    NOT from upstream simonpunk/susfs4ksu (5.10-oriented). We extract the three
#    core files with `git show` rather than merging the branch.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [1/5] SUSFS core files ==="
mkdir -p fs include/linux
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
  if git cat-file -e "chimera/chimera-mk8:$f" 2>/dev/null; then
    if [[ -f "$f" && "${FORCE_REPATCH:-false}" != "true" ]] && grep -q "SUSFS_VERSION" "$f" 2>/dev/null; then
      log "SKIP (present): $f"
    else
      git show "chimera/chimera-mk8:$f" > "$f"
      log "PULLED: $f from chimera/chimera-mk8"
    fi
  else
    log "WARN: $f not found on chimera/chimera-mk8 — leaving unset, CONFIG_KSU_SUSFS build will fail until resolved"
  fi
done

# fs/Makefile glue for susfs.o
if ! grep -q 'susfs.o' fs/Makefile; then
  printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile
  log "PATCHED: fs/Makefile (+susfs.o)"
else
  log "SKIP (present): fs/Makefile susfs.o glue"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. SUSFS sus_path — fs/namei.c
#    4.9.337 topology (per audit): lookup_dcache(), __lookup_hash(),
#    lookup_fast() [RCU + non-RCU], lookup_slow(), lookup_open().
#    walk_component() is intentionally NOT hooked (see task spec / notes below).
# ─────────────────────────────────────────────────────────────────────────────
log "=== [2/5] fs/namei.c sus_path hooks ==="
if ! grep -q 'CHIMERA_MK9: SUSFS sus_path' fs/namei.c; then
python3 - << 'PYEOF'
import re, sys
path = "fs/namei.c"
with open(path) as f:
    src = f.read()

# --- includes ---
if '#include <linux/susfs_def.h>' not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n#include <linux/susfs_def.h>\nextern bool susfs_is_inode_sus_path(struct inode *inode);\nextern struct qstr susfs_fake_qstr_name;\n#endif\n/* CHIMERA_MK9: SUSFS sus_path hooks below */',
        1,
    )

# --- a) lookup_dcache(): suppress dcache hit for sus_path inode ---
anchor_a = (
    "static struct dentry *lookup_dcache(const struct qstr *name,\n"
    "\t\t\t\t     struct dentry *dir,\n"
    "\t\t\t\t     unsigned int flags)\n"
    "{\n"
    "\tstruct dentry *dentry = d_lookup(dir, name);\n"
)
insert_a = (
    anchor_a +
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\tif (dentry && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\td_lookup_done(dentry);\n"
    "\t\tdput(dentry);\n"
    "\t\tdentry = NULL;\n"
    "\t}\n"
    "#endif\n"
)
if anchor_a in src and insert_a not in src:
    src = src.replace(anchor_a, insert_a, 1)

# --- b) __lookup_hash(): substitute susfs_fake_qstr_name on new-dentry alloc ---
anchor_b = (
    "\tdentry = lookup_dcache(name, base, flags);\n"
    "\tif (dentry)\n"
    "\t\treturn dentry;\n\n"
    "\t/*\n"
    "\t * Don't bother with __d_lookup: callers before us can't have\n"
)
insert_b = (
    "\tdentry = lookup_dcache(name, base, flags);\n"
    "\tif (dentry)\n"
    "\t\treturn dentry;\n\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\t{\n"
    "\t\tstruct dentry *tmp = d_alloc(base, name);\n"
    "\t\tif (tmp && tmp->d_inode && susfs_is_inode_sus_path(tmp->d_inode)) {\n"
    "\t\t\tdput(tmp);\n"
    "\t\t\ttmp = d_alloc(base, &susfs_fake_qstr_name);\n"
    "\t\t\treturn tmp;\n"
    "\t\t}\n"
    "\t\tif (tmp)\n"
    "\t\t\tdput(tmp);\n"
    "\t}\n"
    "#endif\n"
    "\t/*\n"
    "\t * Don't bother with __d_lookup: callers before us can't have\n"
)
if anchor_b in src and insert_b not in src:
    src = src.replace(anchor_b, insert_b, 1)

# --- c) lookup_fast(): RCU + non-RCU branches ---
anchor_c_rcu = (
    "\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n"
    "\t\tif (unlikely(!dentry)) {\n"
)
insert_c_rcu = (
    "\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\t\tif (dentry && (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST)) &&\n"
    "\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\t\tdentry = NULL;\n"
    "\t\t}\n"
    "#endif\n"
    "\t\tif (unlikely(!dentry)) {\n"
)
if anchor_c_rcu in src and insert_c_rcu not in src:
    src = src.replace(anchor_c_rcu, insert_c_rcu, 1)

anchor_c_nonrcu = (
    "\t\tdentry = __d_lookup(parent, &nd->last);\n"
    "\t\tif (unlikely(!dentry))\n"
    "\t\t\tgoto need_lookup;\n"
)
insert_c_nonrcu = (
    "\t\tdentry = __d_lookup(parent, &nd->last);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\t\tif (dentry && (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST)) &&\n"
    "\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\t\td_lookup_done(dentry);\n"
    "\t\t\tdput(dentry);\n"
    "\t\t\tdentry = NULL;\n"
    "\t\t}\n"
    "#endif\n"
    "\t\tif (unlikely(!dentry))\n"
    "\t\t\tgoto need_lookup;\n"
)
if anchor_c_nonrcu in src and insert_c_nonrcu not in src:
    src = src.replace(anchor_c_nonrcu, insert_c_nonrcu, 1)

# --- d) lookup_slow(): substitute/deny on real-fs lookup ---
anchor_d = (
    "\tdentry = d_alloc_parallel(dir, name, &wq);\n"
    "\tif (IS_ERR(dentry))\n"
    "\t\treturn dentry;\n"
    "\tif (unlikely(!d_in_lookup(dentry)))\n"
    "\t\treturn dentry;\n\n"
    "\told = dir->i_op->lookup(dir, dentry, flags);\n"
)
insert_d = (
    "\tdentry = d_alloc_parallel(dir, name, &wq);\n"
    "\tif (IS_ERR(dentry))\n"
    "\t\treturn dentry;\n"
    "\tif (unlikely(!d_in_lookup(dentry)))\n"
    "\t\treturn dentry;\n\n"
    "\told = dir->i_op->lookup(dir, dentry, flags);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\tif (!old && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\td_lookup_done(dentry);\n"
    "\t\tdput(dentry);\n"
    "\t\treturn ERR_PTR(-ENOENT);\n"
    "\t}\n"
    "#endif\n"
)
if anchor_d in src and insert_d not in src:
    src = src.replace(anchor_d, insert_d, 1)

# --- e) lookup_open(): open-last state filtering ---
anchor_e = (
    "\tif (!dentry->d_inode)\n"
    "\t\tgoto out_no_open;\n\n"
    "\tif ((~open_flag & O_CREAT) || !dir->d_inode->i_op->atomic_open)\n"
    "\t\tgoto no_open;\n"
)
insert_e = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\tif ((nd->state & ND_STATE_OPEN_LAST) && dentry->d_inode &&\n"
    "\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\tdput(dentry);\n"
    "\t\tdentry = d_alloc(dir, &susfs_fake_qstr_name);\n"
    "\t\tif (!dentry)\n"
    "\t\t\treturn ERR_PTR(-ENOMEM);\n"
    "\t\tgoto out_no_open;\n"
    "\t}\n"
    "#endif\n"
    "\tif (!dentry->d_inode)\n"
    "\t\tgoto out_no_open;\n\n"
    "\tif ((~open_flag & O_CREAT) || !dir->d_inode->i_op->atomic_open)\n"
    "\t\tgoto no_open;\n"
)
if anchor_e in src and insert_e not in src:
    src = src.replace(anchor_e, insert_e, 1)

with open(path, "w") as f:
    f.write(src)
print("fs/namei.c: sus_path hooks applied (best-effort anchor match — see patch-apply.log)")
PYEOF
  log "PATCHED (or attempted): fs/namei.c sus_path hooks"
else
  log "SKIP (present): fs/namei.c sus_path hooks"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. SUSFS sus_map — fs/proc/base.c, inside __mem_open()
# ─────────────────────────────────────────────────────────────────────────────
log "=== [3/5] fs/proc/base.c sus_map hook ==="
if ! grep -q 'CHIMERA_MK9: SUSFS sus_map' fs/proc/base.c; then
python3 - << 'PYEOF'
path = "fs/proc/base.c"
with open(path) as f:
    src = f.read()

if '#include <linux/susfs_def.h>' not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\nextern bool SUSFS_IS_INODE_SUS_MAP(struct inode *inode);\n#endif\n/* CHIMERA_MK9: SUSFS sus_map hook below */',
        1,
    )

anchor = (
    "static int __mem_open(struct inode *inode, struct file *file, unsigned int mode)\n"
    "{\n"
    "\tstruct pid *pid = proc_pid(inode);\n"
    "\tstruct mm_struct *mm = proc_mem_open(inode, mode);\n\n"
    "\tif (IS_ERR(mm))\n"
    "\t\treturn PTR_ERR(mm);\n\n"
    "\tfile->private_data = mm;\n"
)
insert = (
    "static int __mem_open(struct inode *inode, struct file *file, unsigned int mode)\n"
    "{\n"
    "\tstruct pid *pid = proc_pid(inode);\n"
    "\tstruct mm_struct *mm = proc_mem_open(inode, mode);\n\n"
    "\tif (IS_ERR(mm))\n"
    "\t\treturn PTR_ERR(mm);\n\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n"
    "\t\tmmput(mm);\n"
    "\t\treturn -EACCES;\n"
    "\t}\n"
    "#endif\n"
    "\tfile->private_data = mm;\n"
)
if anchor in src and insert not in src:
    src = src.replace(anchor, insert, 1)
else:
    print("WARN: __mem_open() anchor not matched verbatim — inspect fs/proc/base.c manually", file=__import__('sys').stderr)

with open(path, "w") as f:
    f.write(src)
PYEOF
  log "PATCHED (or attempted): fs/proc/base.c __mem_open sus_map guard"
else
  log "SKIP (present): fs/proc/base.c sus_map hook"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. KernelSU-Next non-kprobe hooks — fs/open.c, fs/exec.c, kernel/sys.c
# ─────────────────────────────────────────────────────────────────────────────
log "=== [4/5] KSU-Next non-kprobe call-site hooks ==="

# 4a. fs/open.c — faccessat
if ! grep -q 'ksu_handle_faccessat' fs/open.c; then
python3 - << 'PYEOF'
path = "fs/open.c"
with open(path) as f:
    src = f.read()

if '#include <linux/ksu.h>' not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"\n#ifdef CONFIG_KSU\n#include <linux/ksu.h>\n#endif',
        1,
    )

anchor = (
    "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
    "{\n"
)
insert = (
    anchor +
    "#ifdef CONFIG_KSU\n"
    "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
    "#endif\n"
)
if anchor in src and insert not in src:
    src = src.replace(anchor, insert, 1)
else:
    print("WARN: faccessat anchor not matched — check for (int, dfd, ...) macro form drift")

with open(path, "w") as f:
    f.write(src)
PYEOF
  log "PATCHED: fs/open.c faccessat KSU hook"
else
  log "SKIP (present): fs/open.c faccessat hook"
fi

# 4b. fs/exec.c — do_execveat_common, before search_binary_handler()
if ! grep -q 'ksu_handle_do_execveat_common' fs/exec.c; then
python3 - << 'PYEOF'
path = "fs/exec.c"
with open(path) as f:
    src = f.read()

if '#include <linux/ksu.h>' not in src:
    src = src.replace(
        '#include <linux/kmod.h>',
        '#include <linux/kmod.h>\n#ifdef CONFIG_KSU\n#include <linux/ksu.h>\n#endif',
        1,
    )

anchor = "\tretval = search_binary_handler(bprm);\n"
insert = (
    "#ifdef CONFIG_KSU\n"
    "\tksu_handle_do_execveat_common(&fd, &filename, &argv, &envp, &flags);\n"
    "#endif\n"
    "\tretval = search_binary_handler(bprm);\n"
)
if anchor in src and insert not in src:
    src = src.replace(anchor, insert, 1)
else:
    print("WARN: search_binary_handler() call-site anchor not matched — inspect do_execveat_common() manually")

with open(path, "w") as f:
    f.write(src)
PYEOF
  log "PATCHED: fs/exec.c do_execveat_common KSU hook"
else
  log "SKIP (present): fs/exec.c KSU hook"
fi

# 4c. kernel/sys.c — setresuid, after security_task_fix_setuid(), before commit_creds()
if ! grep -q 'ksu_handle_setresuid' kernel/sys.c; then
python3 - << 'PYEOF'
path = "kernel/sys.c"
with open(path) as f:
    src = f.read()

if '#include <linux/ksu.h>' not in src:
    src = src.replace(
        '#include <linux/security.h>',
        '#include <linux/security.h>\n#ifdef CONFIG_KSU\n#include <linux/ksu.h>\n#endif',
        1,
    )

anchor = (
    "\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n"
    "\tif (retval < 0)\n"
    "\t\tgoto error;\n\n"
    "\treturn commit_creds(new);\n"
)
insert = (
    "\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n"
    "\tif (retval < 0)\n"
    "\t\tgoto error;\n\n"
    "#ifdef CONFIG_KSU\n"
    "\tif (ksu_handle_setresuid(new, old) < 0)\n"
    "\t\tgoto error;\n"
    "#endif\n"
    "\treturn commit_creds(new);\n"
)
if anchor in src and insert not in src:
    src = src.replace(anchor, insert, 1)
else:
    print("WARN: setresuid commit_creds() anchor not matched — this repo's whitespace/goto"
          " layout around commit_creds(new) may differ; inspect SYSCALL_DEFINE3(setresuid) manually")

with open(path, "w") as f:
    f.write(src)
PYEOF
  log "PATCHED: kernel/sys.c setresuid KSU root-grant hook"
else
  log "SKIP (present): kernel/sys.c KSU hook"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Kconfig / Makefile glue for CONFIG_KSU + drivers/kernelsu
# ─────────────────────────────────────────────────────────────────────────────
log "=== [5/5] Kconfig/Makefile glue ==="
if [[ -d KernelSU-Next/kernel ]]; then
  if ! grep -q 'source "KernelSU-Next/kernel/Kconfig"' drivers/Kconfig 2>/dev/null; then
    sed -i '/^endmenu/i source "KernelSU-Next/kernel/Kconfig"' drivers/Kconfig
    log "PATCHED: drivers/Kconfig (+KernelSU-Next source line)"
  fi
  if ! grep -q 'KernelSU-Next/kernel' drivers/Makefile 2>/dev/null; then
    echo 'obj-$(CONFIG_KSU) += ../KernelSU-Next/kernel/' >> drivers/Makefile
    log "PATCHED: drivers/Makefile (+KernelSU-Next obj glue)"
  fi

  # ── ksu.h header search path ────────────────────────────────────────────
  # Our call-site patches (fs/open.c, fs/exec.c, kernel/sys.c) do
  # `#include <linux/ksu.h>`. That only resolves if some -I on the global
  # compile line points at a directory that itself CONTAINS a `linux/`
  # subdirectory holding ksu.h. Different KSU-Next forks/revisions ship this
  # header in different places (kernel/include/linux/ksu.h in some, bare
  # uapi/ksu.h with NO linux/ nesting in others — confirmed: this repo's
  # pinned KSU-Next revision ships KernelSU-Next/uapi/ksu.h, not nested under
  # linux/ at all). Rather than guess at upstream layout with a dirname
  # heuristic, build a small deterministic shim: copy the real header into a
  # synthetic linux/ directory we control, and point one unambiguous -I at
  # that shim. This resolves the #include correctly regardless of how
  # KernelSU-Next organises its own tree.
  KSU_HDR_PATH=$(find KernelSU-Next -type f -name 'ksu.h' 2>/dev/null | head -1 || true)
  if [[ -z "$KSU_HDR_PATH" ]]; then
    log "FATAL: ksu.h not found anywhere under KernelSU-Next/ — submodule checkout is incomplete or KSU-Next revision doesn't ship this header; aborting"
    exit 1
  fi
  SHIM_DIR=".chimera_ksu_shim"
  mkdir -p "$SHIM_DIR/linux"
  cp "$KSU_HDR_PATH" "$SHIM_DIR/linux/ksu.h"
  log "Shimmed $KSU_HDR_PATH -> $SHIM_DIR/linux/ksu.h"

  if ! grep -q 'KSU_INCLUDE_DIR_MARKER' Makefile 2>/dev/null; then
    if grep -q '^LINUXINCLUDE' Makefile; then
      # Track the LINUXINCLUDE assignment across backslash line-continuations
      # and insert our -I only once the continuation actually ends, so we
      # never split a multi-line variable assignment mid-way (that produced
      # "recipe commences before first target" in a prior run).
      awk -v inc="$SHIM_DIR" '
        {
          print
          if ($0 ~ /^LINUXINCLUDE/) { inblock = 1 }
          if (inblock && $0 !~ /\\[[:space:]]*$/) {
            print "LINUXINCLUDE += -I$(srctree)/" inc " # KSU_INCLUDE_DIR_MARKER"
            inblock = 0
          }
        }
      ' Makefile > Makefile.chimera.tmp && mv Makefile.chimera.tmp Makefile
      log "PATCHED: Makefile (+LINUXINCLUDE -I$SHIM_DIR after end of continuation block)"
    else
      log "FATAL: could not find LINUXINCLUDE in top-level Makefile — inspect manually, KSU headers will not resolve"
      exit 1
    fi
  else
    log "SKIP (present): Makefile KSU include path glue"
  fi

  # Sanity-check the result immediately rather than waiting for the compile
  # step 20 minutes later: LINUXINCLUDE must now contain our shim, and make
  # must still be able to parse the Makefile at all.
  if ! grep -q "KSU_INCLUDE_DIR_MARKER" Makefile; then
    log "FATAL: Makefile patch did not take — KSU_INCLUDE_DIR_MARKER absent after edit"
    exit 1
  fi
  if ! make -n -f Makefile ARCH=arm64 help >/dev/null 2>"$ABS_LOG/makefile-sanity.log"; then
    log "FATAL: top-level Makefile fails to parse after KSU include patch — see $ABS_LOG/makefile-sanity.log"
    cat "$ABS_LOG/makefile-sanity.log" | tee -a "$LOG"
    exit 1
  fi
  log "OK: Makefile parses cleanly after KSU include-path glue"
else
  log "FATAL: KernelSU-Next/kernel submodule not present at glue time — run submodule init first"
  exit 1
fi

log "=== Patch stack application complete ==="
