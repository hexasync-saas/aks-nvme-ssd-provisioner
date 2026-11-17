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
    HAS_FS=$(lsblk -no FSTYPE "$dev" | tr -d '[:space:]')
    IS_MOUNTED=$(lsblk -no MOUNTPOINT "$dev" | tr -d '[:space:]')

    if [[ "$CHILD_COUNT" -eq 1 ]] && [[ -z "$HAS_FS" ]] && [[ -z "$IS_MOUNTED" ]]; then
        echo "   [OK]   $dev: Disk is clean and available."
        UNUSED_DISKS+=("$dev")
    else
        echo "   [SKIP] $dev: Contains partitions or active filesystem."
    fi
done

SSD_NVME_DEVICE_COUNT=${#UNUSED_DISKS[@]}

# --- 2. PRE-FLIGHT CHECKS ---
if [[ $SSD_NVME_DEVICE_COUNT -eq 0 ]]; then
    echo "No unused NVMe disks found."
    
    # Verify if we are already mounted to a RAID device
    if mountpoint -q "$MOUNT_POINT"; then
        echo "Notice: $MOUNT_POINT is already mounted. Checking capacity..."
        df -h "$MOUNT_POINT"
        
        # Even if already mounted, try to ensure the label exists
        if [[ -n "$NODE_NAME" ]]; then
             echo "Ensuring node label is present..."
             kubectl label node "$NODE_NAME" nvme-storage-ready=true --overwrite || echo "Labeling failed, continuing..."
        fi
        sleep infinity
    fi
    exit 0
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

# Unmount any "ghost" mounts from previous failed attempts
umount -l "$MOUNT_POINT" || true

echo "   Mounting UUID=$DEVICE_UUID to $MOUNT_POINT..."
mount -U "$DEVICE_UUID" "$MOUNT_POINT" -o defaults,noatime,discard

# Ensure pods have write access
chmod 777 "$MOUNT_POINT"

# --- 5. NODE LABELING ---
echo "Step 7: Labeling node in Kubernetes..."
if [[ -n "$NODE_NAME" ]]; then
    if command -v kubectl >/dev/null 2>&1; then
        echo "   Labeling node $NODE_NAME with nvme-storage-ready=true..."
        kubectl label node "$NODE_NAME" nvme-storage-ready=true --overwrite
    else
        echo "   [WARNING] kubectl not found in container. Skipping labeling."
        echo "   Ensure your Dockerfile installs kubectl to enable this feature."
    fi
else
    echo "   [SKIP] NODE_NAME env var not set. Cannot label node."
fi

echo "-----------------------------------------------------------"
echo "SUCCESS: Device UUID $DEVICE_UUID mounted at $MOUNT_POINT"
echo "Internal Verification:"
df -Th "$MOUNT_POINT"
echo "-----------------------------------------------------------"

# Keep the container alive for mount propagation
sleep infinity