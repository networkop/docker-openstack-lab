docker create --name os --privileged  -h openstack  openstack
docker network connect bridge os
docker network connect net1 os
docker start  os
