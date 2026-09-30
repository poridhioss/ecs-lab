#!/usr/bin/env bash
# Lab 00: wait for every instance's bootstrap, then collect facts from each.
# Run on: workspace, after `terraform apply`.  Output: ~/lab00-output/instances.txt
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
REMOTE="$(dirname "$0")/remote-check.sh"
mkdir -p ~/lab00-output
exec > >(tee ~/lab00-output/instances.txt) 2>&1

PUBLIC_IPS=$(terraform -chdir="$TF_DIR" output -raw public_ips)
PRIVATE_IPS=$(terraform -chdir="$TF_DIR" output -raw private_ips)
COUNT=$(echo "$PUBLIC_IPS" | wc -w)
echo "instances: $COUNT   public: $PUBLIC_IPS   private: $PRIVATE_IPS"

echo "== waiting for bootstrap on every instance =="
START=$(date +%s)
for i in $(seq 1 "$COUNT"); do
  until ssh -o ConnectTimeout=5 "lab00-$i" 'grep -q "BOOTSTRAP DONE" /var/log/bootstrap.log' 2>/dev/null; do
    if [ $(( $(date +%s) - START )) -gt 900 ]; then echo "lab00-$i: gave up after 15 min"; break; fi
    sleep 5
  done
  echo "lab00-$i ready after $(( $(date +%s) - START ))s"
done

echo; echo "== facts per instance =="
for i in $(seq 1 "$COUNT"); do
  ssh "lab00-$i" bash -s -- $PRIVATE_IPS < "$REMOTE"
  echo
done

echo "== workspace -> public IP on port 8000 =="
for ip in $PUBLIC_IPS; do
  printf '%-16s ' "$ip"; curl -sS -m 5 "http://$ip:8000/" 2>&1 | head -1
done
