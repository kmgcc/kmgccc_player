# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import re

from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord, Source
from lddc_fetch_core.timeutil import time2ms

_TAG_SPLIT_PATTERN = re.compile(r"^\[(?P<k>\w+):(?P<v>[^\]]*)\]$")
_LINE_SPLIT_PATTERN = re.compile(r"^\[(\d+):(\d+)\.(\d+)\](.*)$")
_ENHANCED_WORD_SPLIT_PATTERN = re.compile(r"<(\d+):(\d+)\.(\d+)>((?:(?!<\d+:\d+\.\d+>).)*)(?:<(\d+):(\d+)\.(\d+)>$)?")
_WORD_SPLIT_PATTERN = re.compile(r"((?:(?!\[\d+:\d+\.\d+\]).)*)(?:\[(\d+):(\d+)\.(\d+)\])?")
_MULTI_LINE_SPLIT_PATTERN = re.compile(r"^((?:\[\d+:\d+\.\d+\]){2,})(.*)$")
_TIMESTAMPS_PATTERN = re.compile(r"\[(\d+):(\d+)\.(\d+)\]")


def lrc2data(lrc: str, source: Source | None = None) -> tuple[dict[str, str], LyricsData]:
    tags: dict[str, str] = {}
    data: LyricsData = []

    for raw_line in lrc.splitlines():
        line = raw_line.strip()
        if not line or not line.startswith("["):
            continue

        if line_match := _LINE_SPLIT_PATTERN.match(line):
            m, s, ms, line_content = line_match.groups()
            start = time2ms(m, s, ms)
            end: int | None = None
            words: list[LyricsWord] = []

            if source == Source.NE and (multi_match := _MULTI_LINE_SPLIT_PATTERN.match(line)):
                timestamps, line_content = multi_match.groups()
                for ts_match in _TIMESTAMPS_PATTERN.finditer(timestamps):
                    ts_start = time2ms(*ts_match.groups())
                    data.append(LyricsLine(ts_start, None, [LyricsWord(ts_start, None, line_content)]))
                continue

            if "<" in line_content and ">" in line_content:
                for enhanced_word_parts in _ENHANCED_WORD_SPLIT_PATTERN.finditer(line_content):
                    s_m, s_s, s_ms, word_str, e_m, e_s, e_ms = enhanced_word_parts.groups()
                    word_start = time2ms(s_m, s_s, s_ms)
                    word_end = time2ms(e_m, e_s, e_ms) if e_m and e_s and e_ms else None
                    end = word_end or end
                    if words:
                        words[-1] = LyricsWord(words[-1].start, word_start, words[-1].text)
                    if word_str:
                        words.append(LyricsWord(word_start, word_end, word_str))
            else:
                word_parts = _WORD_SPLIT_PATTERN.findall(line_content)
                if word_parts:
                    for w_i, (word_str, e_m, e_s, e_ms) in enumerate(word_parts):
                        word_start = start if not words else words[-1].end
                        word_end = time2ms(e_m, e_s, e_ms) if e_m and e_s and e_ms else None
                        if w_i == len(word_parts) - 1:
                            end = word_end or end
                        if word_str:
                            words.append(LyricsWord(word_start, word_end, word_str))

            if words:
                data.append(LyricsLine(start, end, words))
            continue

        if tag_match := _TAG_SPLIT_PATTERN.match(line):
            tags[tag_match.group("k")] = tag_match.group("v")
            continue

    # sort and fill prev end
    data = sorted([ln for ln in data if ln.start is not None], key=lambda x: x.start)  # type: ignore[arg-type]
    for i in range(1, len(data)):
        prev = data[i - 1]
        cur = data[i]
        if prev.end is None and prev.start is not None and cur.start is not None:
            data[i - 1] = LyricsLine(prev.start, cur.start, prev.words)

    data = [ln for ln in data if ln.words]
    return tags, data

