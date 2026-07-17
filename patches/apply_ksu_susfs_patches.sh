#!/usr/bin/env bash
# Chimera Mk9 — curated KSU-Next + SUSFS patch stack
# Applies onto the ExyHyperBrick 4.9.337 Exynos9810 BSP in CI.
# Run from the kernel repo root (working-directory: kernel). Idempotent.
#
# ── Patch order ────────────────────────────────────────────────────────────────
#   1. SUSFS core   → fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h
#   2. SUSFS namei  → fs/namei.c   (sus_path hooks: lookup_dcache / __lookup_hash /
#                                   lookup_fast RCU+nonRCU / lookup_slow / lookup_open)
#   3. SUSFS proc   → fs/proc/base.c  (__mem_open SUS_MAP guard)
#   4. KSU hooks    → fs/open.c, fs/exec.c, kernel/sys.c  (extern-based, no header needed)
#   5. Glue         → drivers/{Kconfig,Makefile}  (source + obj-y for KernelSU-Next/kernel)
#
# ── Why extern instead of #include <linux/ksu.h> ───────────────────────────────
#   KernelSU-Next/uapi/ksu.h is the *UAPI* header — it describes the userspace
#   interface (ioctls, app-profile structs, etc.) and does NOT declare the kernel-
#   internal hook functions (ksu_handle_faccessat etc.).  Those are defined in
#   KernelSU-Next/kernel/*.c and their declarations live in KernelSU-Next/kernel/ksu.h
#   or are simply exported as extern symbols.  Pulling the UAPI header into kernel
#   source causes its nested "uapi/supercall.h" relative include to break with
#   'file not found' unless you reproduce the entire directory tree.
#
#   The correct approach for non-kprobe call-site integration is direct extern
#   declarations at each call site.  The linker resolves them against the compiled
#   KernelSU-Next/kernel/ object files — exactly as any other in-tree module.
#
# ── IMPORTANT: verify hook signatures ─────────────────────────────────────────
#   Run `grep -rn 'ksu_handle_' KernelSU-Next/kernel/` in the kernel tree after
#   submodule init to confirm the actual function signatures for your fork/commit.
#   Adjust the extern declarations in sections 4a–4c if they differ.
#
set -Eeuo pipefail
LOG="${ABS_LOG:-.}/patch-apply.log"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }

FORCE="${FORCE_REPATCH:-false}"
need_patch() {
    # Returns 0 (true/proceed) if the marker is absent OR force_repatch is set
    local marker="$1" file="$2"
    if [[ "$FORCE" == "true" ]]; then return 0; fi
    grep -q "$marker" "$file" 2>/dev/null && return 1 || return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. SUSFS core files — pulled from Chimera Mk8 (already a 4.9.337 port).
#    NOT from upstream simonpunk/susfs4ksu which targets ≥5.10 and would
#    require manual namei.c adaptation.  Chimera Mk8 already has the correct
#    4.9 hook topology.  The chimera/chimera-mk8 remote is fetched by the
#    workflow step preceding this script.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [1/5] SUSFS core files (from chimera/chimera-mk8) ==="
for remote_path in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    local_path="$remote_path"
    dir=$(dirname "$local_path")
    if git cat-file -e "chimera/chimera-mk8:${remote_path}" 2>/dev/null; then
        if [[ -f "$local_path" ]] && ! need_patch "SUSFS_VERSION" "$local_path"; then
            log "SKIP (present): $local_path"
        else
            mkdir -p "$dir"
            git show "chimera/chimera-mk8:${remote_path}" > "$local_path"
            log "PULLED from chimera/chimera-mk8: $local_path"
        fi
    else
        log "FATAL: ${remote_path} not found on chimera/chimera-mk8 — cannot continue"
        exit 1
    fi
done

# Wire susfs.o into fs/Makefile
if ! grep -q 'obj-$(CONFIG_KSU_SUSFS).*susfs' fs/Makefile; then
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile
    log "PATCHED: fs/Makefile (+susfs.o)"
else
    log "SKIP (present): fs/Makefile susfs.o glue"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. SUSFS sus_path hooks — fs/namei.c
#
# Topology (Linux 4.9.337, confirmed by ExyHyperBrick audit):
#   a) lookup_dcache()   → suppress dcache hit for hidden inode
#   b) __lookup_hash()   → replace real dentry with susfs_fake_qstr_name
#   c) lookup_fast()     → suppress in both RCU and non-RCU dcache paths
#   d) lookup_slow()     → deny after real-fs lookup returns hidden inode
#   e) lookup_open()     → deny at open-last stage
#
# ND_STATE is intentionally NOT used here because:
#   • struct nameidata in ExyHyperBrick does not have a `state` field
#   • Adding it requires patching the struct definition AND every function
#     that initialises nameidata (set_nameidata, path_init), which is fragile
#   • lookup_dcache/__lookup_hash are unconditional in Chimera Mk8 too
#   • For lookup_fast we apply filtering unconditionally — slightly more
#     aggressive but safe: the hidden inode won't appear in dcache for
#     legitimate lookups once SUSFS is properly configured
# ─────────────────────────────────────────────────────────────────────────────
log "=== [2/5] fs/namei.c sus_path hooks ==="
MARKER_NAMEI="CHIMERA_MK9_SUSFS_NAMEI_PATCHED"
if need_patch "$MARKER_NAMEI" fs/namei.c; then
python3 - << 'PYEOF'
import sys, re

path = "fs/namei.c"
MARKER = "CHIMERA_MK9_SUSFS_NAMEI_PATCHED"

with open(path) as f:
    src = f.read()

if MARKER in src:
    print(f"{path}: already patched (idempotent)")
    sys.exit(0)

applied = []
missed  = []

def patch(description, old, new, src):
    if old in src and new not in src:
        applied.append(description)
        return src.replace(old, new, 1)
    elif new in src:
        applied.append(f"{description} (already present)")
        return src
    else:
        missed.append(description)
        return src

# ── Header / extern block ─────────────────────────────────────────────────────
INC_ANCHOR = '#include "internal.h"'
INC_INSERT = (
    '#include "internal.h"\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '#include <linux/susfs_def.h>\n'
    'extern bool susfs_is_inode_sus_path(struct inode *inode);\n'
    'extern struct qstr susfs_fake_qstr_name;\n'
    '#endif /* CONFIG_KSU_SUSFS_SUS_PATH */\n'
    '/* ' + MARKER + ' */'
)
src = patch("namei: header+extern block", INC_ANCHOR, INC_INSERT, src)

# ── a) lookup_dcache(): suppress dcache hit ───────────────────────────────────
# The function ends with:
#   if (dentry) { ... }   ← revalidation block
#   return dentry;
# followed immediately by the comment for lookup_real.
# We insert the sus_path check before 'return dentry'.
# Anchor uses the distinctive comment that follows to be unique.
DCACHE_OLD = (
    '\t}\n'
    '\treturn dentry;\n'
    '}\n'
    '\n'
    '/*\n'
    ' * Call i_op->lookup on the dentry.  The dentry must be negative and\n'
    ' * unhashed.\n'
)
DCACHE_NEW = (
    '\t}\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (dentry && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\td_lookup_done(dentry);\n'
    '\t\tdput(dentry);\n'
    '\t\treturn NULL;\n'
    '\t}\n'
    '#endif\n'
    '\treturn dentry;\n'
    '}\n'
    '\n'
    '/*\n'
    ' * Call i_op->lookup on the dentry.  The dentry must be negative and\n'
    ' * unhashed.\n'
)
src = patch("namei: lookup_dcache sus_path hook", DCACHE_OLD, DCACHE_NEW, src)

# ── b) __lookup_hash(): replace real dentry with fake qstr ───────────────────
# The tail of __lookup_hash in 4.9:
#   if (dentry)
#       return dentry;
#   dentry = d_alloc(base, name);
#   if (unlikely(!dentry))
#       return ERR_PTR(-ENOMEM);
#   return lookup_real(base->d_inode, dentry, flags);
LHASH_OLD = (
    '\tif (dentry)\n'
    '\t\treturn dentry;\n'
    '\n'
    '\tdentry = d_alloc(base, name);\n'
    '\tif (unlikely(!dentry))\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
    '\treturn lookup_real(base->d_inode, dentry, flags);\n'
    '}'
)
LHASH_NEW = (
    '\tif (dentry)\n'
    '\t\treturn dentry;\n'
    '\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t{\n'
    '\t\tconst struct qstr *alloc_name = name;\n'
    '\t\tstruct dentry *d = d_alloc(base, alloc_name);\n'
    '\t\tif (unlikely(!d))\n'
    '\t\t\treturn ERR_PTR(-ENOMEM);\n'
    '\t\tif (d->d_inode && susfs_is_inode_sus_path(d->d_inode)) {\n'
    '\t\t\tif (d_in_lookup(d)) d_lookup_done(d);\n'
    '\t\t\tdput(d);\n'
    '\t\t\td = d_alloc(base, &susfs_fake_qstr_name);\n'
    '\t\t\tif (unlikely(!d))\n'
    '\t\t\t\treturn ERR_PTR(-ENOMEM);\n'
    '\t\t}\n'
    '\t\treturn lookup_real(base->d_inode, d, flags);\n'
    '\t}\n'
    '#else\n'
    '\tdentry = d_alloc(base, name);\n'
    '\tif (unlikely(!dentry))\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
    '\treturn lookup_real(base->d_inode, dentry, flags);\n'
    '#endif\n'
    '}'
)
src = patch("namei: __lookup_hash sus_path hook", LHASH_OLD, LHASH_NEW, src)

# ── c) lookup_fast(): RCU branch ─────────────────────────────────────────────
# After __d_lookup_rcu(), before the 'if (unlikely(!dentry))' fallback.
LFAST_RCU_OLD = (
    '\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n'
    '\t\tif (unlikely(!dentry)) {\n'
    '\t\t\tif (unlazy_walk(nd, NULL, 0))\n'
    '\t\t\t\treturn -ECHILD;\n'
    '\t\t\treturn 0;\n'
    '\t\t}\n'
)
LFAST_RCU_NEW = (
    '\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t\t/* RCU: __d_lookup_rcu holds no ref; no dput needed */\n'
    '\t\tif (dentry && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode))\n'
    '\t\t\tdentry = NULL;\n'
    '#endif\n'
    '\t\tif (unlikely(!dentry)) {\n'
    '\t\t\tif (unlazy_walk(nd, NULL, 0))\n'
    '\t\t\t\treturn -ECHILD;\n'
    '\t\t\treturn 0;\n'
    '\t\t}\n'
)
src = patch("namei: lookup_fast RCU sus_path hook", LFAST_RCU_OLD, LFAST_RCU_NEW, src)

# ── c) lookup_fast(): non-RCU branch ─────────────────────────────────────────
# After __d_lookup(), before 'if (unlikely(!dentry)) goto need_lookup'.
# Two possible label names: 'need_lookup' (4.9 BSP) or 'unlazy' (some forks).
# Try both; only one will match.
for label in ('need_lookup', 'unlazy'):
    LFAST_NONRCU_OLD = (
        '\t\tdentry = __d_lookup(parent, &nd->last);\n'
        f'\t\tif (unlikely(!dentry))\n'
        f'\t\t\tgoto {label};\n'
    )
    LFAST_NONRCU_NEW = (
        '\t\tdentry = __d_lookup(parent, &nd->last);\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
        '\t\tif (dentry && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
        '\t\t\tif (d_in_lookup(dentry)) d_lookup_done(dentry);\n'
        '\t\t\tdput(dentry);\n'
        '\t\t\tdentry = NULL;\n'
        '\t\t}\n'
        '#endif\n'
        f'\t\tif (unlikely(!dentry))\n'
        f'\t\t\tgoto {label};\n'
    )
    if LFAST_NONRCU_OLD in src:
        src = patch(f"namei: lookup_fast non-RCU sus_path hook (goto {label})",
                    LFAST_NONRCU_OLD, LFAST_NONRCU_NEW, src)
        break
else:
    missed.append("namei: lookup_fast non-RCU sus_path hook (neither 'need_lookup' nor 'unlazy' label found)")

# ── d) lookup_slow(): deny hidden inode from real-fs lookup ──────────────────
# In Samsung 4.9.337 BSP, lookup_slow uses inode_lock_shared (4.14 backport).
# After the i_op->lookup call assigns 'old' and the dentry is final, we check.
# Unique anchor: the 'if (unlikely(old))' correction block + return.
LSLOW_OLD = (
    '\tinode_lock_shared(dir->d_inode);\n'
    '\told = dir->i_op->lookup(dir, dentry, flags);\n'
    '\tinode_unlock_shared(dir->d_inode);\n'
    '\tif (unlikely(old)) {\n'
    '\t\tdput(dentry);\n'
    '\t\tdentry = old;\n'
    '\t}\n'
    '\treturn dentry;\n'
    '}'
)
LSLOW_NEW = (
    '\tinode_lock_shared(dir->d_inode);\n'
    '\told = dir->i_op->lookup(dir, dentry, flags);\n'
    '\tinode_unlock_shared(dir->d_inode);\n'
    '\tif (unlikely(old)) {\n'
    '\t\tdput(dentry);\n'
    '\t\tdentry = old;\n'
    '\t}\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (!IS_ERR(dentry) && dentry->d_inode &&\n'
    '\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tdput(dentry);\n'
    '\t\treturn ERR_PTR(-ENOENT);\n'
    '\t}\n'
    '#endif\n'
    '\treturn dentry;\n'
    '}'
)
src = patch("namei: lookup_slow sus_path hook", LSLOW_OLD, LSLOW_NEW, src)

# Fallback for BSPs that use inode_lock (non-shared) in lookup_slow
if "namei: lookup_slow sus_path hook" in missed:
    LSLOW_OLD2 = (
        '\tinode_lock(dir->d_inode);\n'
        '\told = dir->i_op->lookup(dir, dentry, flags);\n'
        '\tinode_unlock(dir->d_inode);\n'
        '\tif (unlikely(old)) {\n'
        '\t\tdput(dentry);\n'
        '\t\tdentry = old;\n'
        '\t}\n'
        '\treturn dentry;\n'
        '}'
    )
    LSLOW_NEW2 = LSLOW_OLD2.replace(
        '\treturn dentry;\n'
        '}',
        '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
        '\tif (!IS_ERR(dentry) && dentry->d_inode &&\n'
        '\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n'
        '\t\tdput(dentry);\n'
        '\t\treturn ERR_PTR(-ENOENT);\n'
        '\t}\n'
        '#endif\n'
        '\treturn dentry;\n'
        '}'
    )
    src = patch("namei: lookup_slow sus_path hook (inode_lock fallback)", LSLOW_OLD2, LSLOW_NEW2, src)
    if "namei: lookup_slow sus_path hook (inode_lock fallback)" in applied:
        missed = [m for m in missed if "lookup_slow" in m]

# ── e) lookup_open(): deny at open-last stage ─────────────────────────────────
# In lookup_open(), after the dentry is obtained (dcache hit + lookup_real path),
# before the '!d_inode' check that decides create vs open.
# The 4.9.337 BSP form:
#   if (!dentry->d_inode)
#       goto out_no_open;
#   if ((~open_flag & O_CREAT) || ...atomic_open...)
#       goto no_open;
LOPEN_OLD = (
    '\tif (!dentry->d_inode)\n'
    '\t\tgoto out_no_open;\n'
    '\n'
    '\tif ((~open_flag & O_CREAT) || !dir->d_inode->i_op->atomic_open)\n'
    '\t\tgoto no_open;\n'
)
LOPEN_NEW = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tdput(dentry);\n'
    '\t\tdentry = d_alloc(dir, &susfs_fake_qstr_name);\n'
    '\t\tif (!dentry)\n'
    '\t\t\treturn ERR_PTR(-ENOMEM);\n'
    '\t\tgoto out_no_open;\n'
    '\t}\n'
    '#endif\n'
    '\tif (!dentry->d_inode)\n'
    '\t\tgoto out_no_open;\n'
    '\n'
    '\tif ((~open_flag & O_CREAT) || !dir->d_inode->i_op->atomic_open)\n'
    '\t\tgoto no_open;\n'
)
src = patch("namei: lookup_open sus_path hook", LOPEN_OLD, LOPEN_NEW, src)

with open(path, 'w') as f:
    f.write(src)

print(f"\n{'='*60}")
print(f"fs/namei.c patch summary:")
for a in applied:
    print(f"  OK : {a}")
for m in missed:
    print(f"  WARN: {m}  ← ANCHOR NOT FOUND — inspect this function manually")
print(f"{'='*60}\n")

if missed:
    # Exit 1 only if a REQUIRED hook was missed (all five are required)
    sys.exit(1)
PYEOF
    log "PATCHED (or attempted): fs/namei.c sus_path hooks — see log for per-anchor results"
else
    log "SKIP (marker present): fs/namei.c sus_path hooks"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. SUSFS SUS_MAP — fs/proc/base.c, __mem_open()
#
# Hook inserts AFTER IS_ERR(mm) check, BEFORE file->private_data = mm.
# Returns -EACCES (not -ENOENT) — EIO/ENOENT confuse ptrace debuggers.
# SUSFS_IS_INODE_SUS_MAP is a MACRO defined in <linux/susfs_def.h>
# (which was pulled from Chimera Mk8 in section 1).  Do NOT use `extern`
# for macros.
#
# ── Why the old anchor failed ──────────────────────────────────────────────
# The previous script looked for `struct pid *pid = proc_pid(inode);`
# inside __mem_open().  That line does not exist in the standard 4.9.337
# Samsung BSP form of this function — it is absent.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [3/5] fs/proc/base.c __mem_open SUS_MAP guard ==="
MARKER_PROC="CHIMERA_MK9_SUSMAP_PATCHED"
if need_patch "$MARKER_PROC" fs/proc/base.c; then
python3 - << 'PYEOF'
import sys

path = "fs/proc/base.c"
MARKER = "CHIMERA_MK9_SUSMAP_PATCHED"

with open(path) as f:
    src = f.read()

if MARKER in src:
    print(f"{path}: already patched (idempotent)")
    sys.exit(0)

# ── Header insert ─────────────────────────────────────────────────────────────
if '#include <linux/susfs_def.h>' not in src:
    src = src.replace(
        '#include "internal.h"',
        '#include "internal.h"\n'
        '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
        '#include <linux/susfs_def.h>\n'
        '#endif /* ' + MARKER + ' */',
        1,
    )

# ── Hook in __mem_open() ──────────────────────────────────────────────────────
# Standard 4.9.337 Samsung BSP __mem_open (no struct pid line):
#
#   static int __mem_open(struct inode *inode, struct file *file, unsigned int mode)
#   {
#       struct mm_struct *mm = proc_mem_open(inode, mode);
#
#       if (IS_ERR(mm))
#           return PTR_ERR(mm);
#
#       file->private_data = mm;
#       return 0;
#   }
#
# We insert the SUS_MAP guard between IS_ERR check and file->private_data.
# Blank lines may or may not exist; try both forms.

def try_anchor(old, new):
    if old in src and new not in src:
        return src.replace(old, new, 1), True
    return src, False

GUARD = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n'
    '\t\tmmput(mm);\n'
    '\t\treturn -EACCES;\n'
    '\t}\n'
    '#endif\n'
)

# Try with blank lines (more common)
OLD_A = (
    '\tif (IS_ERR(mm))\n'
    '\t\treturn PTR_ERR(mm);\n'
    '\n'
    '\tfile->private_data = mm;\n'
)
NEW_A = (
    '\tif (IS_ERR(mm))\n'
    '\t\treturn PTR_ERR(mm);\n'
    '\n'
    + GUARD +
    '\tfile->private_data = mm;\n'
)
src, ok = try_anchor(OLD_A, NEW_A)

if not ok:
    # Try without blank lines
    OLD_B = (
        '\tif (IS_ERR(mm))\n'
        '\t\treturn PTR_ERR(mm);\n'
        '\tfile->private_data = mm;\n'
    )
    NEW_B = (
        '\tif (IS_ERR(mm))\n'
        '\t\treturn PTR_ERR(mm);\n'
        + GUARD +
        '\tfile->private_data = mm;\n'
    )
    src, ok = try_anchor(OLD_B, NEW_B)

if not ok:
    print(
        "WARN: __mem_open() anchor not matched in either blank-line variant.\n"
        "  → Run: grep -n 'proc_mem_open\\|file->private_data\\|IS_ERR(mm)' fs/proc/base.c\n"
        "  → Find the IS_ERR(mm) check, then the file->private_data assignment.\n"
        "  → Insert the SUS_MAP guard block between them manually.",
        file=sys.stderr
    )
    sys.exit(1)

with open(path, 'w') as f:
    f.write(src)
print(f"OK: fs/proc/base.c __mem_open SUS_MAP guard inserted")
PYEOF
    log "PATCHED: fs/proc/base.c __mem_open SUS_MAP guard"
else
    log "SKIP (marker present): fs/proc/base.c sus_map hook"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. KernelSU-Next non-kprobe call-site hooks
#
# ── Why extern instead of #include <linux/ksu.h> ──────────────────────────
#   KernelSU-Next/uapi/ksu.h is the USERSPACE API header (ioctl codes,
#   app_profile structs, etc.).  It does NOT declare ksu_handle_faccessat,
#   ksu_handle_do_execveat_common, or ksu_handle_setresuid.
#   The kernel-side declarations are in KernelSU-Next/kernel/ksu.h (or
#   equivalent) which is NOT on LINUXINCLUDE because it is compiled as part
#   of drivers/kernelsu — an in-tree module with its own ccflags.
#
#   Using `#include <linux/ksu.h>` requires either:
#     (a) adding a shim with the entire uapi/ directory tree so that
#         ksu.h's "uapi/supercall.h" relative include chain can resolve, OR
#     (b) adding -IKernelSU-Next to LINUXINCLUDE (pollutes the namespace).
#   Both are fragile.  Using `extern` at the call site is the correct,
#   version-agnostic approach — the linker resolves at link time.
#
# ── SIGNATURE NOTE ─────────────────────────────────────────────────────────
#   These externs match the most common KSU-Next non-kprobe signature set
#   (rifsxd/KernelSU-Next ≥ v0.9, gavdoc38 fork).  If your specific
#   KernelSU-Next commit exports different function names or argument types,
#   the build will fail with 'conflicting types' or 'incompatible pointer'
#   — fix by running:
#       grep -rn 'ksu_handle_\|EXPORT_SYMBOL.*ksu' KernelSU-Next/kernel/
#   and adjusting the three extern blocks below accordingly.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [4/5] KSU-Next non-kprobe call-site hooks ==="

# 4a. fs/open.c — faccessat
if ! grep -q 'ksu_handle_faccessat' fs/open.c; then
python3 - << 'PYEOF'
import sys
path = "fs/open.c"
with open(path) as f:
    src = f.read()

if 'ksu_handle_faccessat' in src:
    sys.exit(0)

# SYSCALL_DEFINE3(faccessat ...) body in ExyHyperBrick / Samsung 4.9:
# The macro expands such that the opening brace is on the next line.
# We insert at the very start of the function body before any existing code.
OLD = (
    'SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n'
    '{\n'
)
NEW = (
    'SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n'
    '{\n'
    '#ifdef CONFIG_KSU\n'
    '\t{\n'
    '\t\textern int ksu_handle_faccessat(int *dfd,\n'
    '\t\t\t\tconst char __user **filename_user, int *mode, int *flags);\n'
    '\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'
    '\t}\n'
    '#endif\n'
)
if OLD in src:
    src = src.replace(OLD, NEW, 1)
    with open(path, 'w') as f:
        f.write(src)
    print(f"OK: fs/open.c faccessat KSU hook inserted")
else:
    print(
        "WARN: faccessat SYSCALL_DEFINE3 anchor not matched.\n"
        "  → Run: grep -n 'SYSCALL_DEFINE.*faccessat' fs/open.c\n"
        "  → Insert ksu_handle_faccessat() call at the top of the function body.",
        file=sys.stderr
    )
    sys.exit(1)
PYEOF
    log "PATCHED: fs/open.c faccessat KSU hook"
else
    log "SKIP (present): fs/open.c faccessat hook"
fi

# 4b. fs/exec.c — do_execveat_common, before search_binary_handler()
#
# ExyHyperBrick bash confirms the variable name is `ret` (NOT `retval`):
#   1890:	ret = search_binary_handler(bprm);
# Previous script used `retval` — that is why the anchor missed.
if ! grep -q 'ksu_handle_do_execveat_common' fs/exec.c; then
python3 - << 'PYEOF'
import sys
path = "fs/exec.c"
with open(path) as f:
    src = f.read()

if 'ksu_handle_do_execveat_common' in src:
    sys.exit(0)

# The call to search_binary_handler in do_execveat_common.
# ExyHyperBrick uses `ret =` (confirmed from bash audit line 1890).
# We insert the KSU hook BEFORE the search_binary_handler call.
OLD = '\tret = search_binary_handler(bprm);\n'
NEW = (
    '#ifdef CONFIG_KSU\n'
    '\t{\n'
    '\t\textern int ksu_handle_do_execveat_common(int fd,\n'
    '\t\t\t\tstruct filename *filename);\n'
    '\t\tksu_handle_do_execveat_common(fd, filename);\n'
    '\t}\n'
    '#endif\n'
    '\tret = search_binary_handler(bprm);\n'
)
if OLD in src:
    src = src.replace(OLD, NEW, 1)
    with open(path, 'w') as f:
        f.write(src)
    print("OK: fs/exec.c do_execveat_common KSU hook inserted (before search_binary_handler)")
else:
    # Fallback: try `retval =` form used by some BSPs
    OLD2 = '\tretval = search_binary_handler(bprm);\n'
    NEW2 = NEW.replace(
        '\tret = search_binary_handler(bprm);\n',
        '\tretval = search_binary_handler(bprm);\n'
    )
    if OLD2 in src:
        src = src.replace(OLD2, NEW2, 1)
        with open(path, 'w') as f:
            f.write(src)
        print("OK: fs/exec.c do_execveat_common KSU hook inserted (retval= fallback)")
    else:
        print(
            "WARN: search_binary_handler call-site anchor not matched in either 'ret=' or 'retval=' form.\n"
            "  → Run: grep -n 'search_binary_handler' fs/exec.c\n"
            "  → Insert ksu_handle_do_execveat_common(fd, filename) before that call.",
            file=sys.stderr
        )
        sys.exit(1)
PYEOF
    log "PATCHED: fs/exec.c do_execveat_common KSU hook"
else
    log "SKIP (present): fs/exec.c KSU hook"
fi

# 4c. kernel/sys.c — setresuid, after security_task_fix_setuid, before commit_creds
#
# From ExyHyperBrick bash (confirmed):
#   retval = security_task_fix_setuid(new, old, LSM_SETID_RES);
#   if (retval < 0)
#       goto error;
#
#   return commit_creds(new);
#
# KSU intercepts a setresuid(0,0,0) from su and responds via the allowlist.
# Return value convention for ksu_handle_setresuid:
#   true  → KSU is handling this cred change (commit + return 0 immediately)
#   false → normal flow, continue to commit_creds
if ! grep -q 'ksu_handle_setresuid' kernel/sys.c; then
python3 - << 'PYEOF'
import sys
path = "kernel/sys.c"
with open(path) as f:
    src = f.read()

if 'ksu_handle_setresuid' in src:
    sys.exit(0)

# Anchor confirmed from ExyHyperBrick audit document.
# The blank line between 'goto error;' and 'return commit_creds' is preserved.
OLD = (
    '\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n'
    '\tif (retval < 0)\n'
    '\t\tgoto error;\n'
    '\n'
    '\treturn commit_creds(new);\n'
)
NEW = (
    '\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n'
    '\tif (retval < 0)\n'
    '\t\tgoto error;\n'
    '\n'
    '#ifdef CONFIG_KSU\n'
    '\t{\n'
    '\t\textern bool ksu_handle_setresuid(struct cred *new,\n'
    '\t\t\t\tconst struct cred *old);\n'
    '\t\tif (ksu_handle_setresuid(new, old)) {\n'
    '\t\t\t/* KSU granted root — bypass normal commit */\n'
    '\t\t\treturn commit_creds(new);\n'
    '\t\t}\n'
    '\t}\n'
    '#endif\n'
    '\n'
    '\treturn commit_creds(new);\n'
)
if OLD in src:
    src = src.replace(OLD, NEW, 1)
    with open(path, 'w') as f:
        f.write(src)
    print("OK: kernel/sys.c setresuid KSU root-grant hook inserted")
else:
    print(
        "WARN: setresuid anchor not matched.\n"
        "  → Run: grep -n 'security_task_fix_setuid\\|commit_creds' kernel/sys.c\n"
        "  → Insert ksu_handle_setresuid() between the IS_ERR check and commit_creds call\n"
        "    inside SYSCALL_DEFINE3(setresuid).",
        file=sys.stderr
    )
    sys.exit(1)
PYEOF
    log "PATCHED: kernel/sys.c setresuid KSU root-grant hook"
else
    log "SKIP (present): kernel/sys.c KSU hook"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Kconfig / Makefile glue for CONFIG_KSU + KernelSU-Next/kernel
#
# KernelSU-Next/kernel is compiled as an in-tree module via drivers/Makefile.
# Its own Makefile adds the ccflags it needs (typically -I$(src)/../ so
# uapi/ksu.h and related internal headers resolve relative to the KSU-Next
# repo root).  We do NOT touch LINUXINCLUDE — the `extern` declarations in
# the call-site patches handle forward declarations without any include path.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [5/5] Kconfig/Makefile glue (drivers/Kconfig + drivers/Makefile) ==="
if [[ -d KernelSU-Next/kernel ]]; then

    # drivers/Kconfig — source the KSU Kconfig so CONFIG_KSU is visible
    if ! grep -q 'KernelSU-Next/kernel/Kconfig' drivers/Kconfig 2>/dev/null; then
        # Insert before the final 'endmenu' (handles both with and without trailing newline)
        if grep -q '^endmenu' drivers/Kconfig; then
            sed -i '/^endmenu/i source "KernelSU-Next/kernel/Kconfig"' drivers/Kconfig
            log "PATCHED: drivers/Kconfig (+source KernelSU-Next/kernel/Kconfig)"
        else
            printf '\nsource "KernelSU-Next/kernel/Kconfig"\n' >> drivers/Kconfig
            log "PATCHED: drivers/Kconfig (appended source line — no endmenu found)"
        fi
    else
        log "SKIP (present): drivers/Kconfig KSU source line"
    fi

    # drivers/Makefile — compile KernelSU-Next/kernel as obj-$(CONFIG_KSU)
    # Use '../KernelSU-Next/kernel/' because drivers/Makefile paths are
    # relative to the kernel source root, not to drivers/.
    if ! grep -q 'KernelSU-Next/kernel' drivers/Makefile 2>/dev/null; then
        printf '\nobj-$(CONFIG_KSU) += ../KernelSU-Next/kernel/\n' >> drivers/Makefile
        log "PATCHED: drivers/Makefile (+obj-\$(CONFIG_KSU) KernelSU-Next/kernel)"
    else
        log "SKIP (present): drivers/Makefile KSU obj line"
    fi

else
    log "FATAL: KernelSU-Next/kernel not found — run submodule init before this script"
    exit 1
fi

log "=== Patch stack application complete ==="
log "=== Review WARN lines above before proceeding to build ==="
