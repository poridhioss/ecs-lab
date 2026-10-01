#!/usr/bin/env bash
# Before a lab: find and delete anything an earlier session left behind.
# Run on: workspace, after `aws configure`, before `terraform apply`.
#
# Poridhi normally cleans the account between sessions, so this usually prints
# "clean". But Terraform state dies with the workspace, so if leftovers exist,
# `terraform destroy` can't remove them; this deletes them by their ecs-lab tags.
# A leftover key pair would also make `terraform apply` fail (duplicate key name).
set -uo pipefail

VPCS=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ecs-lab-vpc" --query 'Vpcs[].VpcId' --output text)
KEY=$(aws ec2 describe-key-pairs --filters "Name=key-name,Values=ecs-lab-key" --query 'KeyPairs[].KeyName' --output text)

if [ -z "$VPCS" ] && [ -z "$KEY" ]; then
  echo "clean: no leftovers from an earlier session"
  exit 0
fi

for VPC in $VPCS; do
  echo "== leftover VPC $VPC: deleting it and everything in it =="

  IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$IDS" ]; then
    echo "terminating instances: $IDS (takes 1-2 minutes)"
    aws ec2 terminate-instances --instance-ids $IDS >/dev/null
    aws ec2 wait instance-terminated --instance-ids $IDS
  fi

  for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
               --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
  done
  for SUBNET in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
                  --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$SUBNET"
  done
  # Every route table except the VPC's main one (that goes with the VPC itself)
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
              --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$RT"
  done
  # Every security group except "default" (that goes with the VPC itself)
  for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
              --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
    aws ec2 delete-security-group --group-id "$SG"
  done
  aws ec2 delete-vpc --vpc-id "$VPC" && echo "deleted $VPC"
done

if [ -n "$KEY" ]; then
  aws ec2 delete-key-pair --key-name ecs-lab-key && echo "deleted key pair ecs-lab-key"
fi

echo "== re-checking (both lines should be empty) =="
echo "VPCs:      $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ecs-lab-vpc" --query 'Vpcs[].VpcId' --output text)"
echo "key pairs: $(aws ec2 describe-key-pairs --filters "Name=key-name,Values=ecs-lab-key" --query 'KeyPairs[].KeyName' --output text)"
