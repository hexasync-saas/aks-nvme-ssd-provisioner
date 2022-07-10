
docker build . --tag aks-nvme-ssd-provisioner:202207100848;
docker tag aks-nvme-ssd-provisioner:202207100848 registry.sandbox.beehexa.com/hexasync/aks-nvme-ssd-provisioner:202207100848; 
docker push registry.sandbox.beehexa.com/hexasync/aks-nvme-ssd-provisioner:202207100848