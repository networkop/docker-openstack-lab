FROM ubuntu:16.04

RUN apt-get -qy update && apt-get install -qy --no-install-recommends \
    qemu-kvm libvirt-bin iproute2 wget vim genisoimage virtinst bridge-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY xenial-server-cloudimg-amd64-disk1.img /
COPY entrypoint.sh /

ARG ssh
ENV SSH=${ssh}

ENTRYPOINT [ "./entrypoint.sh" ]

HEALTHCHECK CMD virsh dominfo os || exit 1
