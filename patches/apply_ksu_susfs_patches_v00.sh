#!/usr/bin/env bash
set -Eeuo pipefail
echo "Applying KSU + SUSFS Non-Kprobe Hooks to ExyHyperBrick 4.9.337..."

# 1. Pull core SUSFS files from Chimera Mk8 reference
git checkout chimera/chimera-mk8 -- fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> fs/Makefile

# 2. Hook fs/open.c (faccessat)
sed -i '/SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/a \
#ifdef CONFIG_KSU\n\textern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif' fs/open.c

# 3. Hook fs/exec.c (do_execveat_common)
sed -i '/retval = exec_binprm(bprm);/i \
#ifdef CONFIG_KSU\n\textern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif' fs/exec.c

# 4. Hook kernel/sys.c (setresuid)
sed -i '/retval = security_task_fix_setuid(new, old, LSM_SETID_RES);/,/goto error;/ {
    /goto error;/a \
#ifdef CONFIG_KSU\n\textern int ksu_handle_setresuid(int *ruid, int *euid, int *suid);\n\tretval = ksu_handle_setresuid((int*)&ruid, (int*)&euid, (int*)&suid);\n\tif (retval) {\n\t\tabort_creds(new);\n\t\treturn retval;\n\t}\n#endif
}' kernel/sys.c

# 5. Hook fs/proc/base.c (__mem_open)
sed -i '1i #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\n#endif\n' fs/proc/base.c
sed -i '/file->private_data = mm;/i \
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n\t\tmmput(mm);\n\t\treturn -EACCES;\n\t}\n#endif' fs/proc/base.c

# 6. Apply intelligent SUSFS namei modifications
cat << 'EOF' > patch_namei.py
import sys

with open("fs/namei.c", "r") as f:
    code = f.read()

# Headers
code = code.replace(
    '#include "mount.h"',
    '#include "mount.h"\n\n#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\nextern bool susfs_is_inode_sus_path(struct inode *inode);\nextern const struct qstr susfs_fake_qstr_name;\n#endif\n'
)

# nameidata Struct addition
if "int\t\tstate;" not in code:
    code = code.replace('unsigned\tseq, m_seq;', 'unsigned\tseq, m_seq;\n\tint\t\tstate;')

# lookup_dcache
code = code.replace(
    'dput(dentry);\n\t\t\t\treturn ERR_PTR(error);\n\t\t\t}\n\t\t}\n\t}',
    'dput(dentry);\n\t\t\t\treturn ERR_PTR(error);\n\t\t\t}\n\t\t}\n\t}\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tif (d_in_lookup(dentry))\n\t\t\td_lookup_done(dentry);\n\t\tdput(dentry);\n\t\treturn NULL;\n\t}\n#endif'
)

# __lookup_hash
code = code.replace(
    'struct dentry *dentry = lookup_dcache(name, base, flags);',
    'struct dentry *dentry = lookup_dcache(name, base, flags);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tbool found_sus_path = false;\n#endif'
)
code = code.replace(
    'dentry = d_alloc(base, name);',
    'dentry = d_alloc(base, name);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\nretry:\n#endif'
)
code = code.replace(
    'return ERR_PTR(-ENOMEM);',
    'return ERR_PTR(-ENOMEM);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (unlikely(dentry) && !IS_ERR(dentry) && dentry->d_inode && !found_sus_path && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tif (d_in_lookup(dentry))\n\t\t\td_lookup_done(dentry);\n\t\tif (!(flags & LOOKUP_RCU))\n\t\t\tdput(dentry);\n\t\tdentry = d_alloc(base, &susfs_fake_qstr_name);\n\t\tfound_sus_path = true;\n\t\tgoto retry;\n\t}\n#endif'
)

# lookup_fast
code = code.replace(
    'int err;\n\n\t/*',
    'int err;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tbool is_nd_state_lookup_last_and_open_last = (nd->state & (ND_STATE_LOOKUP_LAST | ND_STATE_OPEN_LAST));\n#endif\n\n\t/*'
)

with open("fs/namei.c", "w") as f:
    f.write(code)
EOF
python3 patch_namei.py && rm patch_namei.py

echo "Patching completed seamlessly!"
