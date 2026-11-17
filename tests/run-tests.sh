#!/bin/bash
# Runs the provisioner against stubbed disk tools (tests/stubs), one scenario per node
# state seen on hexasync-westus-002. Every stub call is recorded, so a test can assert
# that no wipe or format ever ran.
#
# Usage: tests/run-tests.sh [script]     (default: ./aks-nvme-ssd-provisioner.sh)

set -o nounset
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=${1:-$ROOT/aks-nvme-ssd-provisioner.sh}
PASS=0; FAIL=0
DISKS="/dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1"

new_node() {
    T=$(mktemp -d); export STATE="$T"
    mkdir -p "$STATE/fs" "$STATE/sb"; : > "$STATE/calls"
    echo "$DISKS" > "$STATE/members"
    # The container always starts with the hostPath bind of the host's OS-disk directory;
    # the host itself has nothing mounted on /hx-disks.
    echo "/dev/nvme0n1p1[/hx-disks]" > "$STATE/mount"; : > "$STATE/hostmount"
}
members_of_raid() { for d in $DISKS; do echo linux_raid_member > "$STATE/fs/${d##*/}"; touch "$STATE/sb/${d##*/}"; done; }
active_raid() { members_of_raid; echo "$1" > "$STATE/raid"; echo ext4 > "$STATE/fs/${1##*/}"; }

run() {
    OUT=$(timeout 10 env PATH="$ROOT/tests/stubs:$PATH" NODE_NAME=node-a bash "$SCRIPT" "$@" 2>&1)
    CODE=$?
}
called() { grep -q -- "$1" "$STATE/calls"; }
never() { ! grep -qE "$1" "$STATE/calls"; }
before() { local a b; a=$(grep -n -- "$1" "$STATE/calls" | head -1 | cut -d: -f1); b=$(grep -n -- "$2" "$STATE/calls" | head -1 | cut -d: -f1); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; }
idle() { called "^sleep infinity"; }

check() {
    local name=$1; shift
    if "$@"; then PASS=$((PASS + 1)); echo "ok   - $name"
    else FAIL=$((FAIL + 1)); echo "FAIL - $name"; echo "$OUT" | tail -4 | sed 's/^/       | /'; fi
}

# vmss000000/001: md127 assembled and mounted on /hx-disks.
test_mounted_raid_is_left_alone() {
    new_node; active_raid /dev/md127; echo /dev/md127 > "$STATE/mount"; echo /dev/md127 > "$STATE/hostmount"
    run
    check "mounted: reaches idle" idle
    check "mounted: no mount, wipe or format" never "^(mount |wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
}

# vmss000002 today: md0 active with ext4, /hx-disks is the OS-disk directory.
test_unmounted_raid_is_mounted() {
    new_node; active_raid /dev/md0; echo "/dev/nvme0n1p1[/hx-disks]" > "$STATE/mount"
    run
    check "vmss000002: mounts /dev/md0" called "^mount /dev/md0 /hx-disks"
    check "vmss000002: mountpoint made immutable first" before "^chattr +i /hx-disks" "^mount "
    check "vmss000002: no wipe or format" never "^(wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
    check "vmss000002: reaches idle" idle
    check "vmss000002: labels for the Longhorn default disk" called "^kubectl label node node-a nvme-storage-ready=true node.longhorn.io/create-default-disk=true"
}

# After a reboot the kernel has not assembled the array yet.
test_unassembled_raid_is_assembled_not_wiped() {
    new_node; members_of_raid; echo ext4 > "$STATE/fs/md127"; echo "/dev/nvme0n1p1[/hx-disks]" > "$STATE/mount"
    run
    check "unassembled: assembles" called "^mdadm --assemble --scan"
    check "unassembled: mounts /dev/md127" called "^mount /dev/md127 /hx-disks"
    check "unassembled: no wipe or format" never "^(wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
}

# A new node: four blank disks.
test_blank_disks_are_formatted_and_mounted_on_the_host_path() {
    new_node
    run
    check "blank: creates raid0 of the 4 disks" called "^mdadm --create --run --verbose /dev/md0 --level=0 -c 512 --raid-devices=4 $DISKS"
    check "blank: formats md0" called "^mkfs.ext4 .*/dev/md0"
    check "blank: keeps the hostPath mount (no umount -l)" never "^umount"
    check "blank: mountpoint made immutable first" before "^chattr +i /hx-disks" "^mount "
    check "blank: mounts" called "^mount -U"
    check "blank: labels for the Longhorn default disk" called "^kubectl label node node-a nvme-storage-ready=true node.longhorn.io/create-default-disk=true"
}

test_mixed_disks_are_refused() {
    new_node; members_of_raid; rm "$STATE/fs/nvme4n1" "$STATE/sb/nvme4n1"; echo "/dev/nvme0n1p1[/hx-disks]" > "$STATE/mount"
    run
    check "mixed: exit 1" test "$CODE" -eq 1
    check "mixed: no wipe or format" never "^(wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
}

test_raid_without_ext4_is_refused() {
    new_node; members_of_raid; echo "/dev/nvme0n1p1[/hx-disks]" > "$STATE/mount"
    run
    check "no ext4: exit 1" test "$CODE" -eq 1
    check "no ext4: no mount, wipe or format" never "^(mount |wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
}

# Image 202602281131 regression: the hostPath bind is gone (umount -l), so the mount stays in
# the container and Longhorn uses the OS disk. Must fail instead of reporting SUCCESS.
test_mount_not_reaching_the_host_is_refused() {
    new_node; : > "$STATE/mount"
    run
    check "container-only mount: exit 1" test "$CODE" -eq 1
    check "container-only mount: node not labelled" never "^kubectl label"
    new_node; active_raid /dev/md0; : > "$STATE/mount"
    run
    check "container-only mount of an existing RAID: exit 1" test "$CODE" -eq 1
    check "container-only mount of an existing RAID: node not labelled" never "^kubectl label"
}

# A missing label means Longhorn never creates its disk: fail so the pod retries.
test_label_failure_is_not_ignored() {
    new_node; active_raid /dev/md0; touch "$STATE/kubectl-fails"
    run
    check "label fails: exit 1" test "$CODE" -eq 1
    check "label fails: does not idle as if done" never "^sleep infinity"
}

# Without hostPID, "findmnt -N 1" would read the container's own mount table.
test_without_host_pid_it_refuses() {
    new_node; touch "$STATE/no-hostpid"
    run
    check "no hostPID: exit 1" test "$CODE" -eq 1
    check "no hostPID: no mount, wipe or format" never "^(mount |wipefs|mkfs.ext4|mdadm --create|mdadm --zero)"
}

test_readiness_check() {
    new_node; active_raid /dev/md127; echo /dev/md127 > "$STATE/hostmount"
    run --check
    check "--check: ready when the host has the RAID on /hx-disks" test "$CODE" -eq 0
    check "--check: touches no disk" never "^(mount |wipefs|mkfs.ext4|mdadm)"
    new_node; active_raid /dev/md0
    run --check
    check "--check: not ready when /hx-disks is the OS-disk directory (vmss000002)" test "$CODE" -eq 1
}

for t in $(declare -F | awk '/ test_/{print $3}'); do "$t"; done
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
