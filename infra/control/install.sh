#!/usr/bin/env bash
# Start (or update) Postgres and Temporal on control-01. Safe to run again.
# Run on: control-01, as root (scripts/push.sh does this for you).
set -euo pipefail
cd /opt/ecs-lab/infra/control

# --wait blocks until containers are running and Postgres' healthcheck passes
docker compose up -d --wait

echo "waiting for the Temporal UI on :8233 ..."
for i in $(seq 60); do
  curl -sf -o /dev/null localhost:8233 && { echo "Postgres and Temporal are up"; exit 0; }
  sleep 2
done
echo "Temporal did not come up; see: docker compose -f /opt/ecs-lab/infra/control/docker-compose.yml logs temporal" >&2
exit 1
