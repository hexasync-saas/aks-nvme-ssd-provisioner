# Reconstructed from the running image
# hexasyncregistry.azurecr.io/hexasync/aks-nvme-ssd-provisioner:202602281522
# (sha256:84df82890cd2df01eb271eeabc3a21df64b83157843625a62f9080f878142d8f):
# Debian 12.13 slim, the packages below, and a kubectl v1.35.2 binary.
FROM debian:12-slim

RUN apt-get update \
 && apt-get -y install --no-install-recommends ca-certificates curl e2fsprogs kmod mdadm mount nvme-cli udev util-linux \
 && apt-get -y clean && rm -rf /var/lib/apt/lists/*

ARG KUBECTL_VERSION=v1.35.2
RUN curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl

COPY aks-nvme-ssd-provisioner.sh /usr/local/bin/aks-nvme-ssd-provisioner.sh
RUN chmod +x /usr/local/bin/aks-nvme-ssd-provisioner.sh
ENTRYPOINT ["aks-nvme-ssd-provisioner.sh"]
