# Tokyo GPU deploy (ap-northeast-1)

Goal: run the **best open-weight stack** — faster-whisper `large-v3` + Qwen3-32B
(vLLM) — on a GPU instance in Tokyo, exposing the relay's WebSocket to your Mac.

## 1. Instance

| Item | Value |
|---|---|
| Region | `ap-northeast-1` (Tokyo) |
| Instance | `g6e.2xlarge` (1× L40S, 48 GB) — fits Qwen3-32B AWQ + whisper. Bigger: `g6e.4xlarge`. |
| AMI | Deep Learning OSS Nvidia Driver AMI (Ubuntu 22.04) |
| Disk | 200 GB gp3 (model weights are large) |

```bash
aws ec2 run-instances --region ap-northeast-1 \
  --image-id <DLAMI_ID> --instance-type g6e.2xlarge \
  --key-name <your-key> \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rt-translator}]'
```

> Find the DLAMI id:
> `aws ssm get-parameters --region ap-northeast-1 --names /aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id --query 'Parameters[0].Value' --output text`

## 2. Security group — DO NOT open the relay to 0.0.0.0/0

Per the workspace's "ALB 공개노출" rule, never expose this publicly. Two options:

- **Recommended:** keep port `8765` closed; reach it over **SSM port forwarding**:
  ```bash
  aws ssm start-session --region ap-northeast-1 \
    --target <instance-id> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["8765"],"localPortNumber":["8765"]}'
  # then in the Mac app use:  ws://localhost:8765
  ```
- Or allow inbound `8765` from **your IP only** (`<your.ip>/32`), and put a shared
  secret check in front (add a token query param to the WS URL and verify in
  `server.py`). vLLM's `:8000` stays bound to localhost on the box.

## 3. Provision (on the instance)

```bash
# vLLM serving Qwen3-32B (AWQ quant fits 48 GB; drop quant on 80 GB cards)
pip install vllm
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen3-32B-AWQ \
  --host 127.0.0.1 --port 8000 \
  --max-model-len 8192 --gpu-memory-utilization 0.55 &

# Relay (this folder)
git clone <this repo> && cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# faster-whisper needs cuDNN; the DLAMI has it. If missing:
#   pip install nvidia-cudnn-cu12

source .env.tokyo.example   # large-v3 / cuda / vLLM endpoint
python server.py
```

## 4. systemd (keep it running)

`/etc/systemd/system/rt-relay.service`:
```ini
[Unit]
Description=Realtime Translation Relay
After=network.target

[Service]
WorkingDirectory=/home/ubuntu/realtime-translator/backend
EnvironmentFile=/home/ubuntu/realtime-translator/backend/.env.tokyo
ExecStart=/home/ubuntu/realtime-translator/backend/.venv/bin/python server.py
Restart=always
User=ubuntu

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now rt-relay
```

## 5. Cost reminder

g6e.2xlarge is ~\$2/hr on-demand in Tokyo and **bills while running**. This is a
GPU box — **stop or terminate it when not demoing** (per the workspace teardown
rule for always-on charges):
```bash
aws ec2 stop-instances --region ap-northeast-1 --instance-ids <id>
```

## Model choices (swap freely via RT_LLM_MODEL)

| Need | Model | Note |
|---|---|---|
| Best KO↔JA quality | `Qwen/Qwen3-32B` (or `-AWQ`) | strongest open multilingual |
| Smaller/faster | `Qwen/Qwen3-8B` | fits small GPUs, still good |
| Alt family | `google/gemma-3-27b-it` | strong JA, try if Qwen feels off |
| ASR | faster-whisper `large-v3` | KO/JA SOTA among open ASR |
