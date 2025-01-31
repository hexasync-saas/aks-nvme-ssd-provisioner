#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SSD_NVME_DEVICE_LIST=($(ls /sys/block | grep nvme | xargs -I. echo /dev/. || true))
SSD_NVME_DEVICE_COUNT=${#SSD_NVME_DEVICE_LIST[@]}
RAID_DEVICE=${RAID_DEVICE:-/dev/md0}
RAID_CHUNK_SIZE=${RAID_CHUNK_SIZE:-512}  # Kilo Bytes
FILESYSTEM_BLOCK_SIZE=${FILESYSTEM_BLOCK_SIZE:-4096}  # Bytes
STRIDE=$(expr $RAID_CHUNK_SIZE \* 1024 / $FILESYSTEM_BLOCK_SIZE || true)
STRIPE_WIDTH=$(expr $SSD_NVME_DEVICE_COUNT \* $STRIDE || true)

# if [[ "$(ls -A /pv-disks)" ]]
# then
#   echo 'Volumes already present in "/pv-disks"'
#   echo -e "\n$(ls -Al /pv-disks | tail -n +2)\n"
#   echo "I assume that provisioning already happend, doing nothing!"
  
#   UUID=$(blkid -s UUID -o value $SSD_NVME_DEVICE_LIST)
#   umount /pv-disks/$UUID
#   umount /dev/md0
#   mdadm --stop /dev/md0
#   mdadm --zero-superblock $SSD_NVME_DEVICE_LIST
#   mdadm --remove /dev/md0
# fi

# Checking if provisioning already happend
if [[ "$(ls -A /hx-disks)" ]]
then
  echo 'Volumes already present in "/hx-disks"'
  echo -e "\n$(ls -Al /hx-disks | tail -n +2)\n"
  echo "I assume that provisioning already happend, doing nothing!"
  sleep infinity
fi

# Perform provisioning based on nvme device count
case $SSD_NVME_DEVICE_COUNT in
"0")
  echo 'No devices found of type "Microsoft NVMe Direct Disk"'
  echo "Maybe your node selectors are not set correct"
  exit 1
  ;;
"1")
  mkfs.ext4 -m 0 -b $FILESYSTEM_BLOCK_SIZE $SSD_NVME_DEVICE_LIST
  DEVICE=$SSD_NVME_DEVICE_LIST
  ;;
*)
  mdadm --create --verbose $RAID_DEVICE --level=0 -c ${RAID_CHUNK_SIZE} \
    --raid-devices=${#SSD_NVME_DEVICE_LIST[@]} ${SSD_NVME_DEVICE_LIST[*]}
  while [ -n "$(mdadm --detail $RAID_DEVICE | grep -ioE 'State :.*resyncing')" ]; do
    echo "Raid is resyncing.."
    sleep 1
  done
  echo "Raid0 device $RAID_DEVICE has been created with disks ${SSD_NVME_DEVICE_LIST[*]}"
  mkfs.ext4 -m 0 -b $FILESYSTEM_BLOCK_SIZE -E stride=$STRIDE,stripe-width=$STRIPE_WIDTH $RAID_DEVICE
  DEVICE=$RAID_DEVICE
  ;;
esac

UUID=$(blkid -s UUID -o value $DEVICE)
mkdir -p /hx-disks
mount -o defaults,noatime,discard,nobarrier --uuid $UUID /hx-disks
echo "Device $DEVICE has been mounted to /hx-disks"
echo "NVMe SSD provisioning is done and I will go to sleep now"

#sleep infinity