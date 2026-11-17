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

## HexaSync provisioner (`aks-nvme-ssd-provisioner.sh`)

Deployed as `manifests/aks-nvme-ssd-provisioner.yaml` on the `nvme` node pool. It builds one ext4
filesystem from the node's local NVMe disks (model `Microsoft NVMe Direct Disk`, RAID 0 when there is
more than one) and mounts it at `/hx-disks` **in the host mount namespace**, where Longhorn uses it.

- It never formats existing data: an existing array is reused or assembled; a disk carrying any other
  signature, a partial array, an array without ext4, or a foreign mount at `/hx-disks` stops it with an
  error and removes the `nvme-storage-ready` node label.
- While nothing is mounted, `/hx-disks` on the host is made immutable so nothing writes to the OS disk.
- `--check` is the readiness probe; `--once` mounts and exits.
- The DaemonSet uses `updateStrategy: OnDelete`: replace the pods one node at a time.

Tests (no root or real disks needed): `tests/run-tests.sh`
