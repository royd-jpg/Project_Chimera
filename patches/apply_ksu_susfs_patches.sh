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
  printf '
obj-$(CONFIG_KSU_SUSFS) += susfs.o
' >> fs/Makefile
  log "PATCHED: fs/Makefile (+susfs.o)"
else
  log "SKIP (present): fs/Makefile susfs.o glue"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. SUSFS sus_path — fs/namei.c (regex-based function patching)
# ─────────────────────────────────────────────────────────────────────────────
log "=== [2/5] fs/namei.c sus_path hooks ==="
if ! grep -q 'CHIMERA_MK9: SUSFS sus_path' fs/namei.c; then
python3 - << 'PYEOF'
import re, sys

path = "fs/namei.c"
src = open(path).read()

def patch_includes(src: str) -> str:
    if "#include <linux/susfs_def.h>" in src:
        return src
    return src.replace(
        '#include "internal.h"',
        '#include "internal.h"
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
'
        '#include <linux/susfs_def.h>
'
        'extern bool susfs_is_inode_sus_path(struct inode *inode);
'
        'extern struct qstr susfs_fake_qstr_name;
'
        '#endif
/* CHIMERA_MK9: SUSFS sus_path hooks below */',
        1,
    )

def find_function(src: str, name: str) -> tuple[int,int]:
    m = re.search(rf"statics+.*?s+{name}s*([^)]*)s*{{", src)
    if not m:
        print(f"WARN: function {name} not found", file=sys.stderr)
        return None, None
    start = m.start()
    depth = 0
    i = start
    end = None
    while i < len(src):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    if end is None:
        print(f"WARN: function {name} end not found", file=sys.stderr)
    return start, end

def patch_lookup_dcache(src: str) -> str:
    start, end = find_function(src, "lookup_dcache")
    if start is None:
        return src
    body = src[start:end]
    if "CHIMERA_MK9: SUSFS lookup_dcache" in body:
        return src
    pattern = r"(structs+dentrys**s*dentrys*=s*d_lookup(dir,s*name);s*)"
    def repl(m):
        chunk = m.group(1)
        return chunk + (
            "
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\tif (dentry && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
"
            "\t\td_lookup_done(dentry);
"
            "\t\tdput(dentry);
"
            "\t\tdentry = NULL;
"
            "\t}
"
            "#endif
"
        )
    new_body, n = re.subn(pattern, repl, body, count=1)
    if n == 0:
        print("WARN: lookup_dcache anchor not matched", file=sys.stderr)
        return src
    new_body = new_body.replace(
        "static struct dentry *lookup_dcache",
        "/* CHIMERA_MK9: SUSFS lookup_dcache */
static struct dentry *lookup_dcache",
        1,
    )
    return src[:start] + new_body + src[end:]

def patch___lookup_hash(src: str) -> str:
    start, end = find_function(src, "__lookup_hash")
    if start is None:
        return src
    body = src[start:end]
    if "CHIMERA_MK9: SUSFS __lookup_hash" in body:
        return src
    pattern = r"(dentrys*=s*lookup_dcache(name,s*base,s*flags);s*ifs*(dentry)s*returns+dentry;s*)"
    def repl(m):
        chunk = m.group(1)
        return chunk + (
            "
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\t{
"
            "\t\tstruct dentry *tmp = d_alloc(base, name);
"
            "\t\tif (tmp && tmp->d_inode && susfs_is_inode_sus_path(tmp->d_inode)) {
"
            "\t\t\tdput(tmp);
"
            "\t\t\ttmp = d_alloc(base, &susfs_fake_qstr_name);
"
            "\t\t\treturn tmp;
"
            "\t\t}
"
            "\t\tif (tmp)
"
            "\t\t\tdput(tmp);
"
            "\t}
"
            "#endif
"
        )
    new_body, n = re.subn(pattern, repl, body, count=1, flags=re.DOTALL)
    if n == 0:
        print("WARN: __lookup_hash anchor not matched", file=sys.stderr)
        return src
    new_body = new_body.replace(
        "static struct dentry *__lookup_hash",
        "/* CHIMERA_MK9: SUSFS __lookup_hash */
static struct dentry *__lookup_hash",
        1,
    )
    return src[:start] + new_body + src[end:]

def patch_lookup_fast(src: str) -> str:
    start, end = find_function(src, "lookup_fast")
    if start is None:
        return src
    body = src[start:end]
    if "CHIMERA_MK9: SUSFS lookup_fast" in body:
        return src
    # RCU branch
    pattern_rcu = r"(\tdentrys*=s*__d_lookup_rcu(parent,s*&nd->last,s*&seq);s*)"
    def repl_rcu(m):
        chunk = m.group(1)
        return chunk + (
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\t\tif (dentry && (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST)) &&
"
            "\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
"
            "\t\t\tdentry = NULL;
"
            "\t\t}
"
            "#endif
"
        )
    body, n1 = re.subn(pattern_rcu, repl_rcu, body, count=1)
    # Non-RCU branch
    pattern_non = r"(\tdentrys*=s*__d_lookup(parent,s*&nd->last);s*)"
    def repl_non(m):
        chunk = m.group(1)
        return chunk + (
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\t\tif (dentry && (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST)) &&
"
            "\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
"
            "\t\t\td_lookup_done(dentry);
"
            "\t\t\tdput(dentry);
"
            "\t\t\tdentry = NULL;
"
            "\t\t}
"
            "#endif
"
        )
    body, n2 = re.subn(pattern_non, repl_non, body, count=1)
    if n1 == 0:
        print("WARN: lookup_fast RCU anchor not matched", file=sys.stderr)
    if n2 == 0:
        print("WARN: lookup_fast non-RCU anchor not matched", file=sys.stderr)
    if n1 == 0 and n2 == 0:
        return src
    body = body.replace(
        "static int lookup_fast",
        "/* CHIMERA_MK9: SUSFS lookup_fast */
static int lookup_fast",
        1,
    )
    return src[:start] + body + src[end:]

def patch_lookup_slow(src: str) -> str:
    start, end = find_function(src, "lookup_slow")
    if start is None:
        return src
    body = src[start:end]
    if "CHIMERA_MK9: SUSFS lookup_slow" in body:
        return src
    pattern = r"(\tdentrys*=s*d_alloc_parallel(dir,s*name,s*&wq);s*[^}]*?olds*=s*dir->i_op->lookup(dir,s*dentry,s*flags);s*)"
    def repl(m):
        chunk = m.group(1)
        return chunk + (
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\tif (!old && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {
"
            "\t\td_lookup_done(dentry);
"
            "\t\tdput(dentry);
"
            "\t\treturn ERR_PTR(-ENOENT);
"
            "\t}
"
            "#endif
"
        )
    new_body, n = re.subn(pattern, repl, body, count=1, flags=re.DOTALL)
    if n == 0:
        print("WARN: lookup_slow anchor not matched", file=sys.stderr)
        return src
    new_body = new_body.replace(
        "static struct dentry *lookup_slow",
        "/* CHIMERA_MK9: SUSFS lookup_slow */
static struct dentry *lookup_slow",
        1,
    )
    return src[:start] + new_body + src[end:]

def patch_lookup_open(src: str) -> str:
    start, end = find_function(src, "lookup_open")
    if start is None:
        return src
    body = src[start:end]
    if "CHIMERA_MK9: SUSFS lookup_open" in body:
        return src
    pattern = r"(\tifs*(!dentry->d_inode)s*
s*\t\tgotos+out_no_open;s*)"
    def repl(m):
        chunk = m.group(1)
        return (
            "#ifdef CONFIG_KSU_SUSFS_SUS_PATH
"
            "\tif ((nd->state & ND_STATE_OPEN_LAST) && dentry->d_inode &&
"
            "\t    susfs_is_inode_sus_path(dentry->d_inode)) {
"
            "\t\tdput(dentry);
"
            "\t\tdentry = d_alloc(dir, &susfs_fake_qstr_name);
"
            "\t\tif (!dentry)
"
            "\t\t\treturn ERR_PTR(-ENOMEM);
"
            "\t\tgoto out_no_open;
"
            "\t}
"
            "#endif
"
        ) + chunk
    new_body, n = re.subn(pattern, repl, body, count=1)
    if n == 0:
        print("WARN: lookup_open anchor not matched", file=sys.stderr)
        return src
    new_body = new_body.replace(
        "static int lookup_open",
        "/* CHIMERA_MK9: SUSFS lookup_open */
static int lookup_open",
        1,
    )
    return src[:start] + new_body + src[end:]

src = patch_includes(src)
src = patch_lookup_dcache(src)
src = patch___lookup_hash(src)
src = patch_lookup_fast(src)
src = patch_lookup_slow(src)
src = patch_lookup_open(src)

open(path, "w").write(src)
print("fs/namei.c: sus_path hooks applied (regex-based; see patch-apply.log)")
PYEOF
  log "PATCHED (regex-based): fs/namei.c sus_path hooks"
else
  log "SKIP (present): fs/namei.c sus_path hooks"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. SUSFS sus_map — fs/proc/base.c, inside __mem_open() (regex-based)
# ─────────────────────────────────────────────────────────────────────────────
log "=== [3/5] fs/proc/base.c sus_map hook ==="
if ! grep -q 'CHIMERA_MK9: SUSFS sus_map' fs/proc/base.c; then
python3 - << 'PYEOF'
import re, sys

path = "fs/proc/base.c"
src = open(path).read()

if "#include <linux/susfs_def.h>" not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
'
        '#include <linux/susfs_def.h>
'
        'extern bool SUSFS_IS_INODE_SUS_MAP(struct inode *inode);
'
        '#endif
/* CHIMERA_MK9: SUSFS sus_map hook below */',
        1,
    )

m = re.search(r"statics+ints+__mem_opens*([^)]*)s*{", src)
if not m:
    print("WARN: __mem_open() not found in fs/proc/base.c", file=sys.stderr)
else:
    start = m.start()
    depth = 0
    i = start
    end = None
    while i < len(src):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    if end is None:
        print("WARN: __mem_open() end not found", file=sys.stderr)
    else:
        body = src[start:end]
        if "CHIMERA_MK9: SUSFS __mem_open" not in body:
            pattern = r"(\tifs*(IS_ERR(mm))s*
s*\t\treturns+PTR_ERR(mm);s*)"
            def repl(m2):
                chunk = m2.group(1)
                return (
                    chunk +
                    "
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
"
                    "\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {
"
                    "\t\tmmput(mm);
"
                    "\t\treturn -EACCES;
"
                    "\t}
"
                    "#endif
"
                )
            new_body, n = re.subn(pattern, repl, body, count=1)
            if n == 0:
                print("WARN: __mem_open() IS_ERR(mm) anchor not matched", file=sys.stderr)
            else:
                new_body = new_body.replace(
                    "static int __mem_open",
                    "/* CHIMERA_MK9: SUSFS __mem_open */
static int __mem_open",
                    1,
                )
                src = src[:start] + new_body + src[end:]

open(path, "w").write(src)
PYEOF
  log "PATCHED (regex-based): fs/proc/base.c __mem_open sus_map guard"
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
import re, sys
path = "fs/open.c"
src = open(path).read()

if "#include <linux/ksu.h>" not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"
#ifdef CONFIG_KSU
#include <linux/ksu.h>
#endif',
        1,
    )

pattern = r"(SYSCALL_DEFINE3s*(s*faccessats*,s*ints*,s*dfds*,[^)]*)s*
{s*
)"
def repl(m):
    anchor = m.group(1)
    return anchor + (
        "#ifdef CONFIG_KSU
"
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);
"
        "#endif
"
    )

new_src, n = re.subn(pattern, repl, src, count=1)
if n == 0:
    print("WARN: faccessat SYSCALL_DEFINE3 anchor not matched", file=sys.stderr)
else:
    src = new_src

open(path, "w").write(src)
PYEOF
  log "PATCHED: fs/open.c faccessat KSU hook"
else
  log "SKIP (present): fs/open.c faccessat hook"
fi

# 4b. fs/exec.c — do_execveat_common, before search_binary_handler()
if ! grep -q 'ksu_handle_do_execveat_common' fs/exec.c; then
python3 - << 'PYEOF'
import re, sys
path = "fs/exec.c"
src = open(path).read()

if "#include <linux/ksu.h>" not in src:
    src = src.replace(
        '#include <linux/kmod.h>',
        '#include <linux/kmod.h>
#ifdef CONFIG_KSU
#include <linux/ksu.h>
#endif',
        1,
    )

pattern = r"(\tretvals*=s*search_binary_handler(bprm);s*)"
def repl(m):
    return (
        "#ifdef CONFIG_KSU
"
        "\tksu_handle_do_execveat_common(&fd, &filename, &argv, &envp, &flags);
"
        "#endif
"
    ) + m.group(1)

new_src, n = re.subn(pattern, repl, src, count=1)
if n == 0:
    print("WARN: search_binary_handler() call-site anchor not matched", file=sys.stderr)
else:
    src = new_src

open(path, "w").write(src)
PYEOF
  log "PATCHED: fs/exec.c do_execveat_common KSU hook"
else
  log "SKIP (present): fs/exec.c KSU hook"
fi

# 4c. kernel/sys.c — setresuid, after security_task_fix_setuid(), before commit_creds()
if ! grep -q 'ksu_handle_setresuid' kernel/sys.c; then
python3 - << 'PYEOF'
import re, sys
path = "kernel/sys.c"
src = open(path).read()

if "#include <linux/ksu.h>" not in src:
    src = src.replace(
        '#include <linux/security.h>',
        '#include <linux/security.h>
#ifdef CONFIG_KSU
#include <linux/ksu.h>
#endif',
        1,
    )

pattern = (
    r"(\tretvals*=s*security_task_fix_setuid(new,s*old,s*LSM_SETID_RES);s*"
    r"\tifs*(retvals*<s*0)s*
s*\t\tgotos+error;s*
s*
s*\treturns+commit_creds(new);s*)"
)
def repl(m):
    chunk = m.group(1)
    return (
        "\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);
"
        "\tif (retval < 0)
"
        "\t\tgoto error;

"
        "#ifdef CONFIG_KSU
"
        "\tif (ksu_handle_setresuid(new, old) < 0)
"
        "\t\tgoto error;
"
        "#endif
"
        "\treturn commit_creds(new);
"
    )

new_src, n = re.subn(pattern, repl, src, count=1)
if n == 0:
    print("WARN: setresuid commit_creds() anchor not matched", file=sys.stderr)
else:
    src = new_src

open(path, "w").write(src)
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
else
  log "WARN: KernelSU-Next/kernel submodule not present at glue time — run submodule init first"
fi

log "=== Patch stack application complete ==="
