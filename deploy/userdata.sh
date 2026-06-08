#!/bin/bash
# user-data bootstrap for the Tokyo GPU relay box.
# Runs as root on first boot (DLAMI PyTorch 2.7, Ubuntu 22.04).
# Backend code is pulled from S3 (placeholders substituted by deploy/launch.sh).
# Logs to /var/log/rt-bootstrap.log AND writes a status file the launcher polls.
set -x
exec > >(tee -a /var/log/rt-bootstrap.log) 2>&1
STATUS=/var/run/rt-status
echo "BOOT_START" > $STATUS

export DEBIAN_FRONTEND=noninteractive
RT_DIR=/opt/realtime-translator
BUCKET="__BUCKET__"
REGION="__REGION__"

# --- 1. fetch the backend tarball from S3 ---------------------------------
mkdir -p $RT_DIR/backend
aws s3 cp "s3://$BUCKET/rt-backend.tgz" /tmp/rt-backend.tgz --region "$REGION"
tar xzf /tmp/rt-backend.tgz -C $RT_DIR/backend
echo "UNPACKED" > $STATUS

# --- 2. python deps -------------------------------------------------------
# NOTE: the DLAMI base image ships a python without working ensurepip, so a
# `venv` ends up pip-less. We install into the system python (which already has
# torch/CUDA wired up for this AMI) instead — simpler and avoids that trap.
cd $RT_DIR/backend
PY=/usr/bin/python3
$PY -m pip install -U pip wheel
$PY -m pip install -r requirements.txt
# Qwen3-32B-AWQ needs vLLM >= 0.8.5.
$PY -m pip install "vllm>=0.8.5"
echo "PIPDONE" > $STATUS

# --- 3. systemd: vLLM (Qwen3-32B AWQ) -------------------------------------
cat >/etc/systemd/system/rt-vllm.service <<UNIT
[Unit]
Description=vLLM Qwen3-32B-AWQ
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$RT_DIR/backend
ExecStart=/usr/bin/python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen3-32B-AWQ \
  --host 127.0.0.1 --port 8000 \
  --max-model-len 8192 --gpu-memory-utilization 0.55 \
  --served-model-name Qwen/Qwen3-32B-AWQ
Restart=always
RestartSec=10
Environment=HF_HOME=/opt/hf-cache

[Install]
WantedBy=multi-user.target
UNIT

# --- 4. systemd: relay (faster-whisper large-v3 + WS) ---------------------
cat >/etc/systemd/system/rt-relay.service <<UNIT
[Unit]
Description=Realtime Translation Relay
After=rt-vllm.service
Wants=rt-vllm.service

[Service]
WorkingDirectory=$RT_DIR/backend
Environment=RT_ASR_MODEL=large-v3
Environment=RT_ASR_DEVICE=cuda
Environment=RT_ASR_COMPUTE=float16
Environment=RT_LLM_BASE_URL=http://127.0.0.1:8000/v1
Environment=RT_LLM_MODEL=Qwen/Qwen3-32B-AWQ
Environment=RT_MIN_SILENCE_MS=1000
Environment=RT_MAX_SEGMENT_MS=15000
Environment=RT_HOST=127.0.0.1
Environment=RT_PORT=8765
Environment=HF_HOME=/opt/hf-cache
ExecStart=/usr/bin/python3 server.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /opt/hf-cache
systemctl daemon-reload
systemctl enable --now rt-vllm.service
systemctl enable --now rt-relay.service
echo "SERVICES_STARTED" > $STATUS

# --- 5. readiness probe ---------------------------------------------------
# Relay binds 8765 only after the ASR model has loaded; vLLM serves /models
# once weights are downloaded. Mark READY when both respond.
for i in $(seq 1 120); do
  V=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/v1/models || true)
  R=$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/8765 && echo ok' 2>/dev/null || true)
  if [ "$V" = "200" ] && [ "$R" = "ok" ]; then
    echo "READY" > $STATUS
    break
  fi
  sleep 30
done
