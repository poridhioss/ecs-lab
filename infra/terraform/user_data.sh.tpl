#!/bin/bash
# First-boot setup for every cluster machine. Rendered by Terraform templatefile().
exec > /var/log/bootstrap.log 2>&1
echo "BOOTSTRAP START $(date -Is)"

hostnamectl set-hostname ${name}

# Docker, pinned so a future release can't change networking under the labs
curl -fsSL https://get.docker.com | sh -s -- --version 29.8
usermod -aG docker ubuntu

# Python virtual environments (Ubuntu 24.04 blocks system-wide pip installs)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y python3-venv

# Where scripts/push.sh copies the code
mkdir -p /opt/ecs-lab
chown ubuntu:ubuntu /opt/ecs-lab

# Settings every service on this machine reads (systemd EnvironmentFile)
mkdir -p /etc/ecs-lab
cat > /etc/ecs-lab/ecs-lab.env <<EOF
NODE_ID=${name}
CONTROL_IP=${control_ip}
AGENT_TOKEN=${agent_token}
EOF
chmod 600 /etc/ecs-lab/ecs-lab.env

echo "BOOTSTRAP DONE $(date -Is)"
