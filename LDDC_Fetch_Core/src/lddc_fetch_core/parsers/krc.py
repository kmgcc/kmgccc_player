# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json
import re
from base64 import b64decode

from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord

KRC_MAGICHEADER = b"krc18"

_TAG_SPLIT_PATTERN = re.compile(r"^\[(\w+):([^\]]*)\]$")
_LINE_SPLIT_PATTERN = re.compile(r"^\[(\d+),(\d+)\](.*)$")  # 逐行匹配
_WORD_SPLIT_PATTERN = re.compile(r"(?:\[\d+,\d+\])?<(?P<start>\d+),(?P<duration>\d+),\d+>(?P<content>(?:.(?!\d+,\d+,\d+>))*)")  # 逐字匹配


def krc2bundle(krc: str) -> tuple[dict[str, str], LyricsData, LyricsData | None, LyricsData | None]:
    tags: dict[str, str] = {}
    orig: LyricsData = []
    roma: LyricsData = []
    ts: LyricsData = []

    for raw_line in krc.splitlines():
        line = raw_line.strip()
        if not line.startswith("["):
            continue

        if tag_match := _TAG_SPLIT_PATTERN.match(line):
            tags[tag_match.group(1)] = tag_match.group(2)
            continue

        if line_match := _LINE_SPLIT_PATTERN.match(line):
            line_start, line_duration, line_content = line_match.groups()
            line_start_i = int(line_start)
            line_end_i = line_start_i + int(line_duration)

            words = [
                LyricsWord(
                    line_start_i + int(word_match.group("start")),
                    line_start_i + int(word_match.group("start")) + int(word_match.group("duration")),
                    word_match.group("content"),
                )
                for word_match in _WORD_SPLIT_PATTERN.finditer(line_content)
            ]
            if not words:
                words = [LyricsWord(line_start_i, line_end_i, line_content)]
            orig.append(LyricsLine(line_start_i, line_end_i, words))

    if "language" in tags and tags["language"].strip():
        languages = json.loads(b64decode(tags["language"].strip()))
        for language in languages.get("content", []):
            if language.get("type") == 0:
                offset = 0
                for i, line in enumerate(orig):
                    if all(not w.text for w in line.words):
                        offset += 1
                        continue
                    roma.append(
                        LyricsLine(
                            line.start,
                            line.end,
                            [LyricsWord(word.start, word.end, language["lyricContent"][i - offset][j]) for j, word in enumerate(line.words)],
                        ),
                    )
            elif language.get("type") == 1:
                for i, line in enumerate(orig):
                    ts.append(LyricsLine(line.start, line.end, [LyricsWord(line.start, line.end, language["lyricContent"][i][0])]))

    return tags, orig, (ts if ts else None), (roma if roma else None)

