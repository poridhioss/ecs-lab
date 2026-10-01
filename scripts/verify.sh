#!/usr/bin/env bash
# Prove the cluster is in the expected state. Run on: workspace.
set -uo pipefail
cd "$(dirname "$0")/.."

CONTROL=$(terraform -chdir=infra/terraform output -raw control_public_ip)
EXPECTED_AGENTS=2
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== control plane http://$CONTROL:8000 =="
curl -sf "http://$CONTROL:8000/health" >/dev/null || fail "control plane /health not reachable"
echo "ok: /health"

echo "== agents (waiting up to 60s for $EXPECTED_AGENTS online) =="
for i in $(seq 30); do
  online=$(curl -sf "http://$CONTROL:8000/agents" | jq '[.[] | select(.status == "online")] | length')
  [ "${online:-0}" -ge "$EXPECTED_AGENTS" ] && break
  sleep 2
done
curl -sf "http://$CONTROL:8000/agents" | jq -r '.[] | "\(.node_id)  \(.status)  \(.private_ip)  cpu_free=\(.cpu_free)/\(.cpu_total)  mem_free=\((.mem_free // 0) / 1048576 | floor) MiB"'
[ "${online:-0}" -ge "$EXPECTED_AGENTS" ] || fail "only ${online:-0} of $EXPECTED_AGENTS agents online"
echo "ok: $online agents online"

echo "== Temporal UI =="
curl -sf -o /dev/null "http://$CONTROL:8233/" || fail "Temporal UI not reachable on :8233"
echo "ok: http://$CONTROL:8233/"

echo "ALL CHECKS PASSED"
