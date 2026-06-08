#!/usr/bin/env bash
# Local Mac demo: faster-whisper (CPU) + Ollama (Qwen3) relay.
set -euo pipefail
cd "$(dirname "$0")"

# 1) Python deps in a venv
if [ ! -d .venv ]; then
  echo "==> creating venv"
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -U pip
pip install -q -r requirements.txt

# 2) Make sure Ollama is up with a Qwen3 model
if ! command -v ollama >/dev/null 2>&1; then
  echo "!! Ollama not found. Install:  brew install ollama"
  echo "   then:  ollama serve   and   ollama pull qwen3:8b"
  exit 1
fi
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "!! Ollama server not responding on :11434. Run 'ollama serve' in another tab."
  exit 1
fi
if ! ollama list | grep -q 'qwen3'; then
  echo "==> pulling qwen3:8b (one-time)"
  ollama pull qwen3:8b
fi

# 3) Env (CPU whisper + Ollama). Override any of these inline if you like.
export RT_ASR_MODEL="${RT_ASR_MODEL:-small}"
export RT_ASR_DEVICE="${RT_ASR_DEVICE:-cpu}"
export RT_ASR_COMPUTE="${RT_ASR_COMPUTE:-int8}"
export RT_LLM_BASE_URL="${RT_LLM_BASE_URL:-http://localhost:11434/v1}"
export RT_LLM_MODEL="${RT_LLM_MODEL:-qwen3:8b}"
export RT_MIN_SILENCE_MS="${RT_MIN_SILENCE_MS:-900}"

echo "==> starting relay on ws://localhost:${RT_PORT:-8765}"
exec python server.py
