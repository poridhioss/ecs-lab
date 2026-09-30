#!/bin/bash
# Rendered by Terraform templatefile(): ${name} and ${port} are filled in.
exec > /var/log/bootstrap.log 2>&1
echo "BOOTSTRAP START $(date -Is)"

hostnamectl set-hostname ${name}

# Docker, the same way the course labs will install it
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
echo "DOCKER INSTALLED $(date -Is)"

# Tiny web server for the browser-reachability test
mkdir -p /opt/www
echo "hello from ${name}" > /opt/www/index.html
cat > /etc/systemd/system/lab00-web.service <<EOF
[Unit]
Description=Lab 00 test web server
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 -m http.server ${port} --directory /opt/www

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab00-web

# VXLAN kernel module (needed by the VXLAN lab)
modprobe vxlan && echo "VXLAN MODULE OK"

echo "BOOTSTRAP DONE $(date -Is)"
