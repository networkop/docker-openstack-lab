set -o xtrace
IP=$(docker inspect os --format '{{.NetworkSettings.IPAddress}}')
ssh -L 6080:$IP:6080 ubuntu@$IP
