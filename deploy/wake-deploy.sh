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

# --- HTTP API (API Gateway) in front of the Lambda -------------------------
# Deliberately NOT a Lambda Function URL: some AWS Organizations block Function
# URL invocations outright — BOTH AuthType NONE and the CloudFront-OAC SigV4
# path return 403 — which silently breaks the app's "Wake & Start" (it polls
# /healthz forever on a box nothing ever starts). An HTTP API is not covered by
# that guardrail and behaves identically everywhere. The shared token checked
# inside the handler is still the only gate (no AWS creds in the app), so the
# route AuthorizationType stays NONE, same threat model as before.
API_NAME=rt-wake-api
API_ID=$(aws apigatewayv2 get-apis --region $REGION \
  --query "Items[?Name=='$API_NAME']|[0].ApiId" --output text 2>/dev/null || echo None)
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  API_ID=$(aws apigatewayv2 create-api --region $REGION --name $API_NAME \
    --protocol-type HTTP --query 'ApiId' --output text)
  echo "==> created HTTP API $API_ID"
fi
FN_ARN=$(aws lambda get-function-configuration --function-name $FN --region $REGION \
  --query 'FunctionArn' --output text)
INT_ID=$(aws apigatewayv2 get-integrations --region $REGION --api-id "$API_ID" \
  --query 'Items[0].IntegrationId' --output text 2>/dev/null || echo None)
if [ "$INT_ID" = "None" ] || [ -z "$INT_ID" ]; then
  # NB: do NOT pass --integration-method here. For an AWS_PROXY Lambda
  # integration API Gateway rejects it with a misleading "Invalid lambda
  # function ARN", which sends you hunting a non-existent ARN problem.
  INT_ID=$(aws apigatewayv2 create-integration --region $REGION --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
    --payload-format-version 2.0 --query 'IntegrationId' --output text)
fi
# Re-running is a no-op: a duplicate route/stage just conflicts and is ignored.
for RK in 'ANY /' 'ANY /{proxy+}'; do
  aws apigatewayv2 create-route --region $REGION --api-id "$API_ID" \
    --route-key "$RK" --target "integrations/$INT_ID" >/dev/null 2>&1 || true
done
aws apigatewayv2 create-stage --region $REGION --api-id "$API_ID" \
  --stage-name '$default' --auto-deploy >/dev/null 2>&1 || true
aws lambda add-permission --function-name $FN --region $REGION \
  --statement-id AllowApiGatewayInvoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCT:$API_ID/*/*" >/dev/null 2>&1 || true
URL="https://$API_ID.execute-api.$REGION.amazonaws.com"

rm -rf "$TMP"
echo "$URL" > .wake-url
echo "==> wake endpoint: $URL"
echo "    test:  curl -s \"$URL/wake?token=\$(cat deploy/.relay-token)\""
echo "    NOTE: point the CloudFront /wake* behavior at this origin domain"
echo "          (${API_ID}.execute-api.${REGION}.amazonaws.com) — no OAC needed."
