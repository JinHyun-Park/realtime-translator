"""
Translation via any OpenAI-compatible chat endpoint.

  - Local demo:  Ollama  (RT_LLM_BASE_URL=http://localhost:11434/v1, model qwen3:32b / qwen3:8b)
  - Tokyo GPU:   vLLM    (RT_LLM_BASE_URL=http://<host>:8000/v1,  model Qwen/Qwen3-32B)

Two things make the output not-awkward:
  1. We carry a few previous FINAL sentences as context so pronouns / topic
     stay consistent across sentence boundaries.
  2. The system prompt forbids commentary — we want ONLY the translation, so the
     subtitle never shows "Sure, here's the translation:".
"""
from __future__ import annotations

import asyncio
import collections
import logging

from openai import AsyncOpenAI

from config import settings

log = logging.getLogger("rt.translator")

LANG_NAME = {"ko": "Korean", "ja": "Japanese", "en": "English"}

# Runtime-mutable provider switch, seeded from config. The app flips this live
# via /control/llm without a redeploy. "bedrock" => Claude Sonnet 4.6; anything
# else => the local vLLM/Ollama (Qwen) path. A stop/start resets it to the env
# default, so the app re-asserts on every wake (same pattern as idle-stop).
LLM = {"provider": settings.LLM_PROVIDER}


def _target_for(src: str, prefer_pair: tuple[str, str]) -> str:
    """KO<->JA by default. If source is EN, send it to the first pair member."""
    a, b = prefer_pair
    if src == a:
        return b
    if src == b:
        return a
    # source outside the pair (e.g. en) -> translate to pair[0]
    return a


class Translator:
    # Process-wide count of translations that failed after all retries (a lost
    # final). Read by the server's /metrics snapshot for observability.
    llm_errors: int = 0
    # How many Bedrock calls fell back to Qwen (throttle/error). Surfaced in
    # /metrics so we can see if Bedrock is being rate-limited under load.
    bedrock_fallbacks: int = 0

    def __init__(self):
        self.client = AsyncOpenAI(
            base_url=settings.LLM_BASE_URL, api_key=settings.LLM_API_KEY
        )
        # Bedrock client is created lazily on first use (only if the user ever
        # switches to the bedrock provider) so the vLLM-only path has no boto3
        # import cost and missing creds don't break startup.
        self._bedrock = None
        self._history: collections.deque[tuple[str, str]] = collections.deque(
            maxlen=settings.CONTEXT_WINDOW
        )

    def _bedrock_client(self):
        if self._bedrock is None:
            from anthropic import AsyncAnthropicBedrock
            self._bedrock = AsyncAnthropicBedrock(
                aws_region=settings.BEDROCK_REGION
            )
        return self._bedrock

    def _system_prompt(self, src: str, tgt: str) -> str:
        return (
            f"You are a professional simultaneous interpreter translating "
            f"{LANG_NAME.get(src, src)} into {LANG_NAME.get(tgt, tgt)}.\n"
            "Rules:\n"
            "- Output ONLY the translation. No quotes, no notes, no romaji, "
            "no explanations, no language labels.\n"
            "- Preserve names, numbers, and honorific register.\n"
            "- Translate the FULL sentence naturally; do not translate word-by-word.\n"
            "- If the input is an incomplete fragment, translate it as a natural "
            "partial phrase without inventing an ending."
        )

    def _context_block(self) -> str:
        if not self._history:
            return ""
        lines = [f"{s}  ->  {t}" for s, t in self._history]
        return "Recent context (for consistency only, do not re-translate):\n" + \
               "\n".join(lines)

    async def translate(
        self, text: str, src: str, prefer_pair: tuple[str, str], final: bool
    ) -> tuple[str, str]:
        tgt = _target_for(src, prefer_pair)
        if not text.strip():
            return "", tgt

        system = self._system_prompt(src, tgt)
        ctx = self._context_block()
        # Interims use greedy decoding (temperature 0) so the same growing
        # phrase maps to a STABLE translation instead of flickering between
        # synonyms on every refresh. Finals keep the configured temperature.
        temperature = 0.0 if not final else settings.LLM_TEMPERATURE

        # Route by the live provider switch. Bedrock (Claude) is higher accuracy;
        # on a throttle/error we fall back to the local Qwen for THIS call so a
        # rate limit never blanks the subtitle mid-meeting.
        if LLM["provider"] == "bedrock":
            out = await self._translate_bedrock(text, system, ctx, temperature, final)
            if out is None:                       # bedrock failed — fall back
                Translator.bedrock_fallbacks += 1
                log.warning("bedrock translate failed — falling back to vLLM")
                out = await self._translate_vllm(text, system, ctx, temperature, final)
        else:
            out = await self._translate_vllm(text, system, ctx, temperature, final)

        if out is None:
            Translator.llm_errors += 1            # observability: lost translation
            return "", tgt

        # Only finals shape future context (interims are noisy/half-formed).
        if final and out:
            self._history.append((text, out))
        return out, tgt

    async def _translate_vllm(self, text, system, ctx, temperature, final):
        """Local Qwen via the OpenAI-compatible vLLM/Ollama endpoint.
        Returns the translation string, or None on hard failure."""
        messages = [{"role": "system", "content": system}]
        if ctx:
            messages.append({"role": "system", "content": ctx})
        messages.append({"role": "user", "content": text})
        # Retry finals a couple times; interims get one quick try (a newer one
        # is coming anyway).
        attempts = 3 if final else 1
        for i in range(attempts):
            try:
                resp = await self.client.chat.completions.create(
                    model=settings.LLM_MODEL,
                    messages=messages,
                    temperature=temperature,
                    stream=False,
                    timeout=settings.LLM_TIMEOUT,
                    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
                )
                return (resp.choices[0].message.content or "").strip()
            except Exception:
                if i == attempts - 1:
                    return None
                await asyncio.sleep(0.4 * (i + 1))
        return None

    async def _translate_bedrock(self, text, system, ctx, temperature, final):
        """Claude Sonnet 4.6 on Bedrock (Messages API). Returns the translation
        string, or None on ANY failure (throttle, timeout, creds) so the caller
        falls back to Qwen. Context rides as extra system blocks, mirroring the
        vLLM path. No streaming: subtitles are short, so a single round-trip is
        simplest and lowest-overhead."""
        system_blocks = [{"type": "text", "text": system}]
        if ctx:
            system_blocks.append({"type": "text", "text": ctx})
        # Finals retry once on a transient error; interims don't (next one comes).
        attempts = 2 if final else 1
        for i in range(attempts):
            try:
                resp = await self._bedrock_client().messages.create(
                    model=settings.BEDROCK_MODEL,
                    max_tokens=settings.BEDROCK_MAX_TOKENS,
                    system=system_blocks,
                    messages=[{"role": "user", "content": text}],
                    timeout=settings.LLM_TIMEOUT,
                )
                parts = [b.text for b in resp.content if getattr(b, "type", None) == "text"]
                return "".join(parts).strip()
            except Exception as e:
                # Throttle/transient: brief backoff then one retry for finals.
                # Anything still failing returns None -> caller falls back to Qwen.
                if i == attempts - 1:
                    log.warning("bedrock call error: %s", e.__class__.__name__)
                    return None
                await asyncio.sleep(0.3)
        return None
