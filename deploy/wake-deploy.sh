#!/usr/bin/env bash
# Deploy (or update) the wake Lambda + its Function URL.
#
# The relay self-stops when idle; this Lambda is the only thing that can turn the
# box back ON. The Mac app hits the printed Function URL with the shared token.
#
# Idempotent: re-run to push code/env changes. Prints the Function URL, which the
# app stores as its "wake endpoint".
#
# Prereqs: aws cli, admin on 579815401013. Reads deploy/.instance-id and
# deploy/.relay-token (same secret the relay checks).
set -euo pipefail
cd "$(dirname "$0")"

REGION=ap-northeast-1
ACCT=$(aws sts get-caller-identity --query Account --output text)
FN=rt-wake
ROLE=rt-wake-lambda-role
INSTANCE_ID="$(cat .instance-id)"
RELAY_TOKEN="$(cat .relay-token 2>/dev/null || true)"

echo "==> acct=$ACCT region=$REGION fn=$FN instance=$INSTANCE_ID"

# --- IAM role: logs + start/describe scoped to the tagged project ---
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "==> waiting for role to propagate ..."; sleep 12
fi
# describe needs * (no resource-level support for DescribeInstances); start is
# scoped to instances tagged project=realtime-translator (same as self-stop).
aws iam put-role-policy --role-name $ROLE --policy-name rt-wake-ec2 --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
     {\"Effect\":\"Allow\",\"Action\":[\"ec2:DescribeInstances\"],\"Resource\":\"*\"},
     {\"Effect\":\"Allow\",\"Action\":[\"ec2:StartInstances\"],\"Resource\":\"arn:aws:ec2:$REGION:$ACCT:instance/*\",\"Condition\":{\"StringEquals\":{\"ec2:ResourceTag/project\":\"realtime-translator\"}}}
   ]}"
ROLE_ARN=$(aws iam get-role --role-name $ROLE --query 'Role.Arn' --output text)

# --- package ---
TMP=$(mktemp -d)
cp wake_lambda.py "$TMP/wake_lambda.py"
( cd "$TMP" && zip -q wake.zip wake_lambda.py )

ENVVARS="Variables={RT_INSTANCE_ID=$INSTANCE_ID,RT_REGION=$REGION,RT_RELAY_TOKEN=$RELAY_TOKEN}"

if aws lambda get-function --function-name $FN --region $REGION >/dev/null 2>&1; then
  echo "==> updating existing function"
  aws lambda update-function-code --function-name $FN --region $REGION \
    --zip-file "fileb://$TMP/wake.zip" >/dev/null
  aws lambda wait function-updated --function-name $FN --region $REGION
  aws lambda update-function-configuration --function-name $FN --region $REGION \
    --environment "$ENVVARS" --timeout 15 >/dev/null
else
  echo "==> creating function"
  aws lambda create-function --function-name $FN --region $REGION \
    --runtime python3.12 --role "$ROLE_ARN" --handler wake_lambda.handler \
    --timeout 15 --memory-size 128 \
    --zip-file "fileb://$TMP/wake.zip" --environment "$ENVVARS" >/dev/null
  aws lambda wait function-active --function-name $FN --region $REGION
fi

# --- Function URL: AuthType NONE (token is the gate; no AWS creds in the app) ---
if ! aws lambda get-function-url-config --function-name $FN --region $REGION >/dev/null 2>&1; then
  aws lambda create-function-url-config --function-name $FN --region $REGION \
    --auth-type NONE >/dev/null
  # public invoke permission for the URL (still token-gated inside the handler)
  aws lambda add-permission --function-name $FN --region $REGION \
    --statement-id FunctionURLAllowPublic --action lambda:InvokeFunctionUrl \
    --principal '*' --function-url-auth-type NONE >/dev/null 2>&1 || true
fi
URL=$(aws lambda get-function-url-config --function-name $FN --region $REGION \
  --query 'FunctionUrl' --output text)

rm -rf "$TMP"
echo "$URL" > .wake-url
echo "==> wake URL: $URL"
echo "    test:  curl -s \"${URL}?token=\$(cat deploy/.relay-token)\""
