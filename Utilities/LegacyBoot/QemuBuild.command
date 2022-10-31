#!/bin/bash

# Build QEMU image, example:
# qemu-system-x86_64 -drive file=$QEMU_IMAGE/OpenCore.RO.raw -serial stdio \
#   -usb -device usb-kbd -device usb-mouse -s -m 8192

cd "$(dirname "$0")" || exit 1

if [ ! -f boot ] || [ ! -f boot0 ] || [ ! -f boot1f32 ]; then
  echo "Boot files are missing from this package!"
  echo "You probably forgot to build DuetPkg first."
  exit 1
fi

if [ "$(which qemu-img)" = "" ]; then
  echo "QEMU installation missing"
  exit 1
fi

if [ ! -d ROOT ]; then
  echo "No ROOT directory with ESP partition contents"
  exit 1
fi

if [ "$(uname)" = "Linux" ]; then
  IMAGE=OpenCore.qcow2
  DIR="$IMAGE.d"
  NBD=/dev/nbd0

  rm -rf "$DIR" "$IMAGE"
  mkdir -p "$DIR"

  # Create 200M MS-DOS disk image with 1 FAT32 partition
  modprobe nbd
  qemu-img create -f qcow2 "$IMAGE" 200M
  qemu-nbd -c "$NBD" "$IMAGE"
  fdisk "$NBD" << END
  o
  n
  p
  1
  2048
  409599
  t
  c
  w
END
  mkfs.vfat -F32 ${NBD}p1

  # Copy boot0 into MBR
  dd if=boot0 of="$NBD" bs=1 count=446 conv=notrunc

  # Copy boot1f32 into FAT32 Boot Record Information
  dd if=${NBD}p1 count=1 of=origbs
  cp -v boot1f32 newbs
  dd if=origbs of=newbs skip=3 seek=3 bs=1 count=87 conv=notrunc
  dd if=/dev/random of=newbs skip=496 seek=496 bs=1 count=14 conv=notrunc
  dd if=newbs of=${NBD}p1

  # Copy boot and ESP into FAT32 file system
  mount ${NBD}p1 "$DIR"
  cp -v boot "$DIR"
  cp -rv ROOT/* "$DIR"

  sleep 2
  umount -R "$DIR"
  qemu-nbd -d "$NBD"
  rm -r "$DIR"
fi

if [ "$(uname)" = "Darwin" ]; then
  rm -f OpenCore.dmg.sparseimage OpenCore.RO.raw OpenCore.RO.dmg
  hdiutil create -size 200m  -layout "UNIVERSAL HD"  -type SPARSE  -o OpenCore.dmg
  newDevice=$(hdiutil attach -nomount OpenCore.dmg.sparseimage |head -n 1 |  awk  '{print $1}')
  echo newdevice "$newDevice"

  diskutil partitionDisk "${newDevice}" 1 MBR fat32 TEST R

  # boot install script
  diskutil list
  N=$(echo "$newDevice" | tr -dc '0-9')
  echo "Will be installed to Disk ${N}"


  if [[ ! $(diskutil info disk"${N}" |  sed -n 's/.*Device Node: *//p') ]]
  then
    echo Disk "$N" not found
    exit 1
  fi

  FS=$(diskutil info disk"${N}"s1 | sed -n 's/.*File System Personality: *//p')
  echo "$FS"

  if [ "$FS" != "MS-DOS FAT32" ]
  then
    echo "No FAT32 partition to install"
    exit 1
  fi

  # Write MBR
  sudo fdisk -f boot0 -u /dev/rdisk"${N}"

  diskutil umount disk"${N}"s1
  sudo dd if=/dev/rdisk"${N}"s1 count=1  of=origbs
  cp -v boot1f32 newbs
  sudo dd if=origbs of=newbs skip=3 seek=3 bs=1 count=87 conv=notrunc
  dd if=/dev/random of=newbs skip=496 seek=496 bs=1 count=14 conv=notrunc
  sudo dd if=newbs of=/dev/rdisk"${N}"s1
  diskutil mount disk"${N}"s1

  cp -v boot "$(diskutil info  disk"${N}"s1 |  sed -n 's/.*Mount Point: *//p')"
  cp -rv ROOT/* "$(diskutil info  disk"${N}"s1 |  sed -n 's/.*Mount Point: *//p')"

  if [ "$(diskutil info  disk"${N}" |  sed -n 's/.*Content (IOContent): *//p')" == "FDisk_partition_scheme" ]
  then
  sudo fdisk -e /dev/rdisk"$N" <<-MAKEACTIVE
  p
  f 1
  w
  y
  q
MAKEACTIVE
  fi

  hdiutil detach "$newDevice"
  hdiutil convert -format UDRO OpenCore.dmg.sparseimage -o OpenCore.RO.dmg
  qemu-img convert -f dmg -O raw OpenCore.RO.dmg OpenCore.RO.raw
fi
