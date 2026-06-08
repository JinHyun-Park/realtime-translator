#!/usr/bin/env bash
# Stop or terminate the Tokyo GPU box. GPU instances bill hourly — run this
# when you're done demoing (per the workspace always-on-charge teardown rule).
#   deploy/teardown.sh stop        # keep disk+config, stop billing for compute
#   deploy/teardown.sh terminate   # delete instance entirely
set -euo pipefail
cd "$(dirname "$0")"
REGION=ap-northeast-1
IID=$(cat .instance-id)
ACTION="${1:-stop}"

case "$ACTION" in
  stop)
    aws ec2 stop-instances --region $REGION --instance-ids "$IID" \
      --query 'StoppingInstances[0].{Id:InstanceId,State:CurrentState.Name}' --output table
    echo "Stopped. Restart later with: aws ec2 start-instances --region $REGION --instance-ids $IID"
    echo "NOTE: a stopped instance still bills for its 200GB EBS volume (~\$16/mo)."
    ;;
  terminate)
    aws ec2 terminate-instances --region $REGION --instance-ids "$IID" \
      --query 'TerminatingInstances[0].{Id:InstanceId,State:CurrentState.Name}' --output table
    echo "Terminated. (S3 deploy bucket + IAM role are left intact for relaunch.)"
    ;;
  *)
    echo "usage: $0 [stop|terminate]"; exit 1;;
esac
