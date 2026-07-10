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

# --- 0. ensure NVIDIA driver matches the RUNNING kernel -------------------
# The DLAMI builds the nvidia DKMS module for the kernel it shipped with, but a
# fresh boot can land on a newer apt kernel (e.g. 1052 -> 1057), leaving the
# module absent OR a stale module loaded against the wrong kernel -> "no
# CUDA-capable device". The reliable gate is "can nvidia-smi enumerate a GPU",
# NOT "is some nvidia module loaded" (lsmod can be true while nvidia-smi fails).
if ! nvidia-smi -L >/dev/null 2>&1; then
  apt-get install -y -q "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
  rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
  dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || true
  modprobe nvidia 2>/dev/null || true
fi
nvidia-smi -L 2>&1 | head -4 || echo "WARN: GPU still not visible after DKMS"

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
# Pin the verified-working combo. vllm 0.23.0 + starlette 1.3.1 throw
# "'_IncludedRouter' object has no attribute 'path'" -> HTTP 500 on every
# request. Pin vLLM AND its web stack to what works with Qwen3-32B-AWQ.
$PY -m pip install "vllm==0.22.1"
$PY -m pip install "starlette==1.2.1" "fastapi==0.136.3"
echo "PIPDONE" > $STATUS

# --- GPU topology: decide how to split vLLM vs whisper across cards ----------
# 4-GPU box (g6e.12xlarge): vLLM on GPU0, whisper workers spread on GPUs 1..3.
# 1-GPU box (g6e.2xlarge):  vLLM + a few whisper workers share GPU0.
NGPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')
NGPU=${NGPU:-1}
if [ "$NGPU" -ge 2 ]; then
  ASR_GPUS=$((NGPU - 1))          # whisper uses all cards except GPU0
  ASR_WORKERS=$((ASR_GPUS * 2))   # ~2 replicas/card
  ASR_CUDA="$(seq -s, 1 $((NGPU-1)))"   # e.g. "1,2,3"
  VLLM_GPU_UTIL=0.90              # vLLM has GPU0 to itself
else
  ASR_GPUS=1
  ASR_WORKERS=3                   # share the single card with vLLM
  ASR_CUDA="0"
  VLLM_GPU_UTIL=0.78             # leave room for whisper workers on the SAME GPU
fi
echo "GPU_TOPOLOGY ngpu=$NGPU asr_workers=$ASR_WORKERS asr_gpus=$ASR_GPUS cuda=$ASR_CUDA vllm_util=$VLLM_GPU_UTIL" >> /var/log/rt-bootstrap.log

# --- 3. systemd: vLLM (Qwen3-32B AWQ) -------------------------------------
cat >/etc/systemd/system/rt-vllm.service <<UNIT
[Unit]
Description=vLLM Qwen3-32B-AWQ
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$RT_DIR/backend
# Pin vLLM to GPU 0 only; whisper workers take GPUs 1..N-1 (multi-GPU box).
# On a single-GPU box this still works (vLLM shares GPU 0 with whisper).
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=/usr/bin/python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen3-32B-AWQ \
  --host 127.0.0.1 --port 8000 \
  --max-model-len 8192 --gpu-memory-utilization $VLLM_GPU_UTIL \
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
# Whisper workers see only the non-vLLM GPUs; device_index 0..N maps onto them.
Environment=CUDA_VISIBLE_DEVICES=$ASR_CUDA
Environment=RT_ASR_MODEL=large-v3
Environment=RT_ASR_DEVICE=cuda
Environment=RT_ASR_COMPUTE=float16
Environment=RT_ASR_WORKERS=$ASR_WORKERS
Environment=RT_ASR_NUM_GPUS=$ASR_GPUS
Environment=RT_LLM_BASE_URL=http://127.0.0.1:8000/v1
Environment=RT_LLM_MODEL=Qwen/Qwen3-32B-AWQ
Environment=RT_MIN_SILENCE_MS=1000
Environment=RT_MAX_SEGMENT_MS=15000
# 6 previous finals as translation context (shared deque is 2x = 12 lines,
# both speakers) — pronouns/terms stay coherent across a longer stretch.
Environment=RT_CONTEXT_WINDOW=6
Environment=RT_HOST=0.0.0.0
Environment=RT_PORT=8765
Environment=RT_RELAY_TOKEN=__RELAY_TOKEN__
# Idle auto-stop DISABLED: this box is a shared always-on server (the owner's
# build + the shared build hit the same relay). Viewers don't count as capture
# sessions, so a viewers-only / idle-but-wanted box would otherwise self-stop.
# Wake-on-demand (rt-wake Lambda) still works; nothing here turns the box ON.
Environment=RT_IDLE_STOP_ENABLED=0
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
