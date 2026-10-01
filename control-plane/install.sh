#!/usr/bin/env bash
# Install (or update) the control plane on control-01. Safe to run again.
# Run on: control-01, as root (scripts/push.sh does this for you).
set -euo pipefail
cd /opt/ecs-lab

python3 -m venv venv
venv/bin/pip install -q -r control-plane/requirements.txt

cp control-plane/control-plane.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q control-plane
systemctl restart control-plane

echo "waiting for the control plane on :8000 ..."
for i in $(seq 60); do
  curl -sf localhost:8000/health >/dev/null && { echo "control plane is up"; exit 0; }
  sleep 2
done
echo "control plane did not come up; see: journalctl -u control-plane -n 50" >&2
exit 1
