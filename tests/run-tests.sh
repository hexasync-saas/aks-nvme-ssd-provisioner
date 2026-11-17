#!/bin/bash
# Runs the provisioner against a fake /sys and stubbed disk tools (tests/stubs),
# one scenario per node state seen on hexasync-westus-002. Every stub call is
# recorded, so a test can assert that no format ever ran.
#
# Usage: tests/run-tests.sh            (no root, no real disks needed)

set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/aks-nvme-ssd-provisioner.sh"
PASS=0
FAIL=0

new_node() {
    T=$(mktemp -d)
    export STATE="$T/state" SYSFS="$T/sys"
    mkdir -p "$STATE/fs" "$STATE/sb" "$T/hx-disks"
    : > "$STATE/calls"
    # Same layout as an L8as_v4 node: OS disk on nvme0n1, four local NVMe disks.
    add_disk nvme0n1 "MSFT NVMe Accelerator v1.0              "
    for d in nvme1n1 nvme2n1 nvme3n1 nvme4n1; do
        add_disk "$d" "Microsoft NVMe Direct Disk v2           "
    done
}

add_disk() {
    mkdir -p "$SYSFS/block/$1/device"
    printf '%s\n' "$2" > "$SYSFS/block/$1/device/model"
}

# Array $1 assembled from the four local disks, holding filesystem $2 (may be empty).
add_array() {
    mkdir -p "$SYSFS/block/$1/slaves"
    for d in nvme1n1 nvme2n1 nvme3n1 nvme4n1; do
        touch "$SYSFS/block/$1/slaves/$d" "$STATE/sb/$d"
    done
    [[ -n "$2" ]] && echo "$2" > "$STATE/fs/$1"
    return 0
}

# The host already has $1 mounted at the mountpoint (stack more with repeated calls).
mounted_from() {
    echo "$1" >> "$STATE/mount"
    echo "$T/hx-disks" > "$STATE/mountpoint"
}

no_format() { ! grep -qE "^(mkfs.ext4|mdadm --create)" "$STATE/calls"; }
guarded() { grep -q "^chattr +i $T/hx-disks" "$STATE/calls"; }

run() {
    OUT=$(timeout 10 env PATH="$ROOT/tests/stubs:$PATH" HOST_EXEC="$ROOT/tests/stubs/hostns" MOUNT_POINT="$T/hx-disks" \
        NODE_NAME=node-a CHECK_INTERVAL=0 bash "$SCRIPT" "$@" 2>&1)
    CODE=$?
}

called() { grep -q -- "$1" "$STATE/calls"; }

# chattr +i on the mountpoint must be recorded, and before the mount call.
immutable_before_mount() {
    local c m
    c=$(grep -n "^chattr +i $T/hx-disks" "$STATE/calls" | head -1 | cut -d: -f1)
    m=$(grep -n "^mount " "$STATE/calls" | head -1 | cut -d: -f1)
    [[ -n "$c" && -n "$m" && "$c" -lt "$m" ]]
}

check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "ok   - $name"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $name"
        echo "$OUT" | sed 's/^/       | /'
        sed 's/^/       > /' "$STATE/calls"
    fi
}

# vmss000000/001 today: md127 assembled at boot and mounted on the host.
test_already_mounted_is_left_alone() {
    new_node; add_array md127 ext4; mounted_from /dev/md127
    run --once
    check "already mounted: exit 0" test "$CODE" -eq 0
    check "already mounted: no mkfs, mdadm or mount" bash -c '! grep -qE "^(mkfs.ext4|mdadm --create|mdadm --assemble|mount) " "$STATE/calls"'
    check "already mounted: node labelled" called "kubectl label node node-a nvme-storage-ready=true"
}

# vmss000002 today: md0 is active and holds ext4, but nothing is mounted on the host.
# The deployed script printed "already mounted" here and slept forever.
test_active_array_not_mounted_is_mounted_without_format() {
    new_node; add_array md0 ext4
    run --once
    check "array not mounted: exit 0" test "$CODE" -eq 0
    check "array not mounted: mounts /dev/md0" called "mount -o defaults,noatime,discard /dev/md0 $T/hx-disks"
    check "array not mounted: never formats" bash -c '! grep -qE "^(mkfs.ext4|mdadm --create)" "$STATE/calls"'
    check "array not mounted: dir made immutable before mount" immutable_before_mount
    check "array not mounted: findmnt asked for exactly the mountpoint" called "findmnt -rn -o SOURCE --mountpoint $T/hx-disks"
    check "array not mounted: mount and its check run in the host namespace" \
        bash -c 'grep -qx "hostns mount" "$STATE/calls" && grep -qx "hostns findmnt" "$STATE/calls" && grep -qx "hostns chattr" "$STATE/calls"'
}

# After a reboot where the kernel did not assemble the array: every disk carries an md
# superblock and has no children. The deployed script saw "clean" disks and wiped them.
test_unassembled_array_is_assembled_not_wiped() {
    new_node
    for d in nvme1n1 nvme2n1 nvme3n1 nvme4n1; do touch "$STATE/sb/$d"; done
    echo ext4 > "$STATE/fs/md0"
    run --once
    check "unassembled: exit 0" test "$CODE" -eq 0
    check "unassembled: assembles" called "mdadm --assemble --run /dev/md0 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1"
    check "unassembled: never formats" bash -c '! grep -qE "^(mkfs.ext4|mdadm --create)" "$STATE/calls"'
    check "unassembled: mounts /dev/md0" called "mount -o defaults,noatime,discard /dev/md0"
}

# A new node: four blank disks.
test_blank_disks_are_formatted_and_mounted() {
    new_node
    run --once
    check "blank: exit 0" test "$CODE" -eq 0
    check "blank: creates raid0 of the 4 local disks only" \
        called "mdadm --create --run --verbose /dev/md0 --level=0 -c 512 --raid-devices=4 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1"
    check "blank: mkfs on md0" called "mkfs.ext4 -m 0 -b 4096 -E stride=128,stripe-width=512 /dev/md0"
    check "blank: mounted" called "mount -o defaults,noatime,discard /dev/md0"
    check "blank: OS disk untouched" bash -c '! grep -q nvme0n1 "$STATE/calls"'
}

test_disk_with_filesystem_is_refused() {
    new_node; echo ext4 > "$STATE/fs/nvme3n1"
    run --once
    check "foreign fs: exit 1" test "$CODE" -eq 1
    check "foreign fs: never formats" bash -c '! grep -qE "^(mkfs.ext4|mdadm --create)" "$STATE/calls"'
    check "foreign fs: label removed" called "kubectl label node node-a nvme-storage-ready- --overwrite"
    check "foreign fs: mountpoint still made immutable" guarded
}

test_partial_superblocks_are_refused() {
    new_node; touch "$STATE/sb/nvme1n1" "$STATE/sb/nvme2n1"
    run --once
    check "partial superblocks: exit 1" test "$CODE" -eq 1
    check "partial superblocks: no assemble, create or mkfs" bash -c '! grep -qE "^(mkfs.ext4|mdadm --create|mdadm --assemble)" "$STATE/calls"'
    check "partial superblocks: mountpoint still made immutable" guarded
}

test_array_without_ext4_is_refused() {
    new_node; add_array md0 ""
    run --once
    check "array without fs: exit 1" test "$CODE" -eq 1
    check "array without fs: never formats" bash -c '! grep -q "^mkfs.ext4" "$STATE/calls"'
    check "array without fs: mountpoint still made immutable" guarded
}

test_foreign_mount_is_refused() {
    new_node; add_array md0 ext4; mounted_from /dev/sdb1
    run --once
    check "foreign mount: exit 1" test "$CODE" -eq 1
    check "foreign mount: no mount call" bash -c '! grep -q "^mount " "$STATE/calls"'
    check "foreign mount: no chattr on a mounted path" bash -c '! grep -q "^chattr" "$STATE/calls"'
}

test_check_mode() {
    new_node; add_array md127 ext4; mounted_from /dev/md127
    run --check
    check "--check: 0 when mounted from the array" test "$CODE" -eq 0
    rm "$STATE/mount"
    run --check
    check "--check: 1 when not mounted" test "$CODE" -eq 1
    mounted_from /dev/nvme0n1p1
    run --check
    check "--check: 1 when mounted from the OS disk" test "$CODE" -eq 1
}

# The stub sleep drops the mount: the watcher must notice, unlabel and exit.
test_lost_mount_exits() {
    new_node; add_array md127 ext4; mounted_from /dev/md127
    run
    check "lost mount: exit 1" test "$CODE" -eq 1
    check "lost mount: label removed" called "kubectl label node node-a nvme-storage-ready- --overwrite"
}

test_no_local_disks_still_guards() {
    new_node; rm -rf "$SYSFS/block/nvme"[1-4]n1
    run --once
    check "no local disks: exit 1" test "$CODE" -eq 1
    check "no local disks: error says why" bash -c 'grep -q "no NVMe disk with model" <<< "$0"' "$OUT"
    check "no local disks: mountpoint still made immutable" guarded
}

single_disk_node() {
    new_node; rm -rf "$SYSFS/block/nvme"[2-4]n1
}

test_single_blank_disk_is_formatted() {
    single_disk_node
    run --once
    check "single blank: exit 0" test "$CODE" -eq 0
    check "single blank: mkfs on the disk, no raid" bash -c 'grep -q "^mkfs.ext4 -m 0 -b 4096 /dev/nvme1n1" "$STATE/calls" && ! grep -q "^mdadm --create" "$STATE/calls"'
    check "single blank: mounted" called "mount -o defaults,noatime,discard /dev/nvme1n1"
}

# After a reboot the disk keeps its ext4 but nothing is mounted.
test_single_disk_with_ext4_is_remounted() {
    single_disk_node; echo ext4 > "$STATE/fs/nvme1n1"
    run --once
    check "single ext4: exit 0" test "$CODE" -eq 0
    check "single ext4: never formats" no_format
    check "single ext4: mounted" called "mount -o defaults,noatime,discard /dev/nvme1n1"
}

# vmss000002: Longhorn wrote onto the OS-disk directory while nothing was mounted.
test_replicas_on_os_disk_are_not_shadowed() {
    new_node; add_array md0 ext4; mkdir -p "$T/hx-disks/replicas/pvc-1"
    run --once
    check "replicas on OS disk: exit 1" test "$CODE" -eq 1
    check "replicas on OS disk: no mount" bash -c '! grep -q "^mount " "$STATE/calls"'
}

test_leftover_files_are_reported_then_mounted() {
    new_node; add_array md0 ext4; mkdir -p "$T/hx-disks/replicas"; touch "$T/hx-disks/longhorn-disk.cfg"
    run --once
    check "leftovers: exit 0" test "$CODE" -eq 0
    check "leftovers: warns which files get hidden" bash -c 'grep -q "become hidden: longhorn-disk.cfg replicas" <<< "$0"' "$OUT"
    check "leftovers: mounted" called "mount -o defaults,noatime,discard /dev/md0"
}

test_stacked_mount_of_the_array_counts_as_mounted() {
    new_node; add_array md127 ext4; mounted_from /dev/md127; mounted_from /dev/md127
    run --check
    check "stacked: --check 0" test "$CODE" -eq 0
    run --once
    check "stacked: no new mount" bash -c '! grep -q "^mount " "$STATE/calls"'
}

for t in $(declare -F | awk '/ test_/{print $3}'); do
    "$t"
done
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
