# aks-nvme-ssd-provisioner
AKS NVMe disk provisioner to be used with the sig-storage-local-static-provisioner

Inspired by https://github.com/brunsgaard/eks-nvme-ssd-provisioner


To use, create an AKS cluster and attach a user nodepool with NVMe-enabled size and the `kubernetes.azure.com/aks-local-ssd` label:


```
az aks nodepool add -g <resourcegrou> --cluster-name <clustername> -n nvme -s Standard_L8s_v2 --labels kubernetes\.azure\.com\/aks-local-ssd=true -c 1
```

Apply the `storage-local-static-provisioner` (from this [repo](https://github.com/kubernetes-sigs/sig-storage-local-static-provisioner)) to create a storageClass and the PVs corresponding to the NVMe('s) present on the nodes:

```
kubectl apply -f manifests/storage-local-static-provisioner.yaml
```

The init container will prepare the NVMe disks for use, and the app container will create the PersistentVolumes to be used by your Pods.

To benchmark, run:

```
kubectl apply -f bench.yaml
```

```
kubectl apply -f ./manifests/aks-nvme-ssd-provisioner.yaml
```

## How the mount reaches the host

The DaemonSet mounts the host directory `/hx-disks` into the pod with `mountPropagation: Bidirectional`.
The script mounts the RAID **on top of** that hostPath bind, and the mount propagates to the host.

- **Never `umount` `/hx-disks` inside the pod.** That removes the hostPath bind itself; the next mount then
  exists in the container only, the script still reports success, and Longhorn writes to the OS disk.
- **Never decide "mounted" from inside the container.** `/hx-disks` is a hostPath volume, so it is always a
  mountpoint there. The script reads the host's mount table instead (`hostPID: true`, `findmnt -N 1`).
- The host mount outlives the pod: deleting or rolling the pod does not unmount it.

## Longhorn

Set the Longhorn setting `create-default-disk-labeled-nodes` to `true` (with `default-data-path` = `/hx-disks/`).
The script labels a node `node.longhorn.io/create-default-disk=true` only after it has verified the mount on
the host, so Longhorn never creates its disk on the OS-disk directory underneath. The setting only affects
nodes that Longhorn sees for the first time.

## Detecting a missing mount

A missing mount does not always raise a Longhorn error. A node that Longhorn sees as new accepts the
OS-disk directory silently. Check any of:

- The DaemonSet pod is not Ready (the readiness probe runs `aks-nvme-ssd-provisioner.sh --check`).
- The Longhorn disk on that node reports the OS-disk size (~124 GB) instead of the RAID (~1.9 TB on
  `Standard_L8as_v4`).
- On the host: `kubectl debug node/<node> -it --profile=sysadmin --image=ubuntu -- grep hx-disks /proc/1/mountinfo`
  shows no `/dev/md*` line. (`chroot /host findmnt` shows the debug pod's view, not the host's.)

## Manual recovery (RAID exists, not mounted on the host)

1. In the provisioner pod on that node: `cat /proc/mdstat`, `blkid -p /dev/md0` (expect `ext4`),
   `findmnt -S /dev/md0` (expect nothing), and check that `/hx-disks/replicas` is empty.
2. Mount **without unmounting first**: `mount -o defaults,noatime,discard /dev/md0 /hx-disks && chmod 777 /hx-disks`.
3. Confirm on the host with the `grep hx-disks /proc/1/mountinfo` command above.
4. In Longhorn, remove the node's old disk (its recorded disk UUID belongs to the OS-disk directory), then add
   `/hx-disks` again as a new disk. Replicas rebuild onto it.
