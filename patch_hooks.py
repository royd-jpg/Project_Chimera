import sys
from pathlib import Path

def replace_once(file_path, old, new, label):
    p = Path(file_path)
    src = p.read_text()
    if new in src:
        print(f"  OK (idempotent): {label}")
        return
    if old in src:
        p.write_text(src.replace(old, new, 1))
        print(f"  OK: {label}")
        return
    print(f"  FATAL: anchor not found — {label}", file=sys.stderr)
    sys.exit(1)

# 1. KSU & SUSFS Wiring
Path('fs/Makefile').write_text(Path('fs/Makefile').read_text() + '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n')
Path('drivers/Makefile').write_text(Path('drivers/Makefile').read_text() + '\nobj-$(CONFIG_KSU) += kernelsu/\n')
replace_once('drivers/Kconfig', 'source "drivers/mpsd/Kconfig"', 'source "drivers/mpsd/Kconfig"\n\nsource "drivers/kernelsu/Kconfig"', 'drivers/Kconfig kernelsu')
replace_once('fs/Kconfig', 'endmenu', 'config KSU_SUSFS\n\tbool "KSU SUSFS"\n\tdepends on KSU\nconfig KSU_SUSFS_SUS_PATH\n\tbool "SUS PATH"\n\tdepends on KSU_SUSFS\nconfig KSU_SUSFS_SUS_MAP\n\tbool "SUS MAP"\n\tdepends on KSU_SUSFS\nconfig KSU_SUSFS_SUS_KSTAT\n\tbool "SUS KSTAT"\n\tdepends on KSU_SUSFS\n\nendmenu', 'fs/Kconfig susfs')

# 2. fs/open.c — faccessat hook
replace_once('fs/open.c',
    'SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{',
    '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_ptr, int *mode, int *flags);\n#endif\nSYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif',
    'fs/open.c faccessat')

# 3. fs/exec.c — do_execveat_common hook
replace_once('fs/exec.c',
    'static int do_execveat_common(int fd, struct filename *filename,',
    '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\nstatic int do_execveat_common(int fd, struct filename *filename,',
    'fs/exec.c extern')
replace_once('fs/exec.c',
    '\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);',
    '\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n#ifdef CONFIG_KSU\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif',
    'fs/exec.c execveat hook')

# 4. kernel/sys.c — setresuid hook
replace_once('kernel/sys.c',
    '\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n\tif (retval < 0)\n\t\tgoto error;\n\n\treturn commit_creds(new);',
    '\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n\tif (retval < 0)\n\t\tgoto error;\n\n#ifdef CONFIG_KSU\n\textern int ksu_handle_setresuid(uid_t *ruid, uid_t *euid, uid_t *suid);\n\tksu_handle_setresuid(&ruid, &euid, &suid);\n\tnew->uid = make_kuid(old->user_ns, ruid);\n\tnew->euid = make_kuid(old->user_ns, euid);\n\tnew->suid = make_kuid(old->user_ns, suid);\n#endif\n\n\treturn commit_creds(new);',
    'kernel/sys.c setresuid')

# 5. kernel/reboot.c — reboot hook for Kbuild check
replace_once('kernel/reboot.c',
    'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{',
    '#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\nSYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{',
    'kernel/reboot.c extern')
replace_once('kernel/reboot.c',
    '\tif ((cmd == LINUX_REBOOT_CMD_POWER_OFF) && !pm_power_off)\n\t\tcmd = LINUX_REBOOT_CMD_HALT;\n\n\tmutex_lock(&reboot_mutex);',
    '\tif ((cmd == LINUX_REBOOT_CMD_POWER_OFF) && !pm_power_off)\n\t\tcmd = LINUX_REBOOT_CMD_HALT;\n\n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\tmutex_lock(&reboot_mutex);',
    'kernel/reboot.c sys_reboot hook')

# 6. fs/proc/base.c — SUS_MAP __mem_open hook
replace_once('fs/proc/base.c',
    '#include <linux/oom.h>',
    '#include <linux/oom.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\n#endif',
    'fs/proc/base.c includes')
replace_once('fs/proc/base.c',
    '\tif (IS_ERR(mm))\n\t\treturn PTR_ERR(mm);\n\n\tfile->private_data = mm;',
    '\tif (IS_ERR(mm))\n\t\treturn PTR_ERR(mm);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n\t\tmmput(mm);\n\t\treturn -EACCES;\n\t}\n#endif\n\n\tfile->private_data = mm;',
    'fs/proc/base.c __mem_open hook')

# 7. fs/namei.c — SUS_PATH hooks
replace_once('fs/namei.c',
    '#include <asm/uaccess.h>',
    '#include <asm/uaccess.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n#include <linux/susfs_def.h>\nextern bool susfs_is_inode_sus_path(struct inode *inode);\nextern const struct qstr susfs_fake_qstr_name;\n#endif',
    'fs/namei.c includes')
replace_once('fs/namei.c',
    '\t\t\t}\n\t\t}\n\t}\n\treturn dentry;\n}',
    '\t\t\t}\n\t\t}\n\t}\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tif (d_in_lookup(dentry))\n\t\t\td_lookup_done(dentry);\n\t\tdput(dentry);\n\t\treturn NULL;\n\t}\n#endif\n\treturn dentry;\n}',
    'fs/namei.c lookup_dcache')
replace_once('fs/namei.c',
    '\tdentry = d_alloc(base, name);\n\tif (unlikely(!dentry))\n\t\treturn ERR_PTR(-ENOMEM);\n\n\treturn lookup_real(base->d_inode, dentry, flags);\n}',
    '\tdentry = d_alloc(base, name);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\nretry:\n#endif\n\tif (unlikely(!dentry))\n\t\treturn ERR_PTR(-ENOMEM);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tdentry = lookup_real(base->d_inode, dentry, flags);\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tdput(dentry);\n\t\tdentry = d_alloc(base, &susfs_fake_qstr_name);\n\t\tgoto retry;\n\t}\n\treturn dentry;\n#else\n\treturn lookup_real(base->d_inode, dentry, flags);\n#endif\n}',
    'fs/namei.c __lookup_hash')
replace_once('fs/namei.c',
    '\t\t\tif (unlikely(negative))\n\t\t\t\treturn -ENOENT;\n\t\t\tpath->mnt = mnt;',
    '\t\t\tif (unlikely(negative))\n\t\t\t\treturn -ENOENT;\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\t\t\tif (unlikely(susfs_is_inode_sus_path(dentry->d_inode))) {\n\t\t\t\tif (unlazy_walk(nd, dentry, seq))\n\t\t\t\t\treturn -ECHILD;\n\t\t\t\tdput(dentry);\n\t\t\t\treturn 0;\n\t\t\t}\n#endif\n\t\t\tpath->mnt = mnt;',
    'fs/namei.c lookup_fast RCU')
replace_once('fs/namei.c',
    '\tif (unlikely(d_is_negative(dentry))) {\n\t\tdput(dentry);\n\t\treturn -ENOENT;\n\t}',
    '\tif (unlikely(d_is_negative(dentry))) {\n\t\tdput(dentry);\n\t\treturn -ENOENT;\n\t}\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (unlikely(susfs_is_inode_sus_path(dentry->d_inode))) {\n\t\tdput(dentry);\n\t\treturn 0;\n\t}\n#endif',
    'fs/namei.c lookup_fast non-RCU')
replace_once('fs/namei.c',
    '\t\tif (unlikely(old)) {\n\t\t\tdput(dentry);\n\t\t\tdentry = old;\n\t\t}\n\t}\nout:\n\tinode_unlock_shared(inode);',
    '\t\tif (unlikely(old)) {\n\t\t\tdput(dentry);\n\t\t\tdentry = old;\n\t\t}\n\t}\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tdput(dentry);\n\t\tdentry = d_alloc_parallel(dir, &susfs_fake_qstr_name, &wq);\n\t\tif (!IS_ERR(dentry)) {\n\t\t\told = inode->i_op->lookup(inode, dentry, flags);\n\t\t\td_lookup_done(dentry);\n\t\t\tif (unlikely(old)) {\n\t\t\t\tdput(dentry);\n\t\t\t\tdentry = old;\n\t\t\t}\n\t\t\tif (dentry && !IS_ERR(dentry))\n\t\t\t\tdput(dentry);\n\t\t}\n\t\tdentry = ERR_PTR(-ENOENT);\n\t}\n#endif\nout:\n\tinode_unlock_shared(inode);',
    'fs/namei.c lookup_slow')
replace_once('fs/namei.c',
    '\tdentry = atomic_open(nd, dentry, path, file, open_flag, mode, opened);\n\tif (unlikely(create_error && !IS_ERR(dentry))) {',
    '\tdentry = atomic_open(nd, dentry, path, file, open_flag, mode, opened);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tdput(dentry);\n\t\treturn ERR_PTR(-ENOENT);\n\t}\n#endif\n\tif (unlikely(create_error && !IS_ERR(dentry))) {',
    'fs/namei.c lookup_open')

print("All hooks applied successfully.")
