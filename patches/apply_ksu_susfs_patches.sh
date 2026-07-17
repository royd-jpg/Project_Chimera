#!/usr/bin/env bash
# Chimera Mk9 — curated KSU-Next + SUSFS patch stack
# Target : ExyHyperBrick/android_kernel_samsung_exynos9810  lineage-23.2
# KSU ref: gavdoc38/KernelSU-Next @ 242f245b2c971eb5c1cc4a689e01dcdeaff4c939
# SUSFS  : royd-jpg/Project_Chimera chimera-mk8 (4.9.337 port — NOT simonpunk 5.10)
#
# Run from the kernel repo root (working-directory: kernel). Idempotent.
#
# ── Patch order ───────────────────────────────────────────────────────────────
#  1. SUSFS core  — fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h
#  2. SUSFS namei — fs/namei.c  (struct nameidata.state + 5 lookup functions +
#                                 lookup_last / do_last ND_STATE bits)
#  3. SUSFS proc  — fs/proc/base.c  (__mem_open SUS_MAP guard)
#  4. KSU hooks   — fs/open.c  (faccessat)
#                   fs/exec.c  (do_execve + compat_do_execve via ksu_handle_execveat)
#                   kernel/sys.c — NO HOOK (ksu_handle_setresuid does not exist
#                                  in this KSU-Next fork; removed entirely)
#  5. Glue        — drivers/kernelsu symlink + drivers/{Makefile,Kconfig}
#
# ── Why extern instead of #include <linux/ksu.h> ──────────────────────────────
#  KernelSU-Next/uapi/ksu.h is the USERSPACE API header.  It only contains
#  ioctl codes and app_profile structs; it does NOT declare ksu_handle_execveat
#  or ksu_handle_faccessat.  Including it causes '#include "uapi/supercall.h"'
#  to fail because the relative path is only valid inside the KSU-Next tree.
#  Direct extern declarations compile fine: the linker resolves them against
#  the KernelSU-Next/kernel/ object files that are pulled in via drivers/kernelsu.
#
set -Eeuo pipefail

ABS_LOG="${ABS_LOG:-.}"
LOG="$ABS_LOG/patch-apply.log"
: > "$LOG"
log()  { printf '[mk9] %s\n' "$*" | tee -a "$LOG"; }
fail() { printf '[mk9][FATAL] %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

FORCE="${FORCE_REPATCH:-false}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. SUSFS core files — exact copies from chimera/chimera-mk8 reference
#    (already fetched as a remote by the workflow step before this script).
# ─────────────────────────────────────────────────────────────────────────────
log "=== [1/5] SUSFS core files from chimera/chimera-mk8 ==="

mkdir -p fs include/linux

for remote_path in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    if ! git cat-file -e "chimera/chimera-mk8:${remote_path}" 2>/dev/null; then
        fail "${remote_path} not found on chimera/chimera-mk8 — is the remote fetch complete?"
    fi
    if [[ -f "$remote_path" && "$FORCE" != "true" ]] && grep -q "SUSFS_VERSION\|SUSFS_MAGIC" "$remote_path" 2>/dev/null; then
        log "SKIP (present): $remote_path"
    else
        git show "chimera/chimera-mk8:${remote_path}" > "$remote_path"
        log "PULLED: $remote_path"
    fi
done

# fs/Makefile: wire susfs.o
if ! grep -q 'obj-$(CONFIG_KSU_SUSFS).*susfs' fs/Makefile; then
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> fs/Makefile
    log "PATCHED: fs/Makefile (+susfs.o)"
else
    log "SKIP: fs/Makefile susfs.o already present"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. fs/namei.c — SUSFS sus_path hooks
#
# All anchors are verified against the confirmed ExyHyperBrick lineage-23.2
# source (grep + sed -n outputs from the research session).  Every patch
# block uses replace_once() which FAILS the build if a REQUIRED anchor is
# missing, so any drift in the base tree is caught at patch time, not at
# compile time.
#
# Changes applied:
#   a) struct nameidata: add  unsigned int state  field (gated #ifdef)
#   b) Includes + extern declarations for SUSFS helpers
#   c) lookup_dcache:  suppress hidden inode on dcache hit
#   d) __lookup_hash:  replace dentry with susfs_fake_qstr_name on alloc
#   e) lookup_fast:    add is_nd_state var + RCU branch check + non-RCU check
#   f) lookup_slow:    replace body with Chimera Mk8 version (ND_FLAGS path)
#   g) lookup_open:    add found_sus_path / is_nd_state_open_last + d_lookup fix
#   h) lookup_last:    set ND_STATE_LOOKUP_LAST + ND_FLAGS_LOOKUP_LAST
#   i) do_last:        set ND_STATE_OPEN_LAST
# ─────────────────────────────────────────────────────────────────────────────
log "=== [2/5] fs/namei.c SUSFS sus_path hooks ==="

python3 - "$FORCE" << 'PYEOF'
import sys
from pathlib import Path

force = sys.argv[1] == "true"
MARKER = "CMK9_NAMEI_SUSFS_PATCHED"
p = Path("fs/namei.c")
src = p.read_text()

if MARKER in src and not force:
    print("namei.c: already patched — skipping (set force_repatch=true to redo)")
    sys.exit(0)

errors = []

def replace_once(src, old, new, label, required=True):
    if new in src:
        print(f"  OK (idempotent): {label}")
        return src
    if old in src:
        print(f"  OK: {label}")
        return src.replace(old, new, 1)
    msg = f"  {'FATAL' if required else 'WARN'}: anchor not found — {label}"
    print(msg, file=sys.stderr)
    if required:
        errors.append(label)
    return src

# ── a) struct nameidata: add state field ──────────────────────────────────────
# Confirmed ExyHyperBrick lineage-23.2 (line 539-540 from bash audit):
#   unsigned int	flags;
#   unsigned	seq, m_seq;
src = replace_once(src,
    '\tunsigned int\tflags;\n'
    '\tunsigned\tseq, m_seq;',
    '\tunsigned int\tflags;\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tunsigned int\tstate;\n'
    '#endif\n'
    '\tunsigned\tseq, m_seq;',
    "struct nameidata state field")

# ── b) Includes + externs ─────────────────────────────────────────────────────
# Confirmed ExyHyperBrick lineage-23.2 (lines 40-44 from bash audit):
#   #include <asm/uaccess.h>
#   #include "internal.h"
#   #include "mount.h"
# Chimera Mk8 inserts susfs_def.h between uaccess.h and internal.h,
# and adds externs after mount.h.
src = replace_once(src,
    '#include <asm/uaccess.h>\n'
    '#include "internal.h"\n'
    '#include "mount.h"',
    '#include <asm/uaccess.h>\n'
    '#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n'
    '#include <linux/susfs_def.h>\n'
    '#endif\n'
    '#include "internal.h"\n'
    '#include "mount.h"\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    'extern bool susfs_is_inode_sus_path(struct inode *inode);\n'
    'extern const struct qstr susfs_fake_qstr_name;\n'
    '#endif\n'
    '/* ' + MARKER + ' */',
    "namei.c includes + SUSFS externs")

# ── c) lookup_dcache: suppress hidden inode on dcache hit ────────────────────
# Confirmed ExyHyperBrick (lines 1564-1583) — the function ends just before the
# lookup_real comment, providing a unique multi-line anchor.
src = replace_once(src,
    '\t}\n'
    '\treturn dentry;\n'
    '}\n'
    '\n'
    '/*\n'
    ' * Call i_op->lookup on the dentry.  The dentry must be negative and\n'
    ' * unhashed.\n'
    ' *\n'
    ' * dir->d_inode->i_mutex must be held\n'
    ' */\n'
    'static struct dentry *lookup_real(struct inode *dir, struct dentry *dentry,',
    '\t}\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tif (d_in_lookup(dentry))\n'
    '\t\t\td_lookup_done(dentry);\n'
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
    ' *\n'
    ' * dir->d_inode->i_mutex must be held\n'
    ' */\n'
    'static struct dentry *lookup_real(struct inode *dir, struct dentry *dentry,',
    "lookup_dcache SUSFS hook")

# ── d) __lookup_hash: replace with Chimera Mk8 version ───────────────────────
# Confirmed ExyHyperBrick (lines 1611-1625) — complete function body.
src = replace_once(src,
    'static struct dentry *__lookup_hash(const struct qstr *name,\n'
    '\t\tstruct dentry *base, unsigned int flags)\n'
    '{\n'
    '\tstruct dentry *dentry = lookup_dcache(name, base, flags);\n'
    '\n'
    '\tif (dentry)\n'
    '\t\treturn dentry;\n'
    '\n'
    '\tdentry = d_alloc(base, name);\n'
    '\tif (unlikely(!dentry))\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
    '\n'
    '\treturn lookup_real(base->d_inode, dentry, flags);\n'
    '}',
    'static struct dentry *__lookup_hash(const struct qstr *name,\n'
    '\t\tstruct dentry *base, unsigned int flags)\n'
    '{\n'
    '\tstruct dentry *dentry = lookup_dcache(name, base, flags);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tbool found_sus_path = false;\n'
    '#endif\n'
    '\tif (dentry)\n'
    '\t\treturn dentry;\n'
    '\n'
    '\tdentry = d_alloc(base, name);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    'retry:\n'
    '#endif\n'
    '\tif (unlikely(!dentry))\n'
    '\t\treturn ERR_PTR(-ENOMEM);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (unlikely(dentry) && !IS_ERR(dentry) && dentry->d_inode && !found_sus_path && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tif (d_in_lookup(dentry))\n'
    '\t\t\td_lookup_done(dentry);\n'
    '\t\tif (!(flags & LOOKUP_RCU))\n'
    '\t\t\tdput(dentry);\n'
    '\t\tdentry = d_alloc(base, &susfs_fake_qstr_name);\n'
    '\t\tfound_sus_path = true;\n'
    '\t\tgoto retry;\n'
    '\t}\n'
    '#endif\n'
    '\treturn lookup_real(base->d_inode, dentry, flags);\n'
    '}',
    "__lookup_hash Chimera Mk8 replacement")

# ── e) lookup_fast: add nd->state variable + RCU check + non-RCU check ───────
# Confirmed ExyHyperBrick (lines 1626-1717).
# Three targeted insertions; the variable goes just before the opening comment.

# e1) is_nd_state_lookup_last_and_open_last variable
# Anchor: the unique local-var block at the top of lookup_fast
src = replace_once(src,
    '\tstruct vfsmount *mnt = nd->path.mnt;\n'
    '\tstruct dentry *dentry, *parent = nd->path.dentry;\n'
    '\tint status = 1;\n'
    '\tint err;\n'
    '\n'
    '\t/*\n'
    '\t * Rename seqlock is not required here because in the off chance\n',
    '\tstruct vfsmount *mnt = nd->path.mnt;\n'
    '\tstruct dentry *dentry, *parent = nd->path.dentry;\n'
    '\tint status = 1;\n'
    '\tint err;\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tbool is_nd_state_lookup_last_and_open_last = (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST));\n'
    '#endif\n'
    '\n'
    '\t/*\n'
    '\t * Rename seqlock is not required here because in the off chance\n',
    "lookup_fast: add nd->state variable")

# e2) RCU branch: after __d_lookup_rcu, before if (unlikely(!dentry))
# Confirmed ExyHyperBrick (lines 1643-1648):
src = replace_once(src,
    '\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n'
    '\t\tif (unlikely(!dentry)) {\n'
    '\t\t\tif (unlazy_walk(nd, NULL, 0))\n'
    '\t\t\t\treturn -ECHILD;\n'
    '\t\t\treturn 0;\n'
    '\t\t}',
    '\t\tdentry = __d_lookup_rcu(parent, &nd->last, &seq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t\tif (is_nd_state_lookup_last_and_open_last && dentry && !IS_ERR(dentry) &&\n'
    '\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\t\tif (d_in_lookup(dentry))\n'
    '\t\t\t\td_lookup_done(dentry);\n'
    '\t\t\t/* __d_lookup_rcu holds no lockref; no dput needed */\n'
    '\t\t\tdentry = NULL;\n'
    '\t\t}\n'
    '#endif\n'
    '\t\tif (unlikely(!dentry)) {\n'
    '\t\t\tif (unlazy_walk(nd, NULL, 0))\n'
    '\t\t\t\treturn -ECHILD;\n'
    '\t\t\treturn 0;\n'
    '\t\t}',
    "lookup_fast: RCU branch SUSFS check")

# e3) non-RCU branch: after __d_lookup, before if (unlikely(!dentry)) return 0
# Confirmed ExyHyperBrick (lines 1697-1699):
src = replace_once(src,
    '\t} else {\n'
    '\t\tdentry = __d_lookup(parent, &nd->last);\n'
    '\t\tif (unlikely(!dentry))\n'
    '\t\t\treturn 0;\n'
    '\t\tif (unlikely(dentry->d_flags & DCACHE_OP_REVALIDATE))\n'
    '\t\t\tstatus = d_revalidate(dentry, nd->flags);\n'
    '\t}',
    '\t} else {\n'
    '\t\tdentry = __d_lookup(parent, &nd->last);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t\tif (is_nd_state_lookup_last_and_open_last && dentry && !IS_ERR(dentry) &&\n'
    '\t\t    dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\t\tif (d_in_lookup(dentry))\n'
    '\t\t\t\td_lookup_done(dentry);\n'
    '\t\t\tdput(dentry);\n'
    '\t\t\tdentry = NULL;\n'
    '\t\t}\n'
    '#endif\n'
    '\t\tif (unlikely(!dentry))\n'
    '\t\t\treturn 0;\n'
    '\t\tif (unlikely(dentry->d_flags & DCACHE_OP_REVALIDATE))\n'
    '\t\t\tstatus = d_revalidate(dentry, nd->flags);\n'
    '\t}',
    "lookup_fast: non-RCU branch SUSFS check")

# ── f) lookup_slow: full replacement with Chimera Mk8 body ───────────────────
# Confirmed ExyHyperBrick (lines 1718-1757) complete function body.
# Chimera Mk8 adds ND_FLAGS_LOOKUP_LAST tracking + fake_qstr substitution.
src = replace_once(src,
    'static struct dentry *lookup_slow(const struct qstr *name,\n'
    '\t\t\t\t  struct dentry *dir,\n'
    '\t\t\t\t  unsigned int flags)\n'
    '{\n'
    '\tstruct dentry *dentry = ERR_PTR(-ENOENT), *old;\n'
    '\tstruct inode *inode = dir->d_inode;\n'
    '\tDECLARE_WAIT_QUEUE_HEAD_ONSTACK(wq);\n'
    '\n'
    '\tinode_lock_shared(inode);\n'
    '\t/* Don\'t go there if it\'s already dead */\n'
    '\tif (unlikely(IS_DEADDIR(inode)))\n'
    '\t\tgoto out;\n'
    'again:\n'
    '\tdentry = d_alloc_parallel(dir, name, &wq);\n'
    '\tif (IS_ERR(dentry))\n'
    '\t\tgoto out;\n'
    '\tif (unlikely(!d_in_lookup(dentry))) {\n'
    '\t\tif ((dentry->d_flags & DCACHE_OP_REVALIDATE) &&\n'
    '\t\t    !(flags & LOOKUP_NO_REVAL)) {\n'
    '\t\t\tint error = d_revalidate(dentry, flags);\n'
    '\t\t\tif (unlikely(error <= 0)) {\n'
    '\t\t\t\tif (!error) {\n'
    '\t\t\t\t\td_invalidate(dentry);\n'
    '\t\t\t\t\tdput(dentry);\n'
    '\t\t\t\t\tgoto again;\n'
    '\t\t\t\t}\n'
    '\t\t\t\tdput(dentry);\n'
    '\t\t\t\tdentry = ERR_PTR(error);\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t} else {\n'
    '\t\told = inode->i_op->lookup(inode, dentry, flags);\n'
    '\t\td_lookup_done(dentry);\n'
    '\t\tif (unlikely(old)) {\n'
    '\t\t\tdput(dentry);\n'
    '\t\t\tdentry = old;\n'
    '\t\t}\n'
    '\t}\n'
    'out:\n'
    '\tinode_unlock_shared(inode);\n'
    '\treturn dentry;\n'
    '}',
    # ── Chimera Mk8 replacement ──
    'static struct dentry *lookup_slow(const struct qstr *name,\n'
    '\t\t\t\t  struct dentry *dir,\n'
    '\t\t\t\t  unsigned int flags)\n'
    '{\n'
    '\tstruct dentry *dentry = ERR_PTR(-ENOENT), *old;\n'
    '\tstruct inode *inode = dir->d_inode;\n'
    '\tDECLARE_WAIT_QUEUE_HEAD_ONSTACK(wq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tbool found_sus_path = false;\n'
    '\tbool is_nd_flags_lookup_last = (flags & ND_FLAGS_LOOKUP_LAST);\n'
    '#endif\n'
    '\n'
    '\tinode_lock_shared(inode);\n'
    '\t/* Don\'t go there if it\'s already dead */\n'
    '\tif (unlikely(IS_DEADDIR(inode)))\n'
    '\t\tgoto out;\n'
    'again:\n'
    '\tdentry = d_alloc_parallel(dir, name, &wq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    'retry:\n'
    '#endif\n'
    '\tif (IS_ERR(dentry))\n'
    '\t\tgoto out;\n'
    '\tif (unlikely(!d_in_lookup(dentry))) {\n'
    '\t\tif ((dentry->d_flags & DCACHE_OP_REVALIDATE) &&\n'
    '\t\t    !(flags & LOOKUP_NO_REVAL)) {\n'
    '\t\t\tint error = d_revalidate(dentry, flags);\n'
    '\t\t\tif (unlikely(error <= 0)) {\n'
    '\t\t\t\tif (!error) {\n'
    '\t\t\t\t\td_invalidate(dentry);\n'
    '\t\t\t\t\tdput(dentry);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t\t\t\tif (found_sus_path) {\n'
    '\t\t\t\t\tdentry = d_alloc_parallel(dir, &susfs_fake_qstr_name, &wq);\n'
    '\t\t\t\t\tgoto retry;\n'
    '\t\t\t\t}\n'
    '#endif\n'
    '\t\t\t\t\tgoto again;\n'
    '\t\t\t\t}\n'
    '\t\t\t\tdput(dentry);\n'
    '\t\t\t\tdentry = ERR_PTR(error);\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t} else {\n'
    '\t\told = inode->i_op->lookup(inode, dentry, flags);\n'
    '\t\td_lookup_done(dentry);\n'
    '\t\tif (unlikely(old)) {\n'
    '\t\t\tdput(dentry);\n'
    '\t\t\tdentry = old;\n'
    '\t\t}\n'
    '\t}\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (is_nd_flags_lookup_last && !found_sus_path && dentry && !IS_ERR(dentry) &&\n'
    '\t\tdentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tif (d_in_lookup(dentry))\n'
    '\t\t\td_lookup_done(dentry);\n'
    '\t\tif (!(flags & LOOKUP_RCU))\n'
    '\t\t\tdput(dentry);\n'
    '\t\tdentry = d_alloc_parallel(dir, &susfs_fake_qstr_name, &wq);\n'
    '\t\tfound_sus_path = true;\n'
    '\t\tgoto retry;\n'
    '\t}\n'
    '#endif\n'
    'out:\n'
    '\tinode_unlock_shared(inode);\n'
    '\treturn dentry;\n'
    '}',
    "lookup_slow Chimera Mk8 replacement")

# ── g) lookup_open: add SUSFS tracking vars + d_lookup check + alloc patch ───
# Confirmed ExyHyperBrick (lines 3216-3245).

# g1) Add bool vars after DECLARE_WAIT_QUEUE_HEAD_ONSTACK(wq);
# This line is unique to lookup_open in the file.
src = replace_once(src,
    '\tDECLARE_WAIT_QUEUE_HEAD_ONSTACK(wq);\n'
    '\n'
    '\tif (unlikely(IS_DEADDIR(dir_inode)))\n'
    '\t\treturn -ENOENT;\n'
    '\n'
    '\t*opened &= ~FILE_CREATED;\n'
    '\tdentry = d_lookup(dir, &nd->last);\n'
    '\tfor (;;) {\n'
    '\t\tif (!dentry) {\n'
    '\t\t\tdentry = d_alloc_parallel(dir, &nd->last, &wq);\n'
    '\t\t\tif (IS_ERR(dentry))\n'
    '\t\t\t\treturn PTR_ERR(dentry);\n'
    '\t\t}',
    '\tDECLARE_WAIT_QUEUE_HEAD_ONSTACK(wq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tbool found_sus_path = false;\n'
    '\tbool is_nd_state_open_last = (nd->state & ND_STATE_OPEN_LAST);\n'
    '#endif\n'
    '\n'
    '\tif (unlikely(IS_DEADDIR(dir_inode)))\n'
    '\t\treturn -ENOENT;\n'
    '\n'
    '\t*opened &= ~FILE_CREATED;\n'
    '\tdentry = d_lookup(dir, &nd->last);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tif (is_nd_state_open_last && dentry && !IS_ERR(dentry) && dentry->d_inode &&\n'
    '\t\tsusfs_is_inode_sus_path(dentry->d_inode)) {\n'
    '\t\tif (d_in_lookup(dentry))\n'
    '\t\t\td_lookup_done(dentry);\n'
    '\t\tdput(dentry);\n'
    '\t\tdentry = NULL;\n'
    '\t\tfound_sus_path = true;\n'
    '\t}\n'
    '#endif\n'
    '\tfor (;;) {\n'
    '\t\tif (!dentry) {\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\t\t\tif (found_sus_path) {\n'
    '\t\t\t\tdentry = d_alloc_parallel(dir, &susfs_fake_qstr_name, &wq);\n'
    '\t\t\t\tgoto skip_orig_dalloc;\n'
    '\t\t\t}\n'
    '#endif\n'
    '\t\t\tdentry = d_alloc_parallel(dir, &nd->last, &wq);\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    'skip_orig_dalloc:\n'
    '#endif\n'
    '\t\t\tif (IS_ERR(dentry))\n'
    '\t\t\t\treturn PTR_ERR(dentry);\n'
    '\t\t}',
    "lookup_open: SUSFS vars + d_lookup check + d_alloc_parallel patch")

# ── h) lookup_last: set ND_STATE_LOOKUP_LAST + ND_FLAGS_LOOKUP_LAST ──────────
# Confirmed ExyHyperBrick (lines 2341-2353).
# Setting ND_FLAGS_LOOKUP_LAST here (in addition to nd->state) avoids the need
# to also patch walk_component; lookup_slow receives flags = nd->flags.
src = replace_once(src,
    'static inline int lookup_last(struct nameidata *nd)\n'
    '{\n'
    '\tif (nd->last_type == LAST_NORM && nd->last.name[nd->last.len])\n'
    '\t\tnd->flags |= LOOKUP_FOLLOW | LOOKUP_DIRECTORY;\n'
    '\n'
    '\tnd->flags &= ~LOOKUP_PARENT;\n',
    'static inline int lookup_last(struct nameidata *nd)\n'
    '{\n'
    '\tif (nd->last_type == LAST_NORM && nd->last.name[nd->last.len])\n'
    '\t\tnd->flags |= LOOKUP_FOLLOW | LOOKUP_DIRECTORY;\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tnd->state |= ND_STATE_LOOKUP_LAST;\n'
    '\tnd->flags |= ND_FLAGS_LOOKUP_LAST;   /* propagate to lookup_slow flags arg */\n'
    '#endif\n'
    '\tnd->flags &= ~LOOKUP_PARENT;\n',
    "lookup_last: set ND_STATE_LOOKUP_LAST + ND_FLAGS_LOOKUP_LAST")

# ── i) do_last: set ND_STATE_OPEN_LAST ───────────────────────────────────────
# Confirmed ExyHyperBrick (lines 3365-3366).
# The combined anchor nd->flags &= ~LOOKUP_PARENT + nd->flags |= op->intent
# is unique to do_last (op->intent is open-only).
src = replace_once(src,
    '\tnd->flags &= ~LOOKUP_PARENT;\n'
    '\tnd->flags |= op->intent;\n'
    '\n'
    '\tif (nd->last_type != LAST_NORM) {\n'
    '\t\terror = handle_dots(nd, nd->last_type);\n',
    '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
    '\tnd->state |= ND_STATE_OPEN_LAST;\n'
    '#endif\n'
    '\tnd->flags &= ~LOOKUP_PARENT;\n'
    '\tnd->flags |= op->intent;\n'
    '\n'
    '\tif (nd->last_type != LAST_NORM) {\n'
    '\t\terror = handle_dots(nd, nd->last_type);\n',
    "do_last: set ND_STATE_OPEN_LAST")

p.write_text(src)

if errors:
    print(f"\nFATAL: {len(errors)} required anchor(s) not found:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    print("\nRun:  grep -n '<anchor keyword>' kernel/fs/namei.c", file=sys.stderr)
    print("to locate the nearest match and adjust the anchor string.", file=sys.stderr)
    sys.exit(1)

print(f"fs/namei.c: all SUSFS sus_path hooks applied successfully")
PYEOF

log "PATCHED: fs/namei.c SUSFS sus_path hooks"

# ─────────────────────────────────────────────────────────────────────────────
# 3. fs/proc/base.c — SUSFS SUS_MAP guard in __mem_open()
#
# SUSFS_IS_INODE_SUS_MAP is a MACRO (defined in susfs_def.h), NOT a function.
# Do NOT use 'extern bool SUSFS_IS_INODE_SUS_MAP(...)' — that causes a
# conflicting declaration error.  We only need the susfs_def.h include.
#
# Confirmed ExyHyperBrick lineage-23.2 __mem_open (lines 826-835):
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
# Note: NO 'struct pid *pid = proc_pid(inode);' line — that was a prior bug.
# ─────────────────────────────────────────────────────────────────────────────
log "=== [3/5] fs/proc/base.c __mem_open SUS_MAP guard ==="

python3 - "$FORCE" << 'PYEOF'
import sys
from pathlib import Path

force = sys.argv[1] == "true"
MARKER = "CMK9_PROC_SUSMAP_PATCHED"
p = Path("fs/proc/base.c")
src = p.read_text()

if MARKER in src and not force:
    print("fs/proc/base.c: already patched — skipping")
    sys.exit(0)

errors = []

def replace_once(src, old, new, label, required=True):
    if new in src:
        print(f"  OK (idempotent): {label}")
        return src
    if old in src:
        print(f"  OK: {label}")
        return src.replace(old, new, 1)
    msg = f"  {'FATAL' if required else 'WARN'}: anchor not found — {label}"
    print(msg, file=sys.stderr)
    if required:
        errors.append(label)
    return src

# Add susfs_def.h include — the macro SUSFS_IS_INODE_SUS_MAP lives there.
# Anchor: the #include "internal.h" line (confirmed present in proc/base.c).
src = replace_once(src,
    '#include "internal.h"',
    '#include "internal.h"\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '#include <linux/susfs_def.h>\n'
    '#endif\n'
    '/* ' + MARKER + ' */',
    "proc/base.c susfs_def.h include")

# Insert SUS_MAP guard inside __mem_open().
# Anchor uses both forms (blank-line and no-blank-line between statements)
# because different BSP minor revisions vary here.

GUARD = (
    '#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n'
    '\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n'
    '\t\tmmput(mm);\n'
    '\t\treturn -EACCES;\n'
    '\t}\n'
    '#endif\n'
)

# Form A: blank line between IS_ERR check and file->private_data (confirmed)
src = replace_once(src,
    '\tif (IS_ERR(mm))\n'
    '\t\treturn PTR_ERR(mm);\n'
    '\n'
    '\tfile->private_data = mm;\n',
    '\tif (IS_ERR(mm))\n'
    '\t\treturn PTR_ERR(mm);\n'
    '\n'
    + GUARD +
    '\tfile->private_data = mm;\n',
    "__mem_open SUS_MAP guard (blank-line form)")

# Form B fallback: no blank line
if not errors and 'SUSFS_IS_INODE_SUS_MAP' not in src:
    src = replace_once(src,
        '\tif (IS_ERR(mm))\n'
        '\t\treturn PTR_ERR(mm);\n'
        '\tfile->private_data = mm;\n',
        '\tif (IS_ERR(mm))\n'
        '\t\treturn PTR_ERR(mm);\n'
        + GUARD +
        '\tfile->private_data = mm;\n',
        "__mem_open SUS_MAP guard (no-blank-line form)")

p.write_text(src)

if errors:
    print("\nFATAL: required anchor(s) not found:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    print("\nRun:  grep -n 'IS_ERR(mm)\\|private_data\\|proc_mem_open' kernel/fs/proc/base.c", file=sys.stderr)
    sys.exit(1)

print("fs/proc/base.c: SUS_MAP guard applied")
PYEOF

log "PATCHED: fs/proc/base.c __mem_open SUS_MAP guard"

# ─────────────────────────────────────────────────────────────────────────────
# 4. KSU-Next non-kprobe call-site hooks
#
# ── Why extern (not #include) ─────────────────────────────────────────────────
# KernelSU-Next/uapi/ksu.h is the USERSPACE API header and does NOT declare
# kernel hook functions.  It contains '#include "uapi/supercall.h"' which is
# a relative path that only resolves inside the KSU-Next source tree.
# Including it from kernel/fs/open.c or fs/exec.c fails with
#   fatal error: 'uapi/supercall.h' file not found
# Direct extern declarations compile correctly and link against the
# KernelSU-Next/kernel/ object files pulled in through drivers/kernelsu.
#
# ── What is NOT hooked ────────────────────────────────────────────────────────
# kernel/sys.c setresuid: ksu_handle_setresuid does NOT exist in the
# gavdoc38/KernelSU-Next fork at 242f245b.  The reference integration
# (gavdoc38/android_kernel_samsung_exynos9810 lineage-23.2-ksun3-susfs2)
# confirms NO sys.c modification.  This section is intentionally absent.
#
# ── Hook targets (confirmed from gavdoc38 reference tree) ─────────────────────
# fs/open.c    : SYSCALL_DEFINE3(faccessat)  → ksu_handle_faccessat
# fs/exec.c    : do_execve()                 → ksu_handle_execveat
#                compat_do_execve()          → ksu_handle_execveat
# ─────────────────────────────────────────────────────────────────────────────
log "=== [4/5] KSU-Next non-kprobe call-site hooks ==="

# 4a. fs/open.c — faccessat
python3 - "$FORCE" << 'PYEOF'
import sys
from pathlib import Path

force = sys.argv[1] == "true"
p = Path("fs/open.c")
src = p.read_text()

if 'ksu_handle_faccessat' in src and not force:
    print("fs/open.c: faccessat hook already present — skipping")
    sys.exit(0)

errors = []

def replace_once(src, old, new, label, required=True):
    if new in src:
        print(f"  OK (idempotent): {label}")
        return src
    if old in src:
        print(f"  OK: {label}")
        return src.replace(old, new, 1)
    msg = f"  {'FATAL' if required else 'WARN'}: anchor not found — {label}"
    print(msg, file=sys.stderr)
    if required:
        errors.append(label)
    return src

# Step 1: insert extern declaration before the SYSCALL_DEFINE3(faccessat) block.
# Anchor: the comment block that immediately precedes faccessat — confirmed unique.
src = replace_once(src,
    ' * switching the fsuid/fsgid around to the real ones.\n'
    ' */\n'
    'SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)',
    ' * switching the fsuid/fsgid around to the real ones.\n'
    ' */\n'
    '#ifdef CONFIG_KSU\n'
    '__attribute__((hot))\n'
    'extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n'
    '\t\t\t\tint *mode, int *flags);\n'
    '#endif\n'
    'SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)',
    "fs/open.c: faccessat extern declaration")

# Step 2: insert call inside faccessat, after 'unsigned int lookup_flags = LOOKUP_FOLLOW'
# and before 'if (mode & ~S_IRWXO)' — the comment on that line makes it unique.
src = replace_once(src,
    '\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n'
    '\n'
    '\tif (mode & ~S_IRWXO)\t/* where\'s F_OK, X_OK, W_OK, R_OK? */',
    '\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n'
    '\n'
    '#ifdef CONFIG_KSU\n'
    '\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'
    '#endif\n'
    '\n'
    '\tif (mode & ~S_IRWXO)\t/* where\'s F_OK, X_OK, W_OK, R_OK? */',
    "fs/open.c: faccessat KSU call")

p.write_text(src)

if errors:
    for e in errors:
        print(f"FATAL: {e}", file=sys.stderr)
    sys.exit(1)
print("fs/open.c: faccessat KSU hook applied")
PYEOF
log "PATCHED: fs/open.c faccessat"

# 4b. fs/exec.c — do_execve() and compat_do_execve()
#
# Confirmed from gavdoc38 reference (lineage-23.2-ksun3-susfs2):
#   - Hook function: ksu_handle_execveat (NOT ksu_handle_do_execveat_common)
#   - Hook location: do_execve() and compat_do_execve(), NOT do_execveat_common()
#   - Insertion point: immediately before 'return do_execveat_common(AT_FDCWD, ...)'
#
python3 - "$FORCE" << 'PYEOF'
import sys
from pathlib import Path

force = sys.argv[1] == "true"
p = Path("fs/exec.c")
src = p.read_text()

if 'ksu_handle_execveat' in src and not force:
    print("fs/exec.c: execveat hook already present — skipping")
    sys.exit(0)

errors = []

def replace_once(src, old, new, label, required=True):
    if new in src:
        print(f"  OK (idempotent): {label}")
        return src
    if old in src:
        print(f"  OK: {label}")
        return src.replace(old, new, 1)
    msg = f"  {'FATAL' if required else 'WARN'}: anchor not found — {label}"
    print(msg, file=sys.stderr)
    if required:
        errors.append(label)
    return src

# Step 1: extern declaration — insert just before 'int do_execve('.
# The function signature is unique in the file.
src = replace_once(src,
    'int do_execve(struct filename *filename,\n'
    '\tconst char __user *const __user *__argv,\n'
    '\tconst char __user *const __user *__envp)\n'
    '{',
    '#ifdef CONFIG_KSU\n'
    '__attribute__((hot))\n'
    'extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n'
    '\t\t\t\tvoid *argv, void *envp, int *flags);\n'
    '#endif\n'
    'int do_execve(struct filename *filename,\n'
    '\tconst char __user *const __user *__argv,\n'
    '\tconst char __user *const __user *__envp)\n'
    '{',
    "fs/exec.c: ksu_handle_execveat extern declaration")

# Step 2: hook in do_execve() body.
# Anchor: the native argv/envp assignment + the AT_FDCWD return.
# The '.ptr.native' field distinguishes this from the compat variant.
src = replace_once(src,
    '\tstruct user_arg_ptr argv = { .ptr.native = __argv };\n'
    '\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n'
    '\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n'
    '}\n'
    '\n'
    'int do_execveat(int fd, struct filename *filename,',
    '\tstruct user_arg_ptr argv = { .ptr.native = __argv };\n'
    '\tstruct user_arg_ptr envp = { .ptr.native = __envp };\n'
    '#ifdef CONFIG_KSU\n'
    '\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n'
    '#endif\n'
    '\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n'
    '}\n'
    '\n'
    'int do_execveat(int fd, struct filename *filename,',
    "fs/exec.c: do_execve KSU call")

# Step 3: hook in compat_do_execve() body.
# Anchor: the compat envp assignment + AT_FDCWD return.
# The '.is_compat = true' field makes this unique to the compat variant.
src = replace_once(src,
    '\tstruct user_arg_ptr envp = {\n'
    '\t\t.is_compat = true,\n'
    '\t\t.ptr.compat = __envp,\n'
    '\t};\n'
    '\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n'
    '}\n'
    '\n'
    'static int compat_do_execveat(int fd, struct filename *filename,',
    '\tstruct user_arg_ptr envp = {\n'
    '\t\t.is_compat = true,\n'
    '\t\t.ptr.compat = __envp,\n'
    '\t};\n'
    '#ifdef CONFIG_KSU /* 32-bit ksud and 32-on-64 support */\n'
    '\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n'
    '#endif\n'
    '\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\n'
    '}\n'
    '\n'
    'static int compat_do_execveat(int fd, struct filename *filename,',
    "fs/exec.c: compat_do_execve KSU call")

p.write_text(src)

if errors:
    for e in errors:
        print(f"FATAL: {e}", file=sys.stderr)
    print("\nRun:  grep -n 'do_execve\\|do_execveat_common\\|compat_do_execve' kernel/fs/exec.c", file=sys.stderr)
    sys.exit(1)
print("fs/exec.c: ksu_handle_execveat hooks applied (do_execve + compat_do_execve)")
PYEOF
log "PATCHED: fs/exec.c do_execve + compat_do_execve"

# NOTE: kernel/sys.c is intentionally NOT patched.
# ksu_handle_setresuid does not exist in gavdoc38/KernelSU-Next @ 242f245b.
# The confirmed reference integration (lineage-23.2-ksun3-susfs2) has no
# sys.c modification.

# ─────────────────────────────────────────────────────────────────────────────
# 5. Kconfig / Makefile glue for CONFIG_KSU + drivers/kernelsu
#
# drivers/kernelsu is a SYMLINK to KernelSU-Next/kernel/ — this matches the
# Chimera Mk8 build system (drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/).
# ─────────────────────────────────────────────────────────────────────────────
log "=== [5/5] Kconfig/Makefile glue ==="

if [[ ! -d KernelSU-Next/kernel ]]; then
    fail "KernelSU-Next/kernel not found — ensure KSU-Next is cloned at kernel/KernelSU-Next"
fi

# Create symlink drivers/kernelsu → KernelSU-Next/kernel
# Using relative target so it works regardless of absolute path on runner.
if [[ ! -e drivers/kernelsu ]]; then
    ln -snf ../KernelSU-Next/kernel drivers/kernelsu
    log "CREATED: drivers/kernelsu → KernelSU-Next/kernel (symlink)"
elif [[ ! -L drivers/kernelsu ]]; then
    fail "drivers/kernelsu exists but is NOT a symlink — inspect manually"
else
    log "SKIP: drivers/kernelsu symlink already present"
fi

# drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/
if ! grep -q 'obj-$(CONFIG_KSU).*kernelsu' drivers/Makefile 2>/dev/null; then
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    log "PATCHED: drivers/Makefile (+kernelsu/)"
else
    log "SKIP: drivers/Makefile KSU entry already present"
fi

# drivers/Kconfig: source "drivers/kernelsu/Kconfig"
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig 2>/dev/null; then
    if grep -q '^endmenu' drivers/Kconfig; then
        sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    else
        printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
    fi
    log "PATCHED: drivers/Kconfig (+source drivers/kernelsu/Kconfig)"
else
    log "SKIP: drivers/Kconfig KSU source already present"
fi

# Sanity: confirm the KSU Kconfig is accessible through the symlink
if [[ ! -f drivers/kernelsu/Kconfig ]]; then
    fail "drivers/kernelsu/Kconfig not readable — symlink may point to wrong target"
fi

log "=== Patch stack application complete ==="
log ""
log "Summary:"
log "  SUSFS core    : fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h"
log "  namei.c       : struct nameidata.state + lookup_{dcache,_hash,fast,slow,open}"
log "                  + lookup_last / do_last ND_STATE bits"
log "  proc/base.c   : __mem_open SUS_MAP guard (SUSFS_IS_INODE_SUS_MAP macro)"
log "  open.c        : ksu_handle_faccessat (extern, no header)"
log "  exec.c        : ksu_handle_execveat in do_execve + compat_do_execve (extern)"
log "  sys.c         : NOT PATCHED (ksu_handle_setresuid absent from this KSU fork)"
log "  drivers       : kernelsu symlink + Makefile + Kconfig"
