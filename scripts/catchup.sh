#!/usr/bin/env bash
# Rebuild the previous lab's end state on freshly created machines.
# Run on: workspace, after `terraform apply` in infra/terraform.
set -euo pipefail
cd "$(dirname "$0")/.."

MACHINES=$(terraform -chdir=infra/terraform output -json public_ips | jq -r 'keys[]')

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

echo "== verifying =="
bash scripts/verify.sh
