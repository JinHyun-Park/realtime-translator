#!/bin/bash
# Lightweight user-data for the GOLDEN AMI (rt-translator-golden-*).
# The golden image ALREADY has: models cached (/opt/hf-cache), vLLM 0.22.1 +
# starlette 1.2.1 installed, nvidia driver, and the systemd units. So on boot we
# only need to: (1) ensure the nvidia module matches the running kernel,
# (2) pull the LATEST backend code from S3, (3) (re)write env knobs, (4) restart
# services. No model download, no pip install -> ready in seconds, not minutes.
set -x
exec > >(tee -a /var/log/rt-bootstrap.log) 2>&1
STATUS=/var/run/rt-status
echo "BOOT_START(golden)" > $STATUS

RT_DIR=/opt/realtime-translator
BUCKET="__BUCKET__"
REGION="__REGION__"
RELAY_TOKEN="__RELAY_TOKEN__"

# --- 0. nvidia driver vs running kernel (same guard as full bootstrap) -------
if ! lsmod | grep -q nvidia; then
  apt-get install -y -q "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
  dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || true
  modprobe nvidia 2>/dev/null || true
fi
nvidia-smi -L 2>&1 | head -4 || echo "WARN: GPU not visible"

# --- 1. refresh backend code from S3 (the only thing newer than the image) ---
aws s3 cp "s3://$BUCKET/rt-backend.tgz" /tmp/rt-backend.tgz --region "$REGION"
tar xzf /tmp/rt-backend.tgz -C "$RT_DIR/backend"
echo "CODE_REFRESHED" > $STATUS

# --- 2. GPU topology -> worker count + vLLM mem (matches full userdata) ------
NGPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
NGPU=${NGPU:-1}
if [ "$NGPU" -ge 2 ]; then
  ASR_GPUS=$((NGPU-1)); ASR_WORKERS=$((ASR_GPUS*2)); ASR_CUDA="$(seq -s, 1 $((NGPU-1)))"; VLLM_GPU_UTIL=0.90
else
  ASR_GPUS=1; ASR_WORKERS=3; ASR_CUDA="0"; VLLM_GPU_UTIL=0.78
fi

# --- 3. (re)write systemd units so env knobs match this box (token/topology) -
# The golden image already has working units; we overwrite to inject the current
# RELAY_TOKEN and topology, then restart. Models/venv untouched.
sed -i "s|--gpu-memory-utilization [0-9.]*|--gpu-memory-utilization $VLLM_GPU_UTIL|" \
  /etc/systemd/system/rt-vllm.service
# Update relay env lines in place (idempotent).
set_env() { # key value
  if grep -q "Environment=$1=" /etc/systemd/system/rt-relay.service; then
    sed -i "s|Environment=$1=.*|Environment=$1=$2|" /etc/systemd/system/rt-relay.service
  fi
}
set_env RT_ASR_WORKERS "$ASR_WORKERS"
set_env RT_ASR_NUM_GPUS "$ASR_GPUS"
set_env RT_RELAY_TOKEN "$RELAY_TOKEN"
sed -i "s|Environment=CUDA_VISIBLE_DEVICES=.*|Environment=CUDA_VISIBLE_DEVICES=$ASR_CUDA|" \
  /etc/systemd/system/rt-relay.service

systemctl daemon-reload
systemctl restart rt-vllm.service
sleep 5
systemctl restart rt-relay.service
echo "SERVICES_STARTED" > $STATUS

# --- 4. readiness probe ------------------------------------------------------
for i in $(seq 1 60); do
  V=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/v1/models || true)
  R=$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/8765 && echo ok' 2>/dev/null || true)
  if [ "$V" = "200" ] && [ "$R" = "ok" ]; then echo "READY" > $STATUS; break; fi
  sleep 5
done
