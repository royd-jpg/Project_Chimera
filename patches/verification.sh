#!/usr/bin/env bash
# Quick local check for KSU and SUSFS hooks
set -e
if ! command -v nm >/dev/null; then echo "Install binutils/llvm-nm"; exit 1; fi

VMLINUX="${1:-kernel-out/vmlinux}"
if [ ! -f "$VMLINUX" ]; then
    echo "Usage: ./verification.sh [path/to/vmlinux]"
    exit 1
fi

REQUIRED=(
    "ksu_handle_setresuid"
    "ksu_handle_execveat"
    "ksu_handle_faccessat"
    "susfs_is_inode_sus_path"
)

echo "Verifying symbols in $VMLINUX..."
FAIL=0
for sym in "${REQUIRED[@]}"; do
    if nm "$VMLINUX" | grep -q " $sym"; then
        echo "✅ Hook intact: $sym"
    else
        echo "❌ Hook MISSING: $sym"
        FAIL=1
    fi
done

[ $FAIL -eq 0 ] && echo "All hooks verified." || exit 1
