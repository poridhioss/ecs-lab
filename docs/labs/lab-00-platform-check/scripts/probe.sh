#!/usr/bin/env bash
# Lab 00: credentials, IAM policy, instance types, Elastic IPs, quotas.
# Run on: workspace, AFTER `terraform apply` (it needs the subnet and AMI from terraform output).
# Output: ~/lab00-output/probe.txt and ~/lab00-output/policy.json
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
mkdir -p ~/lab00-output
exec > >(tee ~/lab00-output/probe.txt) 2>&1

echo "== 1. credentials =="
aws sts get-caller-identity --output table
aws ec2 describe-regions --region ap-southeast-1 --query 'Regions[0].RegionName' --output text

echo; echo "== 2. IAM policy =="
USER_NAME=$(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}')
echo "IAM user: $USER_NAME"
aws iam list-user-policies --user-name "$USER_NAME" --output text
aws iam list-attached-user-policies --user-name "$USER_NAME" --output text
aws iam list-groups-for-user --user-name "$USER_NAME" --query 'Groups[].GroupName' --output text
if aws iam get-user-policy --user-name "$USER_NAME" --policy-name RestrictedAccessPolicy \
     --query PolicyDocument --output json > ~/lab00-output/policy.json 2>&1; then
  echo "Full policy saved to ~/lab00-output/policy.json:"
  cat ~/lab00-output/policy.json; echo
else
  echo "get-user-policy failed:"; cat ~/lab00-output/policy.json; echo
fi

echo; echo "== 3. instance types (dry-run) =="
AMI=$(terraform -chdir="$TF_DIR" output -raw ami_id)
SUBNET=$(terraform -chdir="$TF_DIR" output -raw subnet_id)
echo "AMI=$AMI SUBNET=$SUBNET"
for TYPE in t2.micro t3.medium t3.large t3.xlarge t3.2xlarge m5.large m5.xlarge c5.xlarge; do
  out=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --count 1 \
        --subnet-id "$SUBNET" --dry-run 2>&1)
  case "$out" in
    *DryRunOperation*)       echo "$TYPE ALLOWED" ;;
    *UnauthorizedOperation*) echo "$TYPE DENIED" ;;
    *)                       echo "$TYPE OTHER: $out" ;;
  esac
done

echo; echo "== 4. Elastic IP (dry-run) =="
out=$(aws ec2 allocate-address --domain vpc --dry-run 2>&1)
case "$out" in
  *DryRunOperation*)       echo "Elastic IP ALLOWED" ;;
  *UnauthorizedOperation*) echo "Elastic IP DENIED" ;;
  *)                       echo "Elastic IP OTHER: $out" ;;
esac

echo; echo "== 5. quotas =="
aws ec2 describe-account-attributes --attribute-names max-instances vpc-max-elastic-ips \
  --query 'AccountAttributes[].[AttributeName,AttributeValues[0].AttributeValue]' --output text
# L-1216C47A = running on-demand standard (A, C, D, H, I, M, R, T, Z) instances, in vCPUs
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.[QuotaName,Value]' --output text 2>&1 | head -3

echo; echo "== 6. what is running right now =="
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' --output text
echo "VPCs in the account:"
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output text
