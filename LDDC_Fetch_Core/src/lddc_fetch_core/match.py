# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import re
from difflib import SequenceMatcher

symbol_map = {
    "（": "(",
    "）": ")",
    "：": ":",
    "！": "!",
    "？": "?",
    "／": "/",
    "＆": "&",
    "＊": "*",
    "＠": "@",
    "＃": "#",
    "＄": "$",
    "％": "%",
    "＼": "\\",
    "｜": "|",
    "＝": "=",
    "＋": "+",
    "－": "-",
    "＜": "<",
    "＞": ">",
    "［": "[",
    "］": "]",
    "｛": "{",
    "｝": "}",
}

TITLE_TAG_PATTERN = re.compile(
    r"|".join(
        [
            r"[-<(\[～]([～\]^)>-]*)[～\]^)>-]",  # brackets
            r"(\w+ ?(?:(?:solo |size )?ver(?:sion)?\.?|size|style|mix(?:ed)?|edit(?:ed)?|版|solo))",
            r"(纯音乐|inst\.?(?:rumental)|off ?vocal(?: ?[Vv]er.)?)",
        ],
    ),
)


def unified_symbol(text: str) -> str:
    text = (text or "").strip()
    for k, v in symbol_map.items():
        text = text.replace(k, v)
    return re.sub(r"\s+", " ", text)


def text_difference(text1: str, text2: str) -> float:
    if text1 == text2:
        return 1.0
    differ = SequenceMatcher(lambda x: x == " ", text1, text2)
    return differ.ratio()


def normalize_title(title: str) -> str:
    title = unified_symbol(title).lower()
    # remove common tags (ver./mix/etc) to improve matching
    title = TITLE_TAG_PATTERN.sub("", title)
    return re.sub(r"\s+", " ", title).strip()


def normalize_artist(artist: str) -> str:
    return unified_symbol(artist).lower().replace("·", "・")


def score_candidate(title: str, artist: str | None, cand_title: str | None, cand_artist: str | None) -> float:
    t1 = normalize_title(title)
    t2 = normalize_title(cand_title or "")
    title_score = text_difference(t1, t2) * 100.0

    if artist and cand_artist:
        a1 = normalize_artist(artist)
        a2 = normalize_artist(cand_artist)
        artist_score = text_difference(a1, a2) * 100.0
        score = title_score * 0.55 + artist_score * 0.45
    else:
        score = title_score

    if title_score < 30:
        score = max(0.0, score - 35.0)
    return max(0.0, score)

