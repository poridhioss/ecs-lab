#!/usr/bin/env bash
# Copy code from this repo to the EC2 machines and (re)install it there.
# Run on: workspace.
#
#   bash scripts/push.sh infra           Postgres + Temporal on control-01
#   bash scripts/push.sh control-plane   the FastAPI control plane on control-01
#   bash scripts/push.sh agent           the agent on node-01 and node-02
#   bash scripts/push.sh all             everything, in that order
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root, wherever you run this from

NODES="node-01 node-02"

# copy HOST PATH...: tar the paths here, untar them under /opt/ecs-lab on HOST.
# (tar over ssh, because the workspace has no rsync)
copy() {
  local host=$1; shift
  tar czf - --exclude=__pycache__ --exclude=.venv "$@" | ssh "$host" 'tar xzf - -C /opt/ecs-lab'
  echo "==> copied $* to $host"
}

push_infra()         { copy control-01 infra/control; ssh control-01 'sudo bash /opt/ecs-lab/infra/control/install.sh'; }
push_control_plane() { copy control-01 control-plane; ssh control-01 'sudo bash /opt/ecs-lab/control-plane/install.sh'; }
push_agent() {
  for node in $NODES; do
    copy "$node" agent
    ssh "$node" 'sudo bash /opt/ecs-lab/agent/install.sh'
  done
}

case "${1:-}" in
  infra)         push_infra ;;
  control-plane) push_control_plane ;;
  agent)         push_agent ;;
  all)           push_infra; push_control_plane; push_agent ;;
  *) echo "usage: bash scripts/push.sh infra|control-plane|agent|all" >&2; exit 1 ;;
esac
