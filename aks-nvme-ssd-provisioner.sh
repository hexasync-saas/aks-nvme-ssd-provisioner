#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# --- CONFIGURATION ---
RAID_DEVICE=${RAID_DEVICE:-/dev/md0}
RAID_CHUNK_SIZE=${RAID_CHUNK_SIZE:-512}
FILESYSTEM_BLOCK_SIZE=${FILESYSTEM_BLOCK_SIZE:-4096}
MOUNT_POINT="/hx-disks"
# NODE_NAME is passed from the Downward API in the DaemonSet spec
NODE_NAME=${NODE_NAME:-""}

# --- HOST VIEW ---
# Inside the pod, /hx-disks is a hostPath bind, so the container's own mount table cannot tell
# "mounted on the host" from "mounted in this container only" (image 202602281131 printed
# SUCCESS for a mount the host never saw). PID 1 is the host's init (hostPID: true), so
# "findmnt -N 1" reads the host's mount table. Without hostPID every check below would
# silently fall back to the container's view, so refuse to run.
if [[ "$(readlink /proc/1/ns/mnt)" == "$(readlink /proc/self/ns/mnt)" ]]; then
    echo "ERROR: cannot see the host mount table (the DaemonSet needs hostPID: true)."
    exit 1
fi

# True when the host has a whole data device (md RAID, or one raw NVMe disk) mounted on
# $MOUNT_POINT. When the mount is missing, the host has no entry at all: /hx-disks is then
# a plain directory on the OS disk.
host_disk_mounted() {
    findmnt -N 1 -rn -o SOURCE --mountpoint "$MOUNT_POINT" | tail -n 1 \
        | grep -Eq '^/dev/(md[0-9]+|nvme[0-9]+n[0-9]+)$'
}

# Exit 1 unless the mount just made is visible on the host.
require_host_mount() {
    if ! host_disk_mounted; then
        echo "ERROR: $MOUNT_POINT is mounted in this container but NOT on the host; Longhorn would use the OS disk."
        exit 1
    fi
    echo "   Verified on the host: $(findmnt -N 1 -rn -o SOURCE --mountpoint "$MOUNT_POINT" | tail -n 1) on $MOUNT_POINT"
}

# Label only after the host mount is verified. With the Longhorn setting
# create-default-disk-labeled-nodes=true, Longhorn creates its disk on /hx-disks only once
# node.longhorn.io/create-default-disk=true is set, instead of racing the provisioner and
# writing its disk config to the OS-disk directory.
label_node() {
    if [[ -z "$NODE_NAME" ]]; then
        echo "   [SKIP] NODE_NAME env var not set. Cannot label node."
        return 0
    fi
    # A missing label means Longhorn never creates the disk, so fail and let the pod retry:
    # the restarted pod finds the host mount and only relabels.
    if ! kubectl label node "$NODE_NAME" nvme-storage-ready=true node.longhorn.io/create-default-disk=true --overwrite; then
        echo "ERROR: labeling node $NODE_NAME failed."
        exit 1
    fi
}

# Readiness probe: ready only while the host has the disk mounted on $MOUNT_POINT.
if [[ "${1:-}" == "--check" ]]; then
    if host_disk_mounted; then exit 0; fi
    exit 1
fi

echo "-----------------------------------------------------------"
echo "Starting Hexasync NVMe SSD Provisioner (UUID Mode)..."
echo "Target Node: ${NODE_NAME:-Unknown}"
echo "-----------------------------------------------------------"

# --- 1. SMART FILTERING ---
echo "Step 1: Scanning for strictly unused NVMe disks..."

UNUSED_DISKS=()
# Get all raw NVMe disks (e.g., /dev/nvme0n1, /dev/nvme1n1)
ALL_NVME=$(lsblk -pnro NAME,TYPE | grep 'disk' | grep 'nvme' | awk '{print $1}')

for dev in $ALL_NVME; do
    # A. Skip nvme0n1 specifically (Azure OS disk safety)
    if [[ "$dev" == *"/nvme0n1" ]]; then
        echo "   [SKIP] $dev: Identified as System/OS disk."
        continue
    fi

    # B. Count children (partitions). If > 1, it has partitions.
    CHILD_COUNT=$(lsblk -nlo NAME "$dev" | wc -l)
    
    # C. Check for existing Filesystem or Mountpoint
    # lsblk FSTYPE is always empty in the container (no udev db); blkid -p reads the disk.
    HAS_FS=$(blkid -p -s TYPE -o value "$dev" 2>/dev/null || true)
    IS_MOUNTED=$(lsblk -no MOUNTPOINT "$dev" | tr -d '[:space:]')

    if [[ "$CHILD_COUNT" -eq 1 ]] && [[ -z "$HAS_FS" ]] && [[ -z "$IS_MOUNTED" ]]; then
        echo "   [OK]   $dev: Disk is clean and available."
        UNUSED_DISKS+=("$dev")
    else
        echo "   [SKIP] $dev: Contains partitions or active filesystem."
        IN_USE_COUNT=$((${IN_USE_COUNT:-0} + 1))
    fi
done

SSD_NVME_DEVICE_COUNT=${#UNUSED_DISKS[@]}

if [[ $SSD_NVME_DEVICE_COUNT -gt 0 ]] && [[ ${IN_USE_COUNT:-0} -gt 0 ]]; then
    echo "ERROR: some NVMe disks are blank and some are in use; refusing to format. Check the disks by hand."
    exit 1
fi

# --- 2. PRE-FLIGHT CHECKS ---
if [[ $SSD_NVME_DEVICE_COUNT -eq 0 ]]; then
    echo "No unused NVMe disks found."
    
    # Already mounted on the HOST? Not "mountpoint -q" and not the container's findmnt:
    # /hx-disks is a hostPath volume, so it is always a mountpoint in here.
    if host_disk_mounted; then
        echo "Notice: $MOUNT_POINT is already mounted on the host. Checking capacity..."
        df -h "$MOUNT_POINT"
        echo "Ensuring node label is present..."
        label_node
        sleep infinity
    fi

    # The RAID exists but is not mounted (node reboot, pod restart): mount it, never format it.
    mdadm --assemble --scan || true
    TARGET_DEV=$(lsblk -pnro NAME,TYPE | awk '$2 ~ /^raid/ {print $1}' | sort -u | head -n 1)
    if [[ -z "$TARGET_DEV" ]] || [[ "$(blkid -p -s TYPE -o value "$TARGET_DEV" 2>/dev/null || true)" != "ext4" ]]; then
        echo "ERROR: no ext4 RAID device to mount and no blank disk to format. Check the disks by hand."
        exit 1
    fi
    echo "Found existing RAID $TARGET_DEV: mounting it (no format)..."
    chattr +i "$MOUNT_POINT" || true   # nothing can write to the OS disk under the mountpoint
    mount "$TARGET_DEV" "$MOUNT_POINT" -o defaults,noatime,discard
    chmod 777 "$MOUNT_POINT"
    require_host_mount
    label_node
    sleep infinity
fi

echo "Step 2: Found $SSD_NVME_DEVICE_COUNT devices to use: ${UNUSED_DISKS[*]}"

# --- 3. PROVISIONING ---
echo "Step 3: Cleaning old metadata and wiping signatures..."
# Force stop existing raid if it's currently defined
mdadm --stop "$RAID_DEVICE" || true

for dev in "${UNUSED_DISKS[@]}"; do
    echo "       Wiping $dev..."
    mdadm --zero-superblock "$dev" || true
    wipefs -a "$dev"
done

# Wait for wipes to settle in the kernel
udevadm settle

if [[ $SSD_NVME_DEVICE_COUNT -eq 1 ]]; then
    echo "Step 4: Single disk detected. Formatting..."
    mkfs.ext4 -F -m 0 -b $FILESYSTEM_BLOCK_SIZE "${UNUSED_DISKS[0]}"
    TARGET_DEV="${UNUSED_DISKS[0]}"
else
    echo "Step 4: Multiple disks detected. Creating RAID 0..."
    mdadm --create --run --verbose "$RAID_DEVICE" --level=0 -c ${RAID_CHUNK_SIZE} \
        --raid-devices=${SSD_NVME_DEVICE_COUNT} "${UNUSED_DISKS[@]}"
    
    # Wait for the /dev/md0 node to exist
    udevadm settle

    # Calculate RAID optimization (Stride and Stripe-width)
    STRIDE=$(expr $RAID_CHUNK_SIZE \* 1024 / $FILESYSTEM_BLOCK_SIZE || true)
    STRIPE_WIDTH=$(expr $SSD_NVME_DEVICE_COUNT \* $STRIDE || true)

    echo "Step 5: Formatting RAID device $RAID_DEVICE with Ext4..."
    mkfs.ext4 -F -m 0 -b $FILESYSTEM_BLOCK_SIZE -E stride=$STRIDE,stripe-width=$STRIPE_WIDTH "$RAID_DEVICE"
    TARGET_DEV="$RAID_DEVICE"
fi

# --- 4. MOUNTING BY UUID ---
echo "Step 6: Mounting by UUID..."
udevadm settle

# Capture the UUID of the newly formatted device
DEVICE_UUID=$(blkid -s UUID -o value "$TARGET_DEV")

if [[ -z "$DEVICE_UUID" ]]; then
    echo "ERROR: Could not find UUID for $TARGET_DEV. Formatting may have failed."
    exit 1
fi

mkdir -p "$MOUNT_POINT"

# Do NOT "umount -l $MOUNT_POINT" here: inside the container that removes the hostPath
# mount itself, and the RAID would then be mounted in the container only, not on the host.
chattr +i "$MOUNT_POINT" || true   # nothing can write to the OS disk under the mountpoint

echo "   Mounting UUID=$DEVICE_UUID to $MOUNT_POINT..."
mount -U "$DEVICE_UUID" "$MOUNT_POINT" -o defaults,noatime,discard

# Ensure pods have write access
chmod 777 "$MOUNT_POINT"
require_host_mount

# --- 5. NODE LABELING ---
echo "Step 7: Labeling node in Kubernetes..."
label_node

echo "-----------------------------------------------------------"
echo "SUCCESS: Device UUID $DEVICE_UUID mounted at $MOUNT_POINT"
echo "Internal Verification:"
df -Th "$MOUNT_POINT"
echo "-----------------------------------------------------------"

# Keep the container alive for mount propagation
sleep infinity