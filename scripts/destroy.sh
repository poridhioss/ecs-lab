#!/usr/bin/env bash
# Delete everything this lab created, then check nothing is left. Run on: workspace.
cd "$(dirname "$0")/.."

terraform -chdir=infra/terraform destroy -auto-approve   # also deletes the key pair

echo "== leftover check: all three lists should be empty =="
echo "running instances:"
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text
echo "ecs-lab VPCs:"
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ecs-lab-vpc" --query 'Vpcs[].VpcId' --output text
echo "ecs-lab key pairs:"
aws ec2 describe-key-pairs --filters "Name=key-name,Values=ecs-lab-key" --query 'KeyPairs[].KeyName' --output text
