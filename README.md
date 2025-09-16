## Install

curl -sSL https://raw.githubusercontent.com/luargil/dokploy-install/main/install.sh | bash


## Update

curl -sSL https://raw.githubusercontent.com/luargil/dokploy-install/main/install.sh | bash -s update

## Uninstall

docker stack rm dokploy

docker volume rm -f dokploy-postgres-database redis-data-volume

docker network rm -f dokploy-network

sudo rm -rf /etc/dokploy