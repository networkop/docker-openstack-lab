docker build --build-arg ssh=$(cat ~/.ssh/id_rsa.pub | awk 'NR==1 {print $2}') -t openstack .
