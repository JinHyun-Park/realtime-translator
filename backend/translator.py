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

import collections

from openai import AsyncOpenAI

from config import settings

LANG_NAME = {"ko": "Korean", "ja": "Japanese", "en": "English"}


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
    def __init__(self):
        self.client = AsyncOpenAI(
            base_url=settings.LLM_BASE_URL, api_key=settings.LLM_API_KEY
        )
        self._history: collections.deque[tuple[str, str]] = collections.deque(
            maxlen=settings.CONTEXT_WINDOW
        )

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

        messages = [{"role": "system", "content": self._system_prompt(src, tgt)}]
        ctx = self._context_block()
        if ctx:
            messages.append({"role": "system", "content": ctx})
        messages.append({"role": "user", "content": text})

        resp = await self.client.chat.completions.create(
            model=settings.LLM_MODEL,
            messages=messages,
            temperature=settings.LLM_TEMPERATURE,
            stream=False,
            extra_body={"chat_template_kwargs": {"enable_thinking": False}},
        )
        out = (resp.choices[0].message.content or "").strip()
        # Only finals shape future context (interims are noisy/half-formed).
        if final and out:
            self._history.append((text, out))
        return out, tgt
