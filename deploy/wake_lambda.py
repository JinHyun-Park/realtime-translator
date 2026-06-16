"""
Wake Lambda for the personal realtime-translator box.

The relay self-stops after idle (cost guard). Something has to turn it back ON,
and an EC2 box obviously can't start itself. This tiny always-on Lambda is that
"something": the Mac app calls its Function URL with the shared token, and it
calls start_instances on the ONE tagged instance.

Auth: shared token (same RELAY_TOKEN the relay uses). Function URL AuthType is
NONE (no SigV4 / no AWS creds in the app — that was a hard requirement), so this
token check IS the gate. Constant-time compare; 401 on mismatch.

Env:
  RT_RELAY_TOKEN  - shared secret the app must present (?token= or X-Wake-Token)
  RT_INSTANCE_ID  - the instance to start (single personal box)
  RT_REGION       - region of that instance (default ap-northeast-1)

Returns JSON:
  {"state":"pending"|"running"|"stopping"|..., "starting":bool, "ip":"<eip>"}
The app polls /healthz (through CloudFront) afterwards to know when it's READY;
this endpoint only kicks the box and reports the coarse EC2 lifecycle state.
"""
import hmac
import json
import os

import boto3

INSTANCE_ID = os.environ["RT_INSTANCE_ID"]
REGION = os.environ.get("RT_REGION", "ap-northeast-1")
TOKEN = os.environ.get("RT_RELAY_TOKEN", "")

_ec2 = boto3.client("ec2", region_name=REGION)


def _reply(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json",
                    "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def _present_token(event):
    # Token may arrive as ?token=... (browsers / simple clients) or as the
    # X-Wake-Token header (native app). Function URL lowercases header keys.
    qs = (event.get("queryStringParameters") or {})
    if qs.get("token"):
        return qs["token"]
    hdrs = (event.get("headers") or {})
    return hdrs.get("x-wake-token") or hdrs.get("X-Wake-Token") or ""


def handler(event, _ctx):
    if TOKEN:
        got = _present_token(event)
        if not got or not hmac.compare_digest(got, TOKEN):
            return _reply(401, {"error": "unauthorized"})

    d = _ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    inst = d["Reservations"][0]["Instances"][0]
    state = inst["State"]["Name"]          # running|stopped|stopping|pending|...
    ip = inst.get("PublicIpAddress")       # the EIP once associated

    # Only start from a fully stopped state. If it's pending/running/stopping we
    # just report — calling start on a stopping box races; the app will poll.
    starting = False
    if state == "stopped":
        _ec2.start_instances(InstanceIds=[INSTANCE_ID])
        starting = True
        state = "pending"

    return _reply(200, {
        "state": state,
        "starting": starting,
        "running": state == "running",
        "ip": ip,
    })
