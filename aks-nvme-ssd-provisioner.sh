#!/bin/bash
# Prepares the local NVMe disks of an AKS node as one ext4 filesystem mounted at
# $MOUNT_POINT in the HOST mount namespace (Longhorn's disk path).
#
# Rules this script keeps:
# - The mount is made in the host mount namespace (nsenter, needs hostPID), so it
#   does not depend on this pod's lifetime and survives a pod restart or rollout.
# - "Already mounted" is decided by the HOST's mount table, never by the
#   container's view: inside the container the hostPath volume is always a
#   mountpoint, which is how /hx-disks ended up on the OS disk unnoticed.
# - Existing data is never formatted. An array or filesystem that already exists is
#   assembled/mounted; anything unexpected (a signature on a non-member disk, a
#   partial array, a non-ext4 array, a foreign mount) stops the script with an error.
# - While nothing is mounted, the host directory is made immutable so nothing
#   (Longhorn) can write onto the OS disk underneath the mountpoint.
#
# Usage: aks-nvme-ssd-provisioner.sh            ensure mounted, then keep watching
#        aks-nvme-ssd-provisioner.sh --once     ensure mounted, then exit
#        aks-nvme-ssd-provisioner.sh --check    exit 0 only if mounted correctly (readiness probe)

set -o errexit
set -o nounset
set -o pipefail
shopt -s nullglob

RAID_DEVICE=${RAID_DEVICE:-/dev/md0}
RAID_CHUNK_SIZE=${RAID_CHUNK_SIZE:-512}
FILESYSTEM_BLOCK_SIZE=${FILESYSTEM_BLOCK_SIZE:-4096}
MOUNT_POINT=${MOUNT_POINT:-/hx-disks}
NVME_MODEL=${NVME_MODEL:-Microsoft NVMe Direct Disk}
NODE_NAME=${NODE_NAME:-}
NODE_LABEL=${NODE_LABEL:-nvme-storage-ready}
CHECK_INTERVAL=${CHECK_INTERVAL:-30}
SYSFS=${SYSFS:-/sys}
EXPECTED_DEVICE=""
# Prefix that runs a command in the host mount namespace.
read -r -a HOST <<< "${HOST_EXEC-nsenter -t 1 -m --}"

# To stderr, so a log line never ends up in a captured $(...) value.
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

label_node() {
    [[ -n "$NODE_NAME" ]] || return 0
    kubectl label node "$NODE_NAME" "$1" --overwrite --request-timeout=10s >/dev/null || log "WARNING: could not set node label '$1'"
}

die() {
    log "ERROR: $*"
    label_node "${NODE_LABEL}-"
    exit 1
}

# Local (ephemeral) NVMe disks, chosen by model so the OS disk is never a candidate
# whatever its device number.
find_local_disks() {
    local dir model
    for dir in "$SYSFS"/block/nvme*n1; do
        model=$(tr -s ' ' < "$dir/device/model" | sed 's/ *$//') || return 1
        if [[ "$model" == "$NVME_MODEL"* ]]; then
            echo "/dev/${dir##*/}"
        fi
    done
}

# md device (as /dev/mdX) built from any of the given disks, empty if none.
find_array() {
    local md slave disk
    for md in "$SYSFS"/block/md*; do
        for slave in "$md"/slaves/*; do
            for disk in "$@"; do
                if [[ "/dev/${slave##*/}" == "$disk" ]]; then
                    echo "/dev/${md##*/}"
                    return 0
                fi
            done
        done
    done
}

array_member_count() {
    local slaves=("$SYSFS/block/${1##*/}"/slaves/*)
    echo "${#slaves[@]}"
}

has_partitions() {
    local parts=("$SYSFS/block/${1##*/}/${1##*/}"p*)
    (( ${#parts[@]} > 0 ))
}

# Low-level probe (-p) reads the device itself; lsblk's FSTYPE needs the udev
# database, which the container does not have, so it always reads empty here.
signature() { blkid -p -s TYPE -o value "$1" 2>/dev/null || true; }

# Topmost mount at $MOUNT_POINT (findmnt lists stacked mounts bottom-up), empty if none.
host_mount_source() { "${HOST[@]}" findmnt -rn -o SOURCE --mountpoint "$MOUNT_POINT" 2>/dev/null | tail -n 1 || true; }

expected_device() {
    local disks=("$@") array
    array=$(find_array "${disks[@]}")
    if [[ -n "$array" ]]; then
        echo "$array"
    elif (( ${#disks[@]} == 1 )); then
        echo "${disks[0]}"
    fi
}

is_mounted_correctly() {
    local expected=$1 source
    source=$(host_mount_source)
    [[ -n "$expected" && "$source" == "$expected" ]]
}

create_filesystem() {
    local disks=("$@") disk stride stripe_width
    for disk in "${disks[@]}"; do
        if has_partitions "$disk"; then die "$disk has partitions; refusing to wipe it"; fi
        if [[ -n "$(signature "$disk")" ]]; then
            die "$disk has a '$(signature "$disk")' signature but is not part of an array; refusing to wipe it"
        fi
    done

    log "All ${#disks[@]} local NVMe disks are blank: creating the filesystem"
    if (( ${#disks[@]} == 1 )); then
        mkfs.ext4 -m 0 -b "$FILESYSTEM_BLOCK_SIZE" "${disks[0]}"
        return 0
    fi
    mdadm --create --run --verbose "$RAID_DEVICE" --level=0 -c "$RAID_CHUNK_SIZE" \
        --raid-devices="${#disks[@]}" "${disks[@]}"
    udevadm settle || true
    stride=$(( RAID_CHUNK_SIZE * 1024 / FILESYSTEM_BLOCK_SIZE ))
    stripe_width=$(( ${#disks[@]} * stride ))
    mkfs.ext4 -m 0 -b "$FILESYSTEM_BLOCK_SIZE" -E "stride=$stride,stripe-width=$stripe_width" "$RAID_DEVICE"
}

# Brings the disks to a state with exactly one device holding the filesystem.
prepare_device() {
    local disks=("$@") disk with_superblock=0 array

    array=$(find_array "${disks[@]}")
    if [[ -n "$array" ]]; then
        if [[ "$(array_member_count "$array")" -ne ${#disks[@]} ]]; then
            die "$array has $(array_member_count "$array") members but there are ${#disks[@]} local NVMe disks; refusing to guess"
        fi
        log "Found existing array $array"
        return 0
    fi

    if (( ${#disks[@]} == 1 )) && [[ "$(signature "${disks[0]}")" == "ext4" ]]; then
        log "Single disk ${disks[0]} already holds ext4 (no format)"
        return 0
    fi

    for disk in "${disks[@]}"; do
        if mdadm --examine "$disk" >/dev/null 2>&1; then with_superblock=$((with_superblock + 1)); fi
    done

    if (( with_superblock == ${#disks[@]} )); then
        log "All disks carry an md superblock: assembling the existing array (no format)"
        mdadm --assemble --run "$RAID_DEVICE" "${disks[@]}"
        udevadm settle || true
    elif (( with_superblock > 0 )); then
        die "$with_superblock of ${#disks[@]} disks carry an md superblock; refusing to guess"
    else
        create_filesystem "${disks[@]}"
    fi
}

mount_on_host() {
    local device=$1 fstype source
    fstype=$(signature "$device")
    [[ "$fstype" == "ext4" ]] || die "$device holds '${fstype:-no filesystem}', expected ext4; refusing to format existing data"

    "${HOST[@]}" mount -o defaults,noatime,discard "$device" "$MOUNT_POINT"
    is_mounted_correctly "$device" || die "mounted $device but the host reports $MOUNT_POINT from '$(host_mount_source)'"
    "${HOST[@]}" chmod 777 "$MOUNT_POINT"
    log "Mounted $device at $MOUNT_POINT on the host"
}

# Sets EXPECTED_DEVICE to the device mounted at $MOUNT_POINT.
# Runs while nothing is mounted at $MOUNT_POINT on the host, before anything that can
# fail: from here on a write to $MOUNT_POINT fails instead of landing on the OS disk.
guard_mountpoint() {
    local leftovers
    "${HOST[@]}" mkdir -p "$MOUNT_POINT"
    "${HOST[@]}" chattr +i "$MOUNT_POINT" || log "WARNING: could not make $MOUNT_POINT immutable"
    # Mounting hides what is already in the directory. Longhorn replicas written onto
    # the OS disk must be moved off first, not silently shadowed.
    if [[ -n "$("${HOST[@]}" find "$MOUNT_POINT/replicas" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
        die "$MOUNT_POINT/replicas on the OS disk is not empty; move those Longhorn replicas off this node before mounting"
    fi
    leftovers=$("${HOST[@]}" ls -A "$MOUNT_POINT" 2>/dev/null | tr '\n' ' ')
    [[ -z "$leftovers" ]] || log "WARNING: mounting over files on the OS disk, which become hidden: $leftovers"
}

local_disks() {
    local out
    out=$(find_local_disks) || die "could not read the model of the NVMe disks under $SYSFS/block"
    [[ -n "$out" ]] || die "no NVMe disk with model '$NVME_MODEL' found"
    echo "$out"
}

ensure_mounted() {
    local disks expected source
    source=$(host_mount_source)
    [[ -n "$source" ]] || guard_mountpoint

    local listed
    listed=$(local_disks)
    mapfile -t disks <<< "$listed"
    log "Local NVMe disks: ${disks[*]}"

    expected=$(expected_device "${disks[@]}")
    if is_mounted_correctly "$expected"; then
        log "$MOUNT_POINT is already mounted from $expected on the host"
    elif [[ -n "$source" ]]; then
        die "$MOUNT_POINT on the host is mounted from $source, not from the local NVMe disks; refusing to touch it"
    else
        prepare_device "${disks[@]}"
        expected=$(expected_device "${disks[@]}")
        [[ -n "$expected" ]] || die "no device holds the filesystem after preparing the disks"
        mount_on_host "$expected"
    fi
    "${HOST[@]}" df -h "$MOUNT_POINT" || true
    label_node "${NODE_LABEL}=true"
    EXPECTED_DEVICE=$expected
}

main() {
    local mode=${1:-} disks misses
    if [[ "$mode" == "--check" ]]; then
        mapfile -t disks < <(find_local_disks || true)
        [[ -n "${disks[0]:-}" ]] || exit 1
        is_mounted_correctly "$(expected_device "${disks[@]}")"
        exit $?
    fi

    log "Starting HexaSync NVMe SSD provisioner on ${NODE_NAME:-unknown node}"
    ensure_mounted
    [[ "$mode" == "--once" ]] && exit 0

    # The mount belongs to the host, but keep watching it: if it disappears, drop the
    # label and exit so the restarted pod mounts it again.
    misses=0
    while true; do
        sleep "$CHECK_INTERVAL"
        if is_mounted_correctly "$EXPECTED_DEVICE"; then
            misses=0
        else
            misses=$((misses + 1))
            (( misses < 2 )) || die "$MOUNT_POINT is no longer mounted from $EXPECTED_DEVICE"
        fi
    done
}

main "$@"
