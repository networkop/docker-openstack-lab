# Virtual Arista+Openstack lab

## Prerequisites

Linux Docker host with 7GB (mini demo) or 20GB (full demo) of RAM, enabled nested virutalisation (/dev/kvm and `grep vmx /proc/cpuinfo`) and a generated SSH key (ssh-keygen)

Required packages:
* git
* [docker-topo](https://github.com/networkop/docker-topo)

## 1. Building Ubuntu VM containers

### 1.1 Download Ubuntu cloud image, build and run it inside a container:

```
wget https://cloud-images.ubuntu.com/xenial/20190207/xenial-server-cloudimg-amd64-disk1.img
qemu-img info xenial-server-cloudimg-amd64-disk1.img
qemu-img resize xenial-server-cloudimg-amd64-disk1.img 10G
./build.sh
./run.sh
```

### 1.2 Install devstack inside the container

SSH into the container

```
./ssh.sh
```

Install the required packages (assuming Openstack Pike):

```
sudo su
apt-get update && apt-get install lldpad lldpd -y
useradd -s /bin/bash -d /opt/stack -m stack
echo "stack ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sudo su stack 
cd ~
git clone https://git.openstack.org/openstack-dev/devstack
cd devstack
git checkout stable/pike
```

create the following local.conf file

```
[[local|localrc]]
ADMIN_PASSWORD=nomoresecret
DATABASE_PASSWORD=stackdb
RABBIT_PASSWORD=stackqueue
SERVICE_PASSWORD=$ADMIN_PASSWORD

IP_VERSION=4
disable_service tempest
disable_service horizon
disable_service swift
disable_service cinder

Q_AGENT=linuxbridge
Q_USE_SECGROUP=True
ENABLE_TENANT_VLANS=True
ML2_VLAN_RANGES=provider:10:40
LB_INTERFACE_MAPPINGS=provider:br-vlan
NEUTRON_CREATE_INITIAL_NETWORKS=False


# Uncomment on compute nodes
#SERVICE_HOST=10.0.0.2
#MYSQL_HOST=$SERVICE_HOST
#RABBIT_HOST=$SERVICE_HOST
#GLANCE_HOSTPORT=$SERVICE_HOST:9292
#ENABLED_SERVICES=n-cpu,q-agt,n-api-meta,placement-client,n-novnc
#MULTI_HOST=1
```

create and destroy stack to download all of the packages:

```
./stack.sh
./unstack.sh
```
### 1.3 Create a new openstack docker image

From the docker host run:

```
docker exec -it os bash -c "virsh destroy os"
docker commit os openstack:latest
docker rm -f os
```


## 2. Creating the virtual lab 

Full demo requires 20GB and mini demo requires 7GB of RAM

### 2.1 Building the lab topology

For full demo with 2 Openstack nodes + 3 vEOS run this:

```
docker-topo --create openstack.yml
```

For mini demo with 1 Openstack node + 1 vEOS run this:

```
docker-topo --create mini.yml
```

> Sometimes there's no internet access from inside the containers, to turn it on do:
   ```docker network inspect os_net-0 --format '{{range .IPAM.Config }}{{.Subnet}}{{ end }}'
   sudo iptables -t nat -A POSTROUTING -s  172.31.0.0/16 -j MASQUERADE
   ```

To access devices setup the requires aliases:

```
source aliasrc
```

And now you can ssh into the lab devices with a single command (e.g. for OS node 2):

```
core@node2 ~/docker-openstack-lab $ os-2
Warning: Permanently added '172.20.0.6' (ECDSA) to the list of known hosts.
ubuntu@os-2:~$ 
```

## 2.3 Initialise Openstack node 1

SSH into the node and su into the `stack` user:

```
os-1
sudo su stack
cd /opt/stack/devstack
```

Bring up the stack:

```
./stack.sh
```

## 2.2 (Full demo) Initialise Openstack node 2

SSH into the node and change the SERVICE_HOST variable to match the IP of the Openstack node 1

```
os-2
sudo su stack
cd /opt/stack/devstack
vi /opt/stack/devstack/local.conf
```

Bring up the stack:

```
./stack.sh
```

on `OS-1` discover the second node
```
./tools/discover_hosts.sh
```

and verify that two hypervisors exist:

```
source openrc admin admin
openstack hypervisor list
+----+---------------------+-----------------+------------+-------+
| ID | Hypervisor Hostname | Hypervisor Type | Host IP    | State |
+----+---------------------+-----------------+------------+-------+
|  1 | os-1                | QEMU            | 172.20.0.5 | up    |
|  2 | os-2                | QEMU            | 172.20.0.6 | up    |
+----+---------------------+-----------------+------------+-------+
```

## 3. Arista integration

### 3.1 Arista-side integration

Confirm that the below already exist on CVX (veos-1):

```
!
cvx
   no shutdown
   !
   service openstack
      no shutdown
      !
      region RegionOne
         username admin tenant admin secret nomoresecret
         keystone auth-url http://169.254.0.10/identity/v3/
!
```

### 3.2 Openstack-side integration

Install arista plugin on Neutron Server:

```
sudo pip install "networking-arista>=2017.2,<2018.1"
```

Adding arista to mechanism drivers

```
sed -ri 's/^(mechanism_drivers.*)/\1,arista/' /etc/neutron/plugins/ml2/ml2_conf.ini 
grep mechanism_driver /etc/neutron/plugins/ml2/ml2_conf.ini
```

Adding Arista ML2 driver config

```
echo "[ml2_arista]" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "eapi_host=169.254.0.1" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "eapi_username=admin" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "eapi_password=admin" >> /etc/neutron/plugins/ml2/ml2_conf.ini
```

Adding VLAN interface to access CVX inband
```
sudo ip link add link br-vlan name vlan10 type vlan id 10
sudo ip addr add dev vlan10 169.254.0.10/16
sudo ip addr add dev vlan10 169.254.0.10/16
```

Restart neutron server

```
sudo systemctl restart devstack@q-svc
```

### 3.3 Verification

Neutron Server:

```
sudo systemctl status devstack@q-svc | grep Active
   Active: active (running) since Thu 2019-02-14 15:09:29 UTC; 27s ago

```

CVX:

```
vEOS-1#show openstack regions 
Region: RegionOne
Sync Status: Completed
```


```
vEOS-1#show network physical-topology hosts 
Unique Id            Hostname
-------------------- ------------------------------
5254.004c.7645       localhost
5254.007a.1157       localhost
5254.006e.ed68       vEOS-1
5254.00ab.3172       vEOS-2
5254.00ee.a4fc       vEOS-3
```

### 3.4 LLDP configuration

If Compute devices show up as `localhost` do this on each Openstack node:

```
stack@os-1:/etc/neutron/plugins/ml2$ sudo lldpcli
[lldpcli] # configure system hostname os-1
```

To control which interfaces to enable LLDP use this command

```
stack@os-1:/etc/neutron/plugins/ml2$ sudo lldpcli
[lldpcli] # configure system interface pattern ens*,!ens2
```

The above `configure` commands can be saved in  `/etc/lldpd.d/{ANY_NAME}.conf` for persistence

> To find out which node DHCP agent is hosted on run `openstack network agent list`

The good result should look like:

```
vEOS-1#show network physical-topology hosts
Unique Id            Hostname
-------------------- ------------------------------
5254.007a.1157       os-1
5254.004c.7645       os-2
5254.006e.ed68       vEOS-1
5254.00ab.3172       vEOS-2
5254.00ee.a4fc       vEOS-3
```

## 4. Basic L2 Demo

Create a private network:
```
openstack network create --provider-network-type vlan \
                         --provider-physical-network provider \
                         --provider-segment 11 \
                         net-1
openstack subnet create --subnet-range 10.0.0.0/24 \
                        --network net-1 \
                        sub-1
```

Create a public external network

```
openstack network create --provider-network-type vlan \
                         --provider-physical-network provider \
                         --provider-segment 40 \
                         --external \
                         net-2
openstack subnet create --subnet-range 40.0.0.0/24  \
                        --network net-2 \
                        sub-2
```

Create neutron router and attach it to both networks
```
openstack router create router-1
openstack router add subnet router-1 sub-1
openstack router set --external-gateway net-2 router-1
```

Create a VM
```
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        VM-1
openstack server show VM-1
```

To Connect to VM console do this:

```
openstack console url show VM-1
ssh -L 10.83.30.252:6080:192.168.240.5:6080 ubuntu@192.168.240.5
```

Otherwise (if vnc proxy is not running, we can setup a floating IP)

```
openstack floating ip create net-2
openstack floating ip set --port b2f7d91c-db29-4bdd-a732-a370e349445d \
                          4030f477-1168-44c7-adb7-70e20e73a650
```

And allow inbound ICMP/SSH traffic
```
openstack port show b2f7d91c-db29-4bdd-a732-a370e349445d | grep security
openstack security group rule create --ingress --dst-port 22  f4ce0525-94f5-4a40-9581-fa7dabda86b4
openstack security group rule create --ingress --proto icmp  f4ce0525-94f5-4a40-9581-fa7dabda86b4
```

On vEOS-1 create a default gateway for external network:

```
!
interface Vlan40
   ip address 40.0.0.1/24
!
```

Now VM-1 should be able to ping/ssh to vEOS-1 and vice versa

```
vEOS-1#ssh -l cirros 40.0.0.11
Warning: Permanently added '40.0.0.11' (RSA) to the list of known hosts.
cirros@40.0.0.11's password: 
$ ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue 
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast qlen 1000
    link/ether fa:16:3e:ea:6e:64 brd ff:ff:ff:ff:ff:ff
    inet 10.0.0.25/24 brd 10.0.0.255 scope global eth0
    inet6 fe80::f816:3eff:feea:6e64/64 scope link 
       valid_lft forever preferred_lft forever
```

## 5. Cleanup

Openstack: 

```
openstack server delete VM-1
openstack router unset --external-gateway router-1
openstack router remove subnet router-1 sub-1
openstack router delete router-1

openstack subnet delete sub-2
openstack network delete net-2
openstack subnet delete sub-1
openstack network delete net-1
```

vEOS-1:

```
no interface Vlan40
```


## 6. L3 plugin

### 6.1 Installation

```
sed -ri 's/^(service_plugins = ).*/\1,arista_l3/' /etc/neutron/neutron.conf
grep service_plugins /etc/neutron/neutron.conf
```

```
echo "[l3_arista]" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "primary_l3_host=169.254.0.1" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "primary_l3_host_username=admin" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "primary_l3_host_password=admin" >> /etc/neutron/plugins/ml2/ml2_conf.ini
```

Restart neutron server

```
sudo systemctl restart devstack@q-svc
```

Configure Subnet, Router and a VM
```
openstack network create --provider-network-type vlan \
                         --provider-physical-network provider \
                         --provider-segment 11 \
                         net-1
openstack subnet create --subnet-range 10.0.0.0/24 \
                        --network net-1 \
                        sub-1
openstack router create router-1
openstack router add subnet router-1 sub-1
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        --availability-zone nova:os-2:os-2 \
                        VM-1
```

SSH from CVX/vEOS-1
```
openstack port list
openstack port show aed10d22-b2af-4a49-84ed-75935cd31551 | grep security
openstack security group rule create --ingress --dst-port 22  f4ce0525-94f5-4a40-9581-fa7dabda86b4
openstack security group rule create --ingress --proto icmp  f4ce0525-94f5-4a40-9581-fa7dabda86b4
```

password = cubswin:)

```
[admin@vEOS-1 ~]$ ping 10.0.0.6
PING 10.0.0.6 (10.0.0.6) 56(84) bytes of data.
64 bytes from 10.0.0.6: icmp_seq=1 ttl=64 time=32.0 ms
^C
--- 10.0.0.6 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 32.002/32.002/32.002/0.000 ms

[admin@vEOS-1 ~]$ ssh cirros@10.0.0.6
Warning: Permanently added '10.0.0.6' (RSA) to the list of known hosts.
cirros@10.0.0.6's password: 
$ 
```

## 7. VLAN-VNI mapping

## 8. VXLAN with HPB

## Troubleshooting

Neutron logs
```
journalctl -f -u devstack@q-svc.service
```
