#!/usr/bin/env bash
# Lab 00: destroy everything and check nothing is left.
# Run on: workspace.  Output: ~/lab00-output/cleanup.txt
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
mkdir -p ~/lab00-output
exec > >(tee ~/lab00-output/cleanup.txt) 2>&1

terraform -chdir="$TF_DIR" destroy -auto-approve
aws ec2 delete-key-pair --key-name lab00-key
rm -f ~/.ssh/lab00-key.id_rsa

echo "== leftover check (both lists should be empty) =="
echo "running instances:"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text
echo "lab00 VPCs:"
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab00-vpc" --query 'Vpcs[].VpcId' --output text
