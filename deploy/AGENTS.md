# AWS Deployment Agent Guide

## Scope

These scripts operate real AWS resources in `ap-northeast-1`:

- `launch.sh`: packages `backend/`, updates shared IAM/S3 resources, and launches
  a new GPU EC2 instance.
- `wake-deploy.sh`: deploys the wake Lambda and its URL.
- `connect.sh`: maintains an SSM port-forward for local access.
- `teardown.sh`: stops or terminates the instance in `.instance-id`.
- `cloudfront-teardown.sh`: removes CloudFront and closes related ingress.
- `userdata*.sh`: first-boot and golden-AMI provisioning.

Read the deployment sections in `README.md` and rollback notes in `VERSIONS.md`
before operating the live environment.

## State And Secrets

Files such as `.relay-token`, `.admin-token`, `.instance-id`, `.golden-ami`,
`.eip`, `.wake-url`, and `.cloudfront-id` are local operational state and are
gitignored. Never print token values into logs, patches, commits, or user-facing
URLs.

Before a mutation:

```bash
aws sts get-caller-identity
aws ec2 describe-instances \
  --region ap-northeast-1 \
  --instance-ids "$(cat deploy/.instance-id)"
```

Confirm that the account and instance match the intended live environment.
Do not assume IDs recorded in documentation are current.

## Deployment Rules

- Run `./scripts/codex-check.sh` from the repository root before live
  deployment.
- `launch.sh` launches a new instance and rewrites `.instance-id`; do not treat
  it as an in-place code sync command.
- Preserve the no-public-port design: SSM and CloudFront are the intended access
  paths.
- Keep `/viewsock` behavior ahead of `/view*` in CloudFront routing. Reversing
  them sends the WebSocket handshake to the static viewer page.
- Preserve current-account substitution in IAM policy templates.
- Use `teardown.sh stop` when compute should pause but disk/state must remain.
  Use `terminate` only when deletion is intended.

## Verification

Static check:

```bash
bash -n deploy/*.sh
```

After deployment, confirm bootstrap status through SSM, then verify `/healthz`.
`ready:false` means the relay is up but the model is still warming; only
`ready:true` is ready for a capture test. Exercise the changed endpoint or app
flow after readiness instead of treating a successful AWS CLI command as proof.

For rollback, use the known-good Git tags and deployment notes in `VERSIONS.md`;
do not invent resource IDs or reconstruct secrets from documentation.
