
docker build . --tag aks-nvme-ssd-provisioner:202207100841;
docker tag aks-nvme-ssd-provisioner:202207100827 registry.sandbox.beehexa.com/hexasync/aks-nvme-ssd-provisioner:202207100841; 
docker push registry.sandbox.beehexa.com/hexasync/aks-nvme-ssd-provisioner:202207100841