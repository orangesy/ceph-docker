# Nextcloud

- use wonderfall/nextcloud:10.0 & mysql

## init Nextcloud rbd image

- `rbd create nextcloud-app --size 2048`
- `rbd create nextcloud-config --size 2048`
- `rbd create nextcloud-data --size 2048`
- `rbd create nextcloud-db --size 2048`
- `docker build -t develop/nextcloud:10.0 .`
-PV's yaml ceph mon IP

## Create Nextcloud

- `kubectl create -f pv/nextcloud-app-pv.yaml  -f pv/nextcloud-config-pv.yaml -f pv/nextcloud-data-pv.yaml -f pv/nextcloud-db-pv.yaml -f nextcloud-db.yaml -f nextcloud.yaml`
