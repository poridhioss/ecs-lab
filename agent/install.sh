#!/usr/bin/env bash
# Install (or update) the agent on a compute node. Safe to run again.
# Run on: node-01 / node-02, as root (scripts/push.sh does this for you).
set -euo pipefail
cd /opt/ecs-lab

python3 -m venv venv
venv/bin/pip install -q -r agent/requirements.txt

cp agent/agent.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q agent
systemctl restart agent
echo "agent (re)started on $(hostname); logs: journalctl -u agent -f"
