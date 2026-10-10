#!/usr/bin/env bash
# Rebuild the previous lab's end state on freshly created machines.
# Run on: workspace, after `terraform apply` in infra/terraform.
set -euo pipefail
cd "$(dirname "$0")/.."

MACHINES=$(terraform -chdir=infra/terraform output -json public_ips | jq -r 'keys[]')
CONTROL=$(terraform -chdir=infra/terraform output -raw control_public_ip)

echo "== waiting for first-boot setup (Docker install) on every machine =="
for m in $MACHINES; do
  for i in $(seq 90); do
    ssh -o ConnectTimeout=5 "$m" 'grep -q "BOOTSTRAP DONE" /var/log/bootstrap.log' 2>/dev/null && break
    sleep 5
  done
  ssh "$m" 'grep -q "BOOTSTRAP DONE" /var/log/bootstrap.log' || { echo "$m: bootstrap did not finish; see /var/log/bootstrap.log" >&2; exit 1; }
  echo "$m ready"
done

echo "== deploying everything =="
bash scripts/push.sh all

echo "== waiting for both agents to register =="
for i in $(seq 30); do
  online=$(curl -sf "http://$CONTROL:8000/agents" | jq '[.[] | select(.status == "online")] | length')
  [ "${online:-0}" -ge 2 ] && break
  sleep 2
done

# The database is new every session, so tenant networks are re-created, not restored.
# Safe to repeat: allocation and network setup are both idempotent.
echo "== creating tenant networks =="
for tenant in alpha beta; do
  curl -sf -X POST "http://$CONTROL:8000/tenants/$tenant/network" | jq -c '{tenant_id, vxlan_id, subnet, nodes}'
done

echo "== verifying =="
bash scripts/verify.sh
