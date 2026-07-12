#!/usr/bin/env bash
# One-shot: package backend -> S3, create IAM/SG, launch the Tokyo GPU box.
# Idempotent-ish: reuses resources if they already exist. Prints the instance id.
#
# Prereqs: aws cli configured, admin on account 579815401013.
set -euo pipefail
cd "$(dirname "$0")/.."

REGION=ap-northeast-1
ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=rt-translator-deploy-$ACCT-$REGION
INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.2xlarge}"
ROLE=rt-translator-ec2-role
PROFILE=rt-translator-ec2-profile

# Prefer the golden AMI (models + vLLM/starlette pinned + driver pre-baked) for
# a seconds-not-minutes boot. Falls back to the DLAMI + full bootstrap if no
# golden AMI is recorded. Override with GOLDEN_AMI= or FORCE_DLAMI=1.
GOLDEN_AMI="${GOLDEN_AMI:-$(cat deploy/.golden-ami 2>/dev/null || true)}"
if [ -n "$GOLDEN_AMI" ] && [ "${FORCE_DLAMI:-0}" != "1" ]; then
  AMI="$GOLDEN_AMI"; USERDATA=deploy/userdata-golden.sh
  echo "==> using GOLDEN AMI $AMI (fast boot)"
else
  AMI=$(aws ssm get-parameters --region $REGION \
    --names /aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.7-ubuntu-22.04/latest/ami-id \
    --query 'Parameters[0].Value' --output text)
  USERDATA=deploy/userdata.sh
  echo "==> using DLAMI $AMI (full bootstrap, ~20min)"
fi

echo "==> account=$ACCT region=$REGION ami=$AMI type=$INSTANCE_TYPE"

# --- package backend -> S3 ---
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || \
  aws s3api create-bucket --region $REGION --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint=$REGION
aws s3api put-public-access-block --bucket "$BUCKET" --region $REGION \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
tar czf /tmp/rt-backend.tgz -C backend --exclude='__pycache__' --exclude='.venv' --exclude='*.pyc' .
aws s3 cp /tmp/rt-backend.tgz "s3://$BUCKET/rt-backend.tgz" --region $REGION

# --- IAM role + profile (SSM + scoped S3 read) ---
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
aws iam put-role-policy --role-name $ROLE --policy-name rt-s3-read --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
# Self-stop on idle: the box may stop ITSELF (never start — that's the wake
# Lambda's job). Scoped to instances tagged project=realtime-translator.
aws iam put-role-policy --role-name $ROLE --policy-name rt-self-stop --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ec2:StopInstances\"],\"Resource\":\"arn:aws:ec2:$REGION:$ACCT:instance/*\",\"Condition\":{\"StringEquals\":{\"ec2:ResourceTag/project\":\"realtime-translator\"}}}]}"
# Bedrock (Claude translation + live insight) and session-history S3 access.
# The shipped policy files carry the original account's ids — substitute the
# CURRENT account's so a fresh deploy works anywhere (matches README's
# "deploying to your own AWS account" promise).
sed "s/579815401013/$ACCT/g" deploy/bedrock-policy.json > /tmp/rt-bedrock-policy.json
aws iam put-role-policy --role-name $ROLE --policy-name rt-bedrock \
  --policy-document file:///tmp/rt-bedrock-policy.json
sed "s/579815401013/$ACCT/g" deploy/session-log-policy.json > /tmp/rt-session-log-policy.json
aws iam put-role-policy --role-name $ROLE --policy-name rt-session-log \
  --policy-document file:///tmp/rt-session-log-policy.json
if ! aws iam get-instance-profile --instance-profile-name $PROFILE >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name $PROFILE
  aws iam add-role-to-instance-profile --instance-profile-name $PROFILE --role-name $ROLE
  sleep 15  # propagation
fi

# --- security group (no inbound; SSM only) ---
VPC=$(aws ec2 describe-vpcs --region $REGION --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 describe-security-groups --region $REGION \
  --filters Name=group-name,Values=rt-translator-sg Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG" = "None" ] || [ -z "$SG" ]; then
  SG=$(aws ec2 create-security-group --region $REGION --group-name rt-translator-sg \
    --description "Realtime translator - SSM only, no inbound" --vpc-id $VPC \
    --query 'GroupId' --output text)
fi
# pick an AZ/subnet where the instance type is offered
AZ=$(aws ec2 describe-instance-type-offerings --region $REGION --location-type availability-zone \
  --filters Name=instance-type,Values=$INSTANCE_TYPE --query 'InstanceTypeOfferings[0].Location' --output text)
SUBNET=$(aws ec2 describe-subnets --region $REGION \
  --filters Name=vpc-id,Values=$VPC Name=availability-zone,Values=$AZ \
  --query 'Subnets[0].SubnetId' --output text)

# --- user-data ---
# Access token: read deploy/.relay-token (created out-of-band) so the relay
# requires ?token=... ; empty file => open relay (dev).
RELAY_TOKEN="$(cat deploy/.relay-token 2>/dev/null || true)"
sed -e "s|__BUCKET__|$BUCKET|g" -e "s|__REGION__|$REGION|g" \
    -e "s|__RELAY_TOKEN__|$RELAY_TOKEN|g" "$USERDATA" > /tmp/rt-userdata.sh

IID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI --instance-type $INSTANCE_TYPE \
  --iam-instance-profile Name=$PROFILE \
  --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
  --user-data file:///tmp/rt-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rt-translator},{Key=project,Value=realtime-translator}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "$IID" > deploy/.instance-id
echo "==> launched $IID ($INSTANCE_TYPE @ $AZ)"
echo "Watch:   aws ssm start-session --region $REGION --target $IID  # then: tail -f /var/log/rt-bootstrap.log"
echo "Connect: deploy/connect.sh   (SSM port-forward 8765 -> localhost:8765)"
