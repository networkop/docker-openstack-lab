#!/bin/bash

echo 'Sleeping to wait for all interfaces to be connected'
sleep 5

echo 'Making sure that character device /dev/kvm exists and setting the right permissions'
if [ ! -c /dev/kvm ]; then
  echo "Requirement not satisfied: /dev/kvm not present"
  exit 1
fi
chown root:kvm /dev/kvm
ls -la /dev/kvm


echo '############################'
echo '# Stealing the IP off eth0 #'
echo '############################'

HOSTNAME=$(hostname)
INTF="eth0"
IPPREFIX=$(ip -o -f inet addr show dev $INTF | awk 'NR==1 {print $4}')
IPADDR=$(echo $IPPREFIX | awk 'NR==1{split($1,a,"/");print a[1]}')
PREFIXLEN=$(echo $IPPREFIX | awk 'NR==1{split($1,a,"/");print a[2]}')
GW=$(ip route get 8.8.8.8 | awk 'NR==1 {print $3}')
ip addr flush dev eth0
ip addr

NETWORK_BOOTSTRAP="""
- echo $IPADDR $HOSTNAME >> /etc/hosts
- hostnamectl set-hostname $HOSTNAME
- ip link add dev br-vlan type bridge
"""


NETWORK_CONFIGURATION="""
version: 1
config:
  - type: physical
    name: ens2
  - type: bridge
    name: lxcbr0
    bridge_interfaces:
      - ens2
"""

NETWORK_CONFIGURATION="""
config: disabled
"""

NETWORK_CONFIGURATION="""
version: 2
ethernets:
  ens2:
    addresses: [ $IPPREFIX ]
    gateway4: $GW
    mtu: 1280
    nameservers:
        addresses: [ 1.1.1.1 ]
  ens3:
    addresses: [ 0.0.0.0 ]
    mtu: 1280
bridges:
  br-vlan:
    interfaces: [ ens3 ]
    addresses: [ 0.0.0.0 ]
    parameters:
      stp: false
      forward-delay: 0
"""


NETWORK_INTERFACES="""|
  auto ens2 
  iface ens2 inet manual
  mtu 1280
  auto lxcbr0
  iface lxcbr0 inet static
    address $IPPREFIX
    gateway $GW
    bridge_ports ens2
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
    dns-nameservers 1.1.1.1
"""

RUN_COMMANDS="""
- sed -i 's/HOST_IP=.*/HOST_IP=$IPADDR/ /opt/stack/devstack/local.conf'
"""

echo '#####################################'
echo '# Saving ip and hostname parameters #'
echo '#####################################'

rm -f /tmp/meta-data

cat << EOF > /tmp/meta-data
instance-id: $HOSTNAME
local-hostname: $HOSTNAME
EOF

rm -f /tmp/user-data
cat << EOF > /tmp/user-data
#cloud-config
password: root
chpasswd: { expire: False}
ssh_pwauth: True
ssh_authorized_keys: 
- ssh-rsa $SSH
bootcmd: $NETWORK_BOOTSTRAP
runcmd: $RUN_COMMANDS
EOF

rm -f /tmp/network-config
cat << EOF > /tmp/network-config
$NETWORK_CONFIGURATION
EOF

INTFS=$(ls /sys/class/net/ | grep 'eth\|ens\|eno')

echo '####################'
echo '# Creating bridges #'
echo '####################'
BRIDGE=""
for i in $INTFS; do
  BRIDGE=$BRIDGE"ip link add name br-$i type bridge;"
  BRIDGE=$BRIDGE"ip link set br-$i up;"
  BRIDGE=$BRIDGE"ip link set $i master br-$i;"
  BRIDGE=$BRIDGE"echo 16384 > /sys/class/net/br-$i/bridge/group_fwd_mask;"
  
done

echo -e $BRIDGE
eval $BRIDGE

echo '====='
bridge link
echo '====='
brctl show
echo '====='

echo '#############################'
echo '# Starting libvirt services #'
echo '#############################'

/usr/sbin/libvirtd &
/usr/sbin/virtlogd &

echo '# Wait for 10 seconds for libvirt sockets to be created'
TIMEOUT=$((SECONDS+10))
while [ $SECONDS -lt $TIMEOUT ]; do
    if [ -S /var/run/libvirt/libvirt-sock ]; then
       break;
    fi
done

echo '##########################'
echo '# Create a startup CDROM #'
echo '##########################'

genisoimage -o config.iso -V cidata -r -J /tmp/meta-data /tmp/user-data /tmp/network-config

echo '#################'
echo '# Creating a VM #'
echo '#################'

VIRT_MAIN="virt-install \
  --connect qemu:///system \
  --autostart \
  -n os \
  -r 6144 \
  --vcpus 1 \
  --os-type=linux \
  --disk path=/xenial-server-cloudimg-amd64-disk1.img,bus=ide \
  --disk path=/config.iso,device=cdrom \
  --graphics none \
  --console pty,target_type=serial"

VIRT_NET=""
for i in $INTFS; do 
  VIRT_NET=$VIRT_NET" --network bridge=br-$i,model=e1000"
done

VIRT_FULL=$VIRT_MAIN$VIRT_NET

if virsh dominfo os; then --
  echo 'OS VM already exists, destroying the old domain'
  virsh destroy os
  virsh undefine os
fi

echo $VIRT_FULL
eval $VIRT_FULL

echo "Management IP = $IPADDR"

# Sleep and wait for the kill
trap : TERM INT; sleep infinity & wait
