#!/usr/bin/env bash
set -Eeuo pipefail
echo "Reverting KSU and SUSFS patches..."
git checkout -- fs/open.c fs/exec.c kernel/sys.c fs/proc/base.c fs/namei.c fs/Makefile
rm -f fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
echo "Revert complete. Tree is clean."
