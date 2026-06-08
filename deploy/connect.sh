#!/usr/bin/env bash
# Open an SSM port-forward so the Mac app can reach the relay at ws://localhost:18765
# WITHOUT exposing any inbound port on the instance (per the no-public-exposure rule).
# Leave this running while you use the app.
set -euo pipefail
cd "$(dirname "$0")"
REGION=ap-northeast-1
IID=$(cat .instance-id)
LOCAL_PORT="${1:-18765}"

echo "==> forwarding ws://localhost:$LOCAL_PORT  ->  $IID:8765  (Ctrl-C to stop)"
echo "    In the Mac app, set server = ws://localhost:$LOCAL_PORT"
aws ssm start-session --region $REGION --target "$IID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"8765\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
