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

# --- 0. nvidia driver vs running kernel --------------------------------------
# THE golden-AMI boot bug: a baked image carries an nvidia module built for the
# kernel that was running at bake time. If apt upgraded the kernel between bake
# and this boot, `lsmod | grep nvidia` can still be TRUE (a stale module loads)
# yet `nvidia-smi` fails with "NO-MODULE" / no CUDA-capable device. So the gate
# must be "can nvidia-smi actually enumerate a GPU", not "is a module loaded".
#
# Fix = (a) pin the kernel so it can't drift again across reboots, then (b) if
# nvidia-smi can't see a GPU, rebuild DKMS for the *running* kernel and reload.
apt-mark hold linux-image-aws linux-headers-aws linux-aws \
  "linux-image-$(uname -r)" "linux-headers-$(uname -r)" >/dev/null 2>&1 || true

if ! nvidia-smi -L >/dev/null 2>&1; then
  echo "GPU not visible (likely kernel/DKMS drift) — rebuilding for $(uname -r)"
  apt-get install -y -q "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
  # Drop any stale module bound to the wrong kernel, then force a rebuild+install
  # of the DKMS nvidia module against the kernel we are ACTUALLY running.
  rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
  dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || true
  modprobe nvidia 2>/dev/null || true
fi
if nvidia-smi -L 2>&1 | head -4; then
  echo "GPU OK"
else
  echo "WARN: GPU still not visible after DKMS rebuild"
fi

# --- 0b. make the GPU fix SURVIVE stop/start (user-data only runs on 1st boot) -
# The block above runs only on the FIRST boot of an instance. A stop/start does
# NOT re-run user-data, so without this, a kernel that drifted while stopped
# would leave the GPU invisible and rt-relay crash-looping. Two safeguards:
#  (A) kill unattended-upgrades — the root cause of kernel/nvidia drift.
#  (B) install a boot-time self-heal unit (rt-gpu-guard) that rebuilds the
#      nvidia DKMS module BEFORE rt-relay starts, on EVERY boot.
systemctl disable --now unattended-upgrades 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
CFG

cat > /usr/local/sbin/rt-gpu-guard.sh <<'GUARD'
#!/bin/bash
set -x
KREL=$(uname -r)
if nvidia-smi -L >/dev/null 2>&1; then echo "rt-gpu-guard: GPU OK ($KREL)"; exit 0; fi
echo "rt-gpu-guard: GPU NOT visible on $KREL — rebuilding nvidia DKMS"
apt-get install -y -q --allow-change-held-packages "linux-headers-$KREL" 2>&1 | tail -3 || true
rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
dkms autoinstall -k "$KREL" 2>&1 | tail -6 || true
modprobe nvidia 2>&1 || true
nvidia-smi -L 2>&1 | head -2
GUARD
chmod +x /usr/local/sbin/rt-gpu-guard.sh

cat > /etc/systemd/system/rt-gpu-guard.service <<'UNIT'
[Unit]
Description=RT GPU guard — ensure nvidia driver matches running kernel before relay
After=network-online.target
Wants=network-online.target
Before=rt-relay.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rt-gpu-guard.sh
TimeoutStartSec=600
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/rt-relay.service.d
cat > /etc/systemd/system/rt-relay.service.d/10-gpu-guard.conf <<'DROPIN'
[Unit]
Wants=rt-gpu-guard.service
After=rt-gpu-guard.service
DROPIN
systemctl enable rt-gpu-guard.service 2>/dev/null || true

# --- 1. refresh backend code from S3 (the only thing newer than the image) ---
aws s3 cp "s3://$BUCKET/rt-backend.tgz" /tmp/rt-backend.tgz --region "$REGION"
tar xzf /tmp/rt-backend.tgz -C "$RT_DIR/backend"
echo "CODE_REFRESHED" > $STATUS

# anthropic[bedrock] is only needed for the optional Claude translation
# provider; the golden image predates it, so ensure it's present (idempotent,
# fast no-op once baked into a future image).
python3 -c "import anthropic" 2>/dev/null || \
  python3 -m pip install "anthropic[bedrock]>=0.40.0" || true

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
set_env() { # key value — update in place if present, else append under [Service].
  if grep -q "Environment=$1=" /etc/systemd/system/rt-relay.service; then
    sed -i "s|Environment=$1=.*|Environment=$1=$2|" /etc/systemd/system/rt-relay.service
  else
    sed -i "/^\[Service\]/a Environment=$1=$2" /etc/systemd/system/rt-relay.service
  fi
}
set_env RT_ASR_WORKERS "$ASR_WORKERS"
set_env RT_ASR_NUM_GPUS "$ASR_GPUS"
set_env RT_RELAY_TOKEN "$RELAY_TOKEN"
# Idle auto-stop OFF: shared always-on box (see userdata.sh for the rationale).
set_env RT_IDLE_STOP_ENABLED "0"
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
