#!/usr/bin/env bash
# Lab 00: facts about one EC2 instance. Not run directly: instance-check.sh pipes it over ssh.
# Arguments: the private IPs of all lab instances (to test instance-to-instance traffic).
# The trailing `; echo` ends lines for commands that print no newline (curl -w).
show() { printf '%-16s ' "$1"; shift; { "$@" 2>&1; echo; } | head -1 || true; }

echo "==== $(hostname) ===="
grep --color=never -E 'BOOTSTRAP (START|DONE)|DOCKER INSTALLED|VXLAN MODULE' /var/log/bootstrap.log
NIC=$(ip -o route get 1.1.1.1 | grep --color=never -o 'dev [^ ]*' | awk '{print $2}')
show kernel      uname -r
show cpu/mem     sh -c 'echo "$(nproc) vCPU, $(free -m | awk "/Mem:/{print \$2}") MB"'
show disk        sh -c 'df -h / | tail -1'
show nic         echo "$NIC"
show mtu         cat "/sys/class/net/$NIC/mtu"
show private-ip  sh -c "ip -4 -o addr show $NIC | awk '{print \$4}'"
show python3     python3 --version
show docker      docker --version
show rsync       sh -c 'rsync --version 2>&1 || echo MISSING'
show vxlan-mod   sh -c 'lsmod | grep --color=never "^vxlan" || echo NOT LOADED'
show github      curl -sS -o /dev/null -w '%{http_code}' https://github.com
show dockerhub   sh -c 'sudo docker run --rm hello-world 2>&1 | grep --color=never "Hello from Docker" || echo PULL FAILED'
for ip in "$@"; do
  show "peer $ip"  curl -sS -m 3 "http://$ip:8000/"
done
