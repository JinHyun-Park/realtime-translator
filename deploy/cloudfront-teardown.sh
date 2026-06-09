#!/usr/bin/env bash
# Tear down the ephemeral CloudFront WS proxy + restore zero-inbound SG.
# Run this as part of the 5-hour shutdown (BEFORE/with deploy/teardown.sh).
#
#   deploy/cloudfront-teardown.sh
#
# CloudFront requires disable -> wait-deployed -> delete (ETag-gated). This
# automates that dance, then revokes the SG rule so the box is closed again.
set -uo pipefail
cd "$(dirname "$0")"

REGION=ap-northeast-1
PL=pl-58a04531
DIST_ID="$(cat .cloudfront-id 2>/dev/null || true)"
# Resolve the SG from the CURRENT instance (avoids stale hardcoded IDs after a
# cutover to a new box).
IID="$(cat .instance-id 2>/dev/null || true)"
SG="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

if [ -z "$DIST_ID" ]; then
  echo "no deploy/.cloudfront-id found — nothing to delete (skipping CF)."
else
  echo "==> disabling CloudFront $DIST_ID"
  aws cloudfront get-distribution-config --id "$DIST_ID" > /tmp/cf-cur.json
  ETAG=$(python3 -c "import json;print(json.load(open('/tmp/cf-cur.json'))['ETag'])")
  python3 -c "import json;d=json.load(open('/tmp/cf-cur.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('/tmp/cf-dis.json','w'))"
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config file:///tmp/cf-dis.json --query 'ETag' --output text >/dev/null
  echo "==> waiting for disable to propagate (~few min)…"
  aws cloudfront wait distribution-deployed --id "$DIST_ID"
  NEWETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'ETag' --output text)
  echo "==> deleting CloudFront $DIST_ID"
  aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$NEWETAG"
  rm -f .cloudfront-id
  echo "==> CloudFront deleted"
fi

echo "==> revoking SG inbound (back to zero exposure)"
aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=8765,ToPort=8765,PrefixListIds=[{PrefixListId=$PL}]" \
  2>&1 | head -2 || true

echo "==> done. Remember: deploy/teardown.sh stop|terminate to stop the GPU box."
