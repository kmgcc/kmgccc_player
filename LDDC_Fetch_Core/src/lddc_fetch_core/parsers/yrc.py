# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import re

from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord

_LINE_SPLIT_PATTERN = re.compile(r"^\[(\d+),(\d+)\](.*)$")  # 逐行匹配
_WORD_SPLIT_PATTERN = re.compile(r"(?:\[\d+,\d+\])?\((?P<start>\d+),(?P<duration>\d+),\d+\)(?P<content>(?:.(?!\d+,\d+,\d+\)))*)")  # 逐字匹配


def yrc2data(yrc: str) -> LyricsData:
    data: LyricsData = []
    for raw_line in yrc.splitlines():
        line = raw_line.strip()
        if not line.startswith("["):
            continue

        line_match = _LINE_SPLIT_PATTERN.match(line)
        if not line_match:
            continue
        line_start, line_duration, line_content = line_match.groups()
        line_start_i = int(line_start)
        line_end_i = line_start_i + int(line_duration)

        words = [
            LyricsWord(int(word_match.group("start")), int(word_match.group("start")) + int(word_match.group("duration")), word_match.group("content"))
            for word_match in _WORD_SPLIT_PATTERN.finditer(line_content)
        ]
        if not words:
            words = [LyricsWord(line_start_i, line_end_i, line_content)]

        data.append(LyricsLine(line_start_i, line_end_i, words))

    return data

