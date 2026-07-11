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
import json
import logging

from openai import AsyncOpenAI

from config import settings

log = logging.getLogger("rt.translator")

LANG_NAME = {"ko": "Korean", "ja": "Japanese", "en": "English"}


def _is_target_char(ch: str, tgt: str) -> bool:
    if tgt == "ko":
        return "가" <= ch <= "힣" or "㄰" <= ch <= "㆏"
    if tgt == "ja":
        return ("぀" <= ch <= "ヿ") or ("一" <= ch <= "鿿")
    return ch.isascii() and ch.isalpha()      # en


def _target_ratio(text: str, tgt: str) -> float:
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    return sum(1 for c in letters if _is_target_char(c, tgt)) / len(letters)


def sanitize_translation(out: str, tgt: str, src_text: str) -> str | None:
    """Guard against the model 'thinking out loud': on a tricky idiom or a
    suspected mishearing the LLM sometimes prints its ANALYSIS (usually in
    English) before/around the actual translation — which then lands verbatim
    on the subtitle. Accept the output only if it actually looks like a
    translation: mostly target-script and not absurdly long. If it fails,
    try to rescue the real translation (the last target-script paragraph —
    models put the answer at the end); otherwise return None so the caller
    keeps/derives a safer result. Pure function, unit-tested."""
    s = (out or "").strip().strip('"“”「」『』')
    if not s:
        return None
    max_len = max(3 * len(src_text), 120)
    # Accept threshold is deliberately LOW (0.35): translations legitimately
    # mix scripts ("Kafka 마이그레이션", Qwen's "今 quarter の売上..."), and a
    # dropped real translation is worse than an awkward one. Analysis prose is
    # overwhelmingly source/English text — it lands near 0.0-0.2.
    if _target_ratio(s, tgt) >= 0.35 and len(s) <= max_len:
        return s
    # Rescue: scan paragraphs (then lines) from the END for a clean chunk
    # (models put the actual answer after their analysis).
    for splitter in ("\n\n", "\n"):
        for part in reversed(s.split(splitter)):
            p = part.strip().strip('"“”「」『』')
            if p and _target_ratio(p, tgt) >= 0.7 and len(p) <= max_len:
                return p
    return None

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

    def __init__(self, history: collections.deque | None = None):
        self.client = AsyncOpenAI(
            base_url=settings.LLM_BASE_URL, api_key=settings.LLM_API_KEY
        )
        # Bedrock client is created lazily on first use (only if the user ever
        # switches to the bedrock provider) so the vLLM-only path has no boto3
        # import cost and missing creds don't break startup.
        self._bedrock = None
        # Context history: (speaker, source, translation) triples. The server
        # passes ONE shared deque to both of a room's capture connections (mic +
        # system audio) so translating THEM can see what ME just said — the two
        # sides of one conversation were previously invisible to each other.
        self._history: collections.deque[tuple[str, str, str]] = (
            history if history is not None
            else collections.deque(maxlen=settings.CONTEXT_WINDOW)
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
            "- NEVER analyze or comment on the input — even if it seems "
            "misheard, ambiguous, or idiomatic, silently pick the most likely "
            "intended meaning and translate it. Commentary on a subtitle "
            "screen is worse than an imperfect translation.\n"
            "- Preserve names, numbers, and honorific register.\n"
            "- Translate the FULL sentence naturally; do not translate word-by-word.\n"
            "- If the input is an incomplete fragment, translate it as a natural "
            "partial phrase without inventing an ending."
        )

    def _context_block(self) -> str:
        if not self._history:
            return ""
        lines = [f"[{who}] {s}  ->  {t}" for who, s, t in self._history]
        return ("Recent conversation (both speakers, for consistency only — "
                "do not re-translate):\n" + "\n".join(lines))

    async def translate(
        self, text: str, src: str, prefer_pair: tuple[str, str], final: bool,
        speaker: str = "?",
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

        # Route by the live provider switch. Bedrock (Claude) is higher accuracy
        # but its round-trip (~1.5s) is LONGER than the interim refresh interval
        # (1s) — an interim translated via Bedrock is cancelled by the next tick
        # before it ever reaches the screen, so the grey "listening" preview
        # disappears entirely. Interims therefore ALWAYS use the local vLLM
        # (fast, free); finals and the refine pass use the selected provider.
        # On a Bedrock throttle/error we fall back to Qwen for THIS call so a
        # rate limit never blanks the subtitle mid-meeting.
        if LLM["provider"] == "bedrock" and final:
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

        # Anti-commentary guard: on tricky idioms/mishearings the model can
        # emit its ANALYSIS around the translation ("here 'club' likely
        # means..."). Keep only output that actually looks like a translation;
        # rescue the trailing target-script chunk if the analysis included one.
        clean = sanitize_translation(out, tgt, text)
        if clean is None:
            log.warning("translation rejected by sanitizer (len=%d): %.80s",
                        len(out), out)
            return "", tgt
        out = clean

        # Only finals shape future context (interims are noisy/half-formed).
        if final and out:
            self._history.append((speaker, text, out))
        return out, tgt

    async def refine(self, text: str, fast: str, src: str, tgt: str,
                     speaker: str = "?") -> str | None:
        """Post-final refine pass (fast-then-refine). The quick per-utterance
        translation `fast` is already on screen; this re-examines it WITH the
        recent conversation and returns a better translation, or None when the
        fast one is already fine / on any failure (caller then leaves the
        subtitle untouched). One attempt, temperature 0, never raises."""
        system = (
            f"You are reviewing one line of live subtitle translation from "
            f"{LANG_NAME.get(src, src)} into {LANG_NAME.get(tgt, tgt)}.\n"
            "The line was translated in real time WITHOUT the surrounding "
            "conversation, so it may misread context: a wrong pronoun or "
            "honorific, a term translated inconsistently with earlier lines, or "
            "an awkward rendering of a sentence fragment.\n"
            "Rules:\n"
            "- If the current translation is already accurate and natural, "
            "output it EXACTLY as given, unchanged.\n"
            "- Otherwise output ONLY the corrected translation. No quotes, no "
            "notes, no explanations.\n"
            "- The source text is speech-recognized; if a word is clearly a "
            "mishearing of a similar-sounding word, translate the intended "
            "word.\n"
            "- Never add content that is not in the source."
        )
        ctx = self._context_block()
        user = (f"Line spoken by [{speaker}]: {text}\n"
                f"Current translation: {fast}")
        if LLM["provider"] == "bedrock":
            out = await self._translate_bedrock(user, system, ctx, 0.0, False)
        else:
            out = await self._translate_vllm(user, system, ctx, 0.0, False)
        if not out:
            return None
        # Same anti-commentary guard as translate(): a refine that came back
        # as analysis prose must never replace a good on-screen subtitle.
        out = sanitize_translation(out, tgt, text)
        if out is None or out == fast.strip():
            return None
        # Refined result replaces the fast one in the shared context too, so
        # later lines build on the corrected phrasing.
        for i in range(len(self._history) - 1, -1, -1):
            who, s, t = self._history[i]
            if s == text and t == fast:
                self._history[i] = (who, s, out)
                break
        return out

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
                    temperature=temperature,
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


# ---------------------------------------------------------------------------
# Live insight (separate from translation): an assistant that reads the rolling
# transcript + a user-supplied context and returns a short rolling summary +
# suggested next questions ("live"), or an end-of-meeting wrap with key points
# + next actions ("final"). One-shot and stateless — the app sends the recent
# transcript each time, so this does NOT touch the per-connection Translator
# state or the translation hot path. Bedrock Claude only; if it fails we surface
# an error to the app rather than silently degrading (insight is opt-in, not
# load-bearing like subtitles).
# ---------------------------------------------------------------------------

# Output language for insight/summary — chosen by the app (matches the UI
# language the user reads in). Falls back to Korean.
_LANG_NAME = {"ko": "KOREAN (한국어)", "ja": "JAPANESE (日本語)", "en": "ENGLISH"}


def _insight_system(lang: str) -> str:
    lname = _LANG_NAME.get(lang, _LANG_NAME["ko"])
    return (
        "You are a real-time meeting copilot. You read a running, possibly bilingual "
        "(Korean/Japanese/English) transcript of a live conversation and help the "
        "user — whose ROLE AND GOALS are given below — stay on top of it.\n"
        "The user's context defines who they are and what they care about; let it "
        "steer everything. If they say they are an interviewer focused on system "
        "design, your suggested questions must probe system-design depth — not "
        "generic small talk.\n"
        f"ALWAYS write your output in {lname}, no matter what language the "
        "transcript or the context is in. Every string value you emit (summary, "
        "questions, key points, next actions) must be in that language.\n"
        "Be concise and concrete; never invent facts not in the transcript. Output "
        "ONLY a single JSON object, no markdown, no prose around it."
    )


def _insight_user_prompt(context: str, transcript_lines: list[str], mode: str,
                         lang: str = "ko") -> str:
    ctx = context.strip() or "(no specific context given — act as a neutral, helpful meeting assistant)"
    convo = "\n".join(transcript_lines).strip() or "(transcript empty so far)"
    if mode == "final":
        shape = (
            'Return JSON exactly: {"summary": string, "key_points": [string, ...], '
            '"next_actions": [string, ...]}.\n'
            "- summary: a tight paragraph of what the whole conversation covered.\n"
            "- key_points: the most important takeaways (3-7 bullets).\n"
            "- next_actions: concrete follow-up actions for the user given their role "
            "(who does what next). Empty list if genuinely none."
        )
    else:
        shape = (
            'Return JSON exactly: {"summary": string, "questions": [string, ...]}.\n'
            "- summary: 2-4 sentences capturing the conversation SO FAR (it will be "
            "shown live and replaced on the next refresh, so make it self-contained).\n"
            "- questions: 2-4 sharp questions the user should consider asking NEXT, "
            "tailored to their role/goals and to what was just said. Empty list if "
            "nothing useful to ask yet."
        )
    return (
        f"=== USER CONTEXT (their role & goals) ===\n{ctx}\n\n"
        f"=== TRANSCRIPT (oldest first; 'ME' = the user, 'THEM' = the other side) ===\n"
        f"{convo}\n\n=== TASK ===\n{shape}\n\n"
        f"IMPORTANT: Write every value in {_LANG_NAME.get(lang, _LANG_NAME['ko'])}."
    )


async def generate_insight(context: str, transcript_lines: list[str], mode: str,
                           lang: str = "ko", timeout: float | None = None) -> dict:
    """One-shot Bedrock Claude call producing the insight JSON for `mode`
    ("live" | "final"), with output in `lang` (ko|ja|en). Returns the parsed
    dict, or {"error": "..."} on failure (the app shows the error; insight is
    opt-in so we don't fall back to Qwen).

    `timeout` overrides the request timeout (seconds). Live insight wants the
    snappy default (LLM_TIMEOUT), but the end-of-session summary digests up to
    INSIGHT_FINAL_LINES at once and needs much longer — a long meeting otherwise
    times out and the archive saves an error instead of a summary. The archive
    caller passes a bigger value (mirrors clean_transcript's LLM_TIMEOUT*3)."""
    from anthropic import AsyncAnthropicBedrock

    if lang not in _LANG_NAME:
        lang = "ko"
    max_tokens = (settings.INSIGHT_FINAL_MAX_TOKENS if mode == "final"
                  else settings.INSIGHT_LIVE_MAX_TOKENS)
    client = AsyncAnthropicBedrock(aws_region=settings.BEDROCK_REGION)
    try:
        resp = await client.messages.create(
            model=settings.BEDROCK_MODEL,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": _insight_system(lang)}],
            messages=[{"role": "user",
                       "content": _insight_user_prompt(context, transcript_lines, mode, lang)}],
            timeout=timeout if timeout is not None else settings.LLM_TIMEOUT,
        )
        text = "".join(b.text for b in resp.content
                       if getattr(b, "type", None) == "text").strip()
    except Exception as e:
        log.warning("insight bedrock error: %s", e.__class__.__name__)
        return {"error": f"insight failed: {e.__class__.__name__}"}

    # Claude is told to emit pure JSON, but be defensive: strip ``` fences and
    # grab the outermost {...} so a stray prefix doesn't break parsing.
    return _parse_insight_json(text, mode)


def _parse_insight_json(text: str, mode: str) -> dict:
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`")
        # drop an optional leading "json" language tag
        if s[:4].lower() == "json":
            s = s[4:]
    a, b = s.find("{"), s.rfind("}")
    if a != -1 and b != -1 and b > a:
        s = s[a:b + 1]
    try:
        obj = json.loads(s)
    except Exception:
        log.warning("insight JSON parse failed; returning raw text")
        return {"error": "could not parse insight", "raw": text[:500]}
    # Normalize to the expected shape so the app can rely on the keys existing.
    if mode == "final":
        return {
            "summary": str(obj.get("summary", "")),
            "key_points": [str(x) for x in (obj.get("key_points") or [])],
            "next_actions": [str(x) for x in (obj.get("next_actions") or [])],
        }
    return {
        "summary": str(obj.get("summary", "")),
        "questions": [str(x) for x in (obj.get("questions") or [])],
    }


# ---------------------------------------------------------------------------
# Transcript cleanup (session end, server-side, NO app change).
#
# The live path stores each utterance as {source: <raw whisper text>,
# translation: <MT output>}. Raw whisper is verbatim — filler words ("음/어/
# えーと"), mis-hearings, missing punctuation, and a single sentence split
# across two pause-separated segments. This makes ONE Bedrock pass over the
# whole session that tidies BOTH source and translation: drops fillers, fixes
# obvious mishears/punctuation/spacing, merges sentences split across lines,
# and lightly repairs nonsense by inferring intent from context — WITHOUT
# rewriting into stiff prose or inventing content. Output is stored alongside
# (never replacing) the raw transcript; the dashboard shows cleaned by default
# with a raw toggle.
# ---------------------------------------------------------------------------

_CLEAN_SYSTEM = (
    "You clean up a raw, SPEECH-RECOGNIZED (STT) bilingual (Korean/Japanese/"
    "English) conversation transcript so it reads naturally, WITHOUT changing "
    "what was said.\n"
    "Because the source is STT, errors are similar-SOUNDING words, not typos. "
    "Each input line has an index, a speaker tag (ME or THEM), the raw ASR "
    "'source' text, and its machine 'translation'. Your job, per the cleaned "
    "output:\n"
    "1. Remove filler words and false starts (음, 어, 그, えーと, あの, um, uh, "
    "like) and stutters/repeats.\n"
    "2. HUNT FOR MISHEARD WORDS: read the WHOLE conversation first to learn its "
    "topic and vocabulary. Then, for every word that doesn't fit its context, ask "
    "what similar-sounding Korean/Japanese/English word the speaker actually said "
    "(homophones, particle mishears, foreign loanwords mangled by STT — e.g. "
    "배포/베포/배표, 결제/결재, デプロイ misheard as similar sounds, cutlass/Kafka) "
    "and write the intended word. Judge by pronunciation similarity + context "
    "fit, and NEVER invent facts, numbers, names or topics that aren't there.\n"
    "3. NORMALIZE TERMS ACROSS THE WHOLE TRANSCRIPT: when the same name, product "
    "or technical term was recognized differently on different lines, pick the "
    "most plausible form and use it consistently in every line.\n"
    "4. Fix punctuation, spacing and casing. MERGE lines when one sentence was "
    "split across consecutive same-speaker lines (ASR cut on a breath/pause); "
    "SPLIT a line that clearly runs two sentences together. Never merge across "
    "speakers.\n"
    "5. Clean the 'translation' the SAME way, keeping it faithful to the cleaned "
    "source; merge/split translations to match so pairs stay aligned. If you "
    "corrected a misheard word in the source, fix its translation too.\n"
    "Do NOT over-formalize: keep the speaker's natural, conversational register. "
    "Do NOT summarize or drop substantive content. Preserve original order.\n"
    "Also report the notable WORD-LEVEL corrections you made (misheard words, "
    "term normalizations — NOT filler removal or punctuation) as a 'corrections' "
    "list so the user can audit them: before, after, and a short reason in the "
    "language of the corrected line.\n"
    "Output ONLY a single JSON object: {\"lines\": [{\"stream\": \"me\"|\"them\", "
    "\"source\": string, \"translation\": string}, ...], \"corrections\": "
    "[{\"before\": string, \"after\": string, \"reason\": string}, ...]}. "
    "corrections may be empty. No markdown, no prose."
)


def _is_me(stream) -> bool:
    # The mic stream is tagged "me" by the app (RelayClient.streamTag); be lenient
    # and also accept "mic" in case older/other producers used that.
    return stream in ("me", "mic")


def _clean_user_prompt(lines: list[dict]) -> str:
    rows = []
    for i, x in enumerate(lines):
        tag = "ME" if _is_me(x.get("stream")) else "THEM"
        src = (x.get("source") or "").replace("\n", " ").strip()
        tr = (x.get("translation") or "").replace("\n", " ").strip()
        rows.append(f"[{i}] ({tag}) source: {src}\n     translation: {tr}")
    body = "\n".join(rows) if rows else "(empty)"
    return (
        "=== RAW TRANSCRIPT (oldest first; ME = the user's mic, THEM = the other "
        "side / system audio) ===\n" + body + "\n\n=== TASK ===\n"
        "Return the cleaned transcript as JSON: {\"lines\": [{\"stream\", "
        "\"source\", \"translation\"}, ...]}. Use \"me\" for ME lines and \"them\" "
        "for THEM lines. The cleaned line count may differ from the input because "
        "of merges/splits — that is expected."
    )


async def clean_transcript(
    lines: list[dict],
) -> tuple[list[dict], list[dict]] | None:
    """One Bedrock Claude pass over the WHOLE session that returns a cleaned
    copy of `lines` — de-fillered, punctuation-fixed, split-sentences merged,
    and STT mishears repaired: similar-sounding wrong words are re-classified
    to the intended word using full-conversation context, and inconsistently
    recognized terms are normalized across all lines — for BOTH source and
    translation. Returns (cleaned_lines, corrections) where corrections is the
    model's audit list of word-level fixes ({before, after, reason}, possibly
    empty), or None on any failure (caller keeps raw-only). Never raises."""
    from anthropic import AsyncAnthropicBedrock

    real = [x for x in lines if not x.get("truncated")]
    if not real:
        return None
    real = real[: settings.CLEAN_MAX_LINES]
    client = AsyncAnthropicBedrock(aws_region=settings.BEDROCK_REGION)
    try:
        resp = await client.messages.create(
            model=settings.BEDROCK_MODEL,
            max_tokens=settings.CLEAN_MAX_TOKENS,
            system=[{"type": "text", "text": _CLEAN_SYSTEM}],
            messages=[{"role": "user", "content": _clean_user_prompt(real)}],
            timeout=settings.LLM_TIMEOUT * 3,   # whole-session pass, bigger than a subtitle
        )
        text = "".join(b.text for b in resp.content
                       if getattr(b, "type", None) == "text").strip()
    except Exception as e:
        log.warning("clean_transcript bedrock error: %s", e.__class__.__name__)
        return None
    return _parse_clean_json(text)


def _parse_clean_json(text: str) -> tuple[list[dict], list[dict]] | None:
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`")
        if s[:4].lower() == "json":
            s = s[4:]
    a, b = s.find("{"), s.rfind("}")
    if a != -1 and b != -1 and b > a:
        s = s[a:b + 1]
    try:
        obj = json.loads(s)
        rows = obj.get("lines") if isinstance(obj, dict) else None
        if not isinstance(rows, list):
            return None
    except Exception:
        log.warning("clean_transcript JSON parse failed")
        return None
    out = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        stream = "me" if _is_me(r.get("stream")) else "them"
        out.append({
            "stream": stream,
            "source": str(r.get("source", "")),
            "translation": str(r.get("translation", "")),
        })
    if not out:
        return None
    corrections = []
    for c in (obj.get("corrections") or []):
        if isinstance(c, dict) and c.get("before") and c.get("after"):
            corrections.append({
                "before": str(c["before"]),
                "after": str(c["after"]),
                "reason": str(c.get("reason", "")),
            })
    return out, corrections
