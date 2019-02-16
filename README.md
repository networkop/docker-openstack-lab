# Virtual Arista+Openstack lab

## Table of contents
1. [Building Ubuntu VM containers](#1-building-ubuntu-vm-containers)
2. [Creating the virtual lab](#2-creating-the-virtual-lab)
3. [Arista integration](#3-arista-integration)
4. [Basic L2 Demo](#4-basic-l2-demo)
5. [Cleanup](#5-cleanup)
6. [L3 plugin](#6-l3-plugin)
7. [VLAN-VNI mapping](#7-vlan-vni-mapping)
8. [VXLAN with HPB](#8-vxlan-with-hpb)
9. [Troubleshooting](#9-troubleshooting)

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
   ```
   docker network inspect os_net-0 --format '{{range .IPAM.Config }}{{.Subnet}}{{ end }}'
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

### 7.1 Arista configuration

On CVX:

```
cvx
   service openstack
      region RegionOne
         networks map vlan 10 - 40 vni 5010 - 5040
   !
   service vxlan
      no shutdown
!
interface Loopback99
   ip address 169.254.0.1/32
!
```

On all vEOS devices create a VXLAN loopback and configure VXLAN service. Interfaces MUST be converted to L3 otherwise a loop will occur.

```
interface loopback0
  ip address 10.10.10.1/32
!
no interface Vlan10
!
interface Ethernet1
  no switchport
  ip address 169.254.12.1/24
!
interface Ethernet2
  no switchport
  ip address 169.254.13.1/24
!
interface vxlan 1
  vxlan source-interface loopback0
  vxlan controller-client
!
router ospf 1
network 10.10.10.0/24 area 0.0.0.0
network 169.254.0.0/16 area 0.0.0.0
!
```

> OSPF is used to establish L3 reachability between Loopbacks over the pre-existing VLAN10

### 7.2 Neutron configuration

> We only need to update the CVX/vEOS-1 IP address (pointing to Management IP)

```
sudo grep _host /etc/neutron/plugins/ml2/ml2_conf.ini 
eapi_host=172.20.0.2
primary_l3_host=172.20.0.4
```

restart Neutron:

```
sudo systemctl restart devstack@q-svc.service
```
### 7.3 Simpe L2 demo

Create a new network:

```
openstack network create --provider-network-type vlan \
                         --provider-physical-network provider \
                         --provider-segment 11 \
                         net-1
openstack subnet create --subnet-range 10.0.0.0/24 \
                        --network net-1 \
                        sub-1
```

Create a couple of VMs on different compute nodes

```
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        --availability-zone nova:os-1:os-1 \
                        VM-1
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        --availability-zone nova:os-2:os-2 \
                        VM-2
```

### 7.4 Verification

Confirm VXLAN-VNI mapping

```
vEOS-3#show vxlan vni
VNI to VLAN Mapping for Vxlan1
VNI        VLAN       Source       Interface       802.1Q Tag 
---------- ---------- ------------ --------------- ---------- 
5011       11*        vcs          Ethernet2       11     
```

Check that MAC tables contains all 3 MACs (VM-1, VM-2 and  DHCP)

```
vEOS-3#show vxlan address-table 
          Vxlan Mac Address Table
----------------------------------------------------------------------

VLAN  Mac Address     Type     Prt  VTEP             Moves   Last Move
----  -----------     ----     ---  ----             -----   ---------
  11  26b7.df10.a340  RECEIVED  Vx1  10.10.10.2       1       0:01:01 ago
  11  fa16.3e33.4766  RECEIVED  Vx1  10.10.10.2       1       0:00:45 ago
  11  fa16.3e92.cee9  RECEIVED  Vx1  10.10.10.2       1       0:01:01 ago
```

Console into VM-1 and ping VM-2

```
openstack console url show VM-1
```

### 7.5 Adding L3 router

Note that L3 router is now setup on vEOS-3 (172.20.0.4), since vEOS-1 doesn't know anything about VXLAN-VNI mappings

```
openstack router create router-1
openstack router add subnet router-1 sub-1
```

### 7.6 Verification

Check the SVI is created

```
vEOS-1# sh run int vlan 11
interface Vlan11
   ip address 10.0.0.1/24
```

Ping VM-1 and SSH into VM-2

```
vEOS-3#ping  10.0.0.7
PING 10.0.0.7 (10.0.0.7) 72(100) bytes of data.
80 bytes from 10.0.0.7: icmp_seq=1 ttl=64 time=20.0 ms
80 bytes from 10.0.0.7: icmp_seq=2 ttl=64 time=24.0 ms
80 bytes from 10.0.0.7: icmp_seq=3 ttl=64 time=20.0 ms
80 bytes from 10.0.0.7: icmp_seq=4 ttl=64 time=24.0 ms
80 bytes from 10.0.0.7: icmp_seq=5 ttl=64 time=20.0 ms

--- 10.0.0.7 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 76ms
rtt min/avg/max/mdev = 20.001/21.601/24.002/1.964 ms, pipe 2, ipg/ewma 19.001/20.774 ms
vEOS-3#ssh -l cirros 10.0.0.6
Warning: Permanently added '10.0.0.6' (RSA) to the list of known hosts.
cirros@10.0.0.6's password: 
$ 
$ 
```

## 8. VXLAN with HPB

### 8.1 Neutron configuration


Add VLAN ranges for each TOR 

```
sudo sed -ri 's/^(network_vlan_ranges.*)/\1,vEOS-2:100:200,vEOS-3:300:400/' /etc/neutron/plugins/ml2/ml2_conf.ini 
grep mechanism_driver /etc/neutron/plugins/ml2/ml2_conf.ini
```

Add network <-> Linuxbridge mappings (os-1)
```
sudo sed -ri 's/^(physical_interface_mappings = ).*/\1vEOS-2:br-vlan/' /etc/neutron/plugins/ml2/ml2_conf.ini 
grep physical_interface_mappings /etc/neutron/plugins/ml2/ml2_conf.ini
sudo systemctl restart devstack@q-agt.service
sudo systemctl status devstack@q-agt.service |  grep Active
```

Add network <-> Linuxbridge mappings (os-2)
```
sudo sed -ri 's/^(physical_interface_mappings = ).*/\1vEOS-2:br-vlan/' /etc/neutron/plugins/ml2/ml2_conf.ini 
grep physical_interface_mappings /etc/neutron/plugins/ml2/ml2_conf.ini
sudo systemctl restart devstack@q-agt.service
sudo systemctl status devstack@q-agt.service |  grep Active
```

Turn off VXLAN and Enable HPB

```
sudo sed -ri 's/^(enable_vxlan =).*/\1 False/' /etc/neutron/plugins/ml2/ml2_conf.ini 
echo "[ml2_arista]" >> /etc/neutron/plugins/ml2/ml2_conf.ini
echo "manage_fabric = True" >> /etc/neutron/plugins/ml2/ml2_conf.ini
```

Create bridge mappings on all compute nodes

```
sudo sed -ri 's/^(physical_interface_mappings.*)/\1,vEOS-1:br-vlan,vEOS-2:br-vlan/' /etc/neutron/plugins/ml2/ml2_conf.ini 
grep physical_interface_mappings /etc/neutron/plugins/ml2/ml2_conf.ini
```

Restart Neutron server process

```
sudo systemctl restart devstack@q-svc.service
sudo systemctl status devstack@q-svc.service | grep Active
```

### 9.4 Simpe L2 demo

Create a new network:

```
openstack network create net-1
openstack subnet create --subnet-range 10.0.0.0/24 \
                        --network net-1 \
                        sub-1
```

Create a couple of VMs on different compute nodes

```
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        --availability-zone nova:os-1:os-1 \
                        VM-1
openstack server create --flavor cirros256 \
                        --image cirros-0.3.5-x86_64-disk \
                        --network net-1  \
                        --availability-zone nova:os-2:os-2 \
                        VM-2
```


## 9. Troubleshooting


### 9.1 Openstack side


Neutron server logs
```
journalctl -f -u devstack@q-svc.service
```

L2 agent logs:

```
journalctl -f -u devstack@q-agt.service
```

Check logs for sync messages

```
journalctl -xe -u devstack@q-svc.service | grep EOS
```


Neutron port -> Linux interface -> Linux bridge mapping

```
ubuntu@os-1:~$ openstack port list | grep 10.0.0.6
| f8e48f8a-348c-4c4a-b68f-f18afcc9b4b6 |      | fa:16:3e:33:47:66 | ip_address='10.0.0.6', subnet_id='103a846d-ee19-42d7-ad79-22b7ed279c2c' | ACTIVE |
ubuntu@os-1:~$ ip link | grep f8e48f8a-34
59: tapf8e48f8a-34: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast master brq514ceff9-f8 state UNKNOWN mode DEFAULT group default qlen 1000
ubuntu@os-1:~$ brctl show brq514ceff9-f8
bridge name	bridge id		STP enabled	interfaces
brq514ceff9-f8		8000.26b7df10a340	no		br-vlan.11
							tap1b54c022-76
							tap594cb928-f6
							tapf8e48f8a-34
```

tcpdump on bridge/tap/vlan port

```
ubuntu@os-1:~$ sudo tcpdump -i br-vlan.11 icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on br-vlan.11, link-type EN10MB (Ethernet), capture size 262144 bytes
15:05:41.664773 IP 10.0.0.1 > 10.0.0.2: ICMP echo request, id 12801, seq 1, length 80
15:05:41.664967 IP 10.0.0.2 > 10.0.0.1: ICMP echo reply, id 12801, seq 1, length 80
```

IPtables 

```
ubuntu@os-1:~$ sudo iptables -L -n -v
< snip >
Chain FORWARD (policy ACCEPT 165 packets, 15840 bytes)
 pkts bytes target     prot opt in     out     source               destination         
13029 2817K neutron-filter-top  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
13029 2817K neutron-linuxbri-FORWARD  all  --  *      *       0.0.0.0/0            0.0.0.0/0  
< snip >
Chain neutron-linuxbri-FORWARD (1 references)
 pkts bytes target     prot opt in     out     source               destination         
  183 18592 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-out tap594cb928-f6 --physdev-is-bridged /* Accept all packets when port is trusted. */
 2090  208K ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-out tap1b54c022-76 --physdev-is-bridged /* Accept all packets when port is trusted. */
 2332  230K neutron-linuxbri-sg-chain  all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-out tapf8e48f8a-34 --physdev-is-bridged /* Direct traffic from the VM interface to the security group chain. */
  202 21924 neutron-linuxbri-sg-chain  all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-in tapf8e48f8a-34 --physdev-is-bridged /* Direct traffic from the VM interface to the security group chain. */
< snip >
Chain neutron-linuxbri-sg-chain (2 references)
 pkts bytes target     prot opt in     out     source               destination         
 2332  230K neutron-linuxbri-if8e48f8a-3  all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-out tapf8e48f8a-34 --physdev-is-bridged /* Jump to the VM specific chain. */
  202 21924 neutron-linuxbri-of8e48f8a-3  all  --  *      *       0.0.0.0/0            0.0.0.0/0            PHYSDEV match --physdev-in tapf8e48f8a-34 --physdev-is-bridged /* Jump to the VM specific chain. */
 3261  321K ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0        
< snip >
Chain neutron-linuxbri-if8e48f8a-3 (1 references)
 pkts bytes target     prot opt in     out     source               destination         
 2297  227K RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            state RELATED,ESTABLISHED /* Direct packets associated with a known session to the RETURN chain. */
    2   695 RETURN     udp  --  *      *       0.0.0.0/0            10.0.0.6             udp spt:67 dpt:68
    0     0 RETURN     udp  --  *      *       0.0.0.0/0            255.255.255.255      udp spt:67 dpt:68
   17  1684 RETURN     icmp --  *      *       0.0.0.0/0            0.0.0.0/0           
   14   760 RETURN     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:22
    0     0 RETURN     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0           
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set NIPv4f4ce0525-94f5-4a40-9581- src
    0     0 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            state INVALID /* Drop packets that appear related to an existing connection (e.g. TCP ACK/FIN) but do not have an entry in conntrack. */
    2   648 neutron-linuxbri-sg-fallback  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Send unmatched traffic to the fallback chain. */

< snip >
Chain neutron-linuxbri-sg-fallback (2 references)
 pkts bytes target     prot opt in     out     source               destination         
 1285  413K DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Default drop rule for unmatched traffic. */
```

The last rule is the default drop-all, so if traffic is not going through due to IPTables - the `pkts` counter should increase. For example, delete the ICMP allow rule:

```
buntu@os-1:~$ openstack security group rule list  | grep icmp
| 23915fa5-8cea-4fb3-ba08-0166acc17693 | icmp        | 0.0.0.0/0 |            | None                                 | f4ce0525-94f5-4a40-9581-fa7dabda86b4 |
ubuntu@os-1:~$ openstack security group rule  delete 23915fa5-8cea-4fb3-ba08-0166acc17693
```

Start the ping from Arista towards one of the VMs

```
vEOS-3#ping 10.0.0.7 timeout 1 repeat 1000
PING 10.0.0.7 (10.0.0.7) 72(100) bytes of data.
```

On the node where VM is sitting start watching the DROP counter

```
watch -n 0.5 "sudo iptables -L -n -v | grep \"Default drop\""
```

### 9.2 Arista side 

CVX management service (from all switches)

```
vEOS-1#show management cvx |  i Status
  Status: Enabled
```

CVX VXLAN controller service (from CVX)

```
vEOS-1#show service vxlan status | i Service
Vxlan Controller Service is   : running
```

CVX VXLAN controller service (from TOR switches )

```
vEOS-2#sh vxlan controller status | grep status
Controller connection status        : Established
```

CVX openstack service

```
vEOS-1#show openstack regions  | i Status
Sync Status: Completed
```
