import sys
import re
from pathlib import Path

def replace_once(file_path, pattern, replacement, label, flags=0):
    p = Path(file_path)
    content = p.read_text()
    
    # Use re.search to find the block
    if re.search(pattern, content, flags):
        new_content = re.sub(pattern, replacement, content, count=1, flags=flags)
        p.write_text(new_content)
        print(f"  OK: {label}")
    else:
        print(f"  FATAL: anchor not found — {label}", file=sys.stderr)
        # Debugging aid: print a snippet of the file if it fails
        print(f"  DEBUG: Could not match pattern in {file_path}", file=sys.stderr)
        sys.exit(1)

# 1. KSU & SUSFS Wiring
Path('fs/Makefile').write_text(Path('fs/Makefile').read_text() + '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n')
Path('drivers/Makefile').write_text(Path('drivers/Makefile').read_text() + '\nobj-$(CONFIG_KSU) += kernelsu/\n')
replace_once('drivers/Kconfig', 'source "drivers/mpsd/Kconfig"', 'source "drivers/mpsd/Kconfig"\n\nsource "drivers/kernelsu/Kconfig"', 'drivers/Kconfig kernelsu')
replace_once('fs/Kconfig', 'endmenu', 'config KSU_SUSFS\n\tbool "KSU SUSFS"\n\tdepends on KSU\nconfig KSU_SUSFS_SUS_PATH\n\tbool "SUS PATH"\n\tdepends on KSU_SUSFS\nconfig KSU_SUSFS_SUS_MAP\n\tbool "SUS MAP"\n\tdepends on KSU_SUSFS\nconfig KSU_SUSFS_SUS_KSTAT\n\tbool "SUS KSTAT"\n\tdepends on KSU_SUSFS\n\nendmenu', 'fs/Kconfig susfs')

# 2. fs/open.c — faccessat hook
replace_once('fs/open.c', r'SYSCALL_DEFINE3\(faccessat,\s*int,\s*dfd,\s*const\s*char\s*__user\s*\*\,\s*filename,\s*int,\s*mode\)\n\{', '#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_ptr, int *mode, int *flags);\n#endif\nSYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif', 'fs/open.c faccessat')

# 3. fs/exec.c — do_execveat_common hook
replace_once('fs/exec.c', r'static\s*int\s*do_execveat_common\(int\s*fd,\s*struct\s*filename\s*\*filename,', '#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\nstatic int do_execveat_common(int fd, struct filename *filename,', 'fs/exec.c extern')
replace_once('fs/exec.c', r'if\s*\(IS_ERR\(filename\)\)\n\t\treturn\s*PTR_ERR\(filename\);', 'if (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n#ifdef CONFIG_KSU\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif', 'fs/exec.c execveat hook')

# 4. kernel/sys.c — setresuid hook
replace_once('kernel/sys.c', r'\tretval\s*=\s*security_task_fix_setuid\(new,\s*old,\s*LSM_SETID_RES\);\n\tif\s*\(retval\s*<\s*0\)\n\t\tgoto\s*error;\n\n\treturn\s*commit_creds\(new\);', '\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n\tif (retval < 0)\n\t\tgoto error;\n\n#ifdef CONFIG_KSU\n\textern int ksu_handle_setresuid(uid_t *ruid, uid_t *euid, uid_t *suid);\n\tksu_handle_setresuid(&ruid, &euid, &suid);\n\tnew->uid = make_kuid(old->user_ns, ruid);\n\tnew->euid = make_kuid(old->user_ns, euid);\n\tnew->suid = make_kuid(old->user_ns, suid);\n#endif\n\n\treturn commit_creds(new);', 'kernel/sys.c setresuid')

# 5. kernel/reboot.c — reboot hook
replace_once('kernel/reboot.c', r'SYSCALL_DEFINE4\(reboot,\s*int,\s*magic1,\s*int,\s*magic2,\s*unsigned\s*int,\s*cmd,\n\t\tvoid\s*__user\s*\*\,\s*arg\)\n\{', '#ifdef CONFIG_KSU\nextern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n#endif\nSYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{', 'kernel/reboot.c extern')
replace_once('kernel/reboot.c', r'if\s*\(\(cmd\s*==\s*LINUX_REBOOT_CMD_POWER_OFF\)\s*&&\s*!pm_power_off\)\n\t\tcmd\s*=\s*LINUX_REBOOT_CMD_HALT;\n\n\tmutex_lock\(&reboot_mutex\);', 'if ((cmd == LINUX_REBOOT_CMD_POWER_OFF) && !pm_power_off)\n\t\tcmd = LINUX_REBOOT_CMD_HALT;\n\n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\tmutex_lock(&reboot_mutex);', 'kernel/reboot.c sys_reboot hook')

# 6. fs/proc/base.c — SUS_MAP hook
replace_once('fs/proc/base.c', '#include <linux/oom.h>', '#include <linux/oom.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux/susfs_def.h>\n#endif', 'fs/proc/base.c includes')
replace_once('fs/proc/base.c', r'if\s*\(IS_ERR\(mm\)\)\n\t\treturn\s*PTR_ERR\(mm\);\n\n\tfile->private_data\s*=\s*mm;', 'if (IS_ERR(mm))\n\t\treturn PTR_ERR(mm);\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n\t\tmmput(mm);\n\t\treturn -EACCES;\n\t}\n#endif\n\n\tfile->private_data = mm;', 'fs/proc/base.c __mem_open hook')

# 7. fs/namei.c — SUS_PATH hooks (Updated Regex for Resilience)
replace_once('fs/namei.c', '#include <asm/uaccess.h>', '#include <asm/uaccess.h>\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n#include <linux/susfs_def.h>\nextern bool susfs_is_inode_sus_path(struct inode *inode);\nextern const struct qstr susfs_fake_qstr_name;\n#endif', 'fs/namei.c includes')

# The failing hook: atomic_open is highly variable in 4.9, using a generic match
replace_once('fs/namei.c', r'dentry\s*=\s*atomic_open\(nd,\s*dentry,\s*path,\s*file,\s*open_flag,\s*mode,\s*opened\);', 
             'dentry = atomic_open(nd, dentry, path, file, open_flag, mode, opened);\n#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (dentry && !IS_ERR(dentry) && dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tdput(dentry);\n\t\treturn ERR_PTR(-ENOENT);\n\t}\n#endif', 'fs/namei.c lookup_open')

print("All hooks applied successfully.")
