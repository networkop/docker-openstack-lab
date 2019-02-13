ssh ubuntu@$(docker inspect os --format '{{.NetworkSettings.IPAddress}}')
