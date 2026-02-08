# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import httpx

from lddc_fetch_core.cache import cache
from lddc_fetch_core.exceptions import TranslateError
from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord
from lddc_fetch_core.version import __version__


def translate_lines_openai(
    *,
    lines: list[str],
    target_lang: str,
    base_url: str,
    api_key: str,
    model: str,
    timeout_s: int = 120,
) -> list[str]:
    if not (base_url.strip() and api_key.strip() and model.strip()):
        raise TranslateError("OpenAI 配置不完整(base_url/api_key/model)")

    cache_key = (__version__, "openai", target_lang, tuple(lines).__hash__(), base_url, model)
    cached = cache.get(cache_key)
    if isinstance(cached, list) and len(cached) == len(lines):
        return cached

    orig_lines = "\n".join(f"{i + 1:02d}|{text}" for i, text in enumerate(lines))
    prompt = (
        "You are a professional lyric translator.\n"
        f"Translate the following lyrics into {target_lang} line-by-line.\n"
        "Do not combine or split lines.\n"
        "Output only in the following format:\n"
        "01|Translated line 1\n"
        "02|Translated line 2\n\n"
        "Input:\n"
        f"{orig_lines}\n"
    )

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": f"lddc-fetch-core/{__version__}",
    }
    data = {"model": model, "messages": [{"role": "user", "content": prompt}], "stream": False}

    resp = httpx.post(f"{base_url.rstrip('/')}/chat/completions", headers=headers, json=data, timeout=timeout_s)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    content = str(content).strip()
    if content.startswith("```"):
        content = content[3:].strip()
    if content.endswith("```"):
        content = content[:-3].strip()

    parsed = []
    for line in content.splitlines():
        if "|" not in line:
            continue
        _idx, txt = line.split("|", 1)
        parsed.append(txt)

    if len(parsed) != len(lines):
        raise TranslateError(f"模型输出行数不匹配: 输入{len(lines)} 输出{len(parsed)}")

    cache.set(cache_key, parsed, expire_seconds=14400)
    return parsed


def translate_data_openai(
    *,
    orig: LyricsData,
    target_lang: str,
    base_url: str,
    api_key: str,
    model: str,
) -> LyricsData:
    texts = ["".join(w.text for w in ln.words) for ln in orig]
    trans = translate_lines_openai(lines=texts, target_lang=target_lang, base_url=base_url, api_key=api_key, model=model)
    out: LyricsData = []
    for ln, t in zip(orig, trans, strict=True):
        out.append(LyricsLine(ln.start, ln.end, [LyricsWord(ln.start, ln.end, t)]))
    return out

