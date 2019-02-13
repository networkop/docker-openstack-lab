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


echo '#############################'
echo '# Entering sleeping loop... #'
echo '#############################'
trap : TERM INT; sleep infinity & wait
