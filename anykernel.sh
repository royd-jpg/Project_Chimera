properties() { '
kernel.string=Chimera Mk9 by AegisDevLabs
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=star2lte
device.name2=star2ltexx
device.name3=SM-G965F
device.name4=SM-G965U
device.name5=SM-G965N
supported.versions=9-16
'; }

BLOCK=/dev/block/by-name/BOOT
IS_SLOT_DEVICE=0
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto

. tools/ak3-core.sh

dump_boot
write_boot
