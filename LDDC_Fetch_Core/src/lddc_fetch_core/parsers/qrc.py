# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import re

from lddc_fetch_core.exceptions import LyricsProcessingError
from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord

from .lrc import lrc2data
from .utils import plaintext2data

QRC_MAGICHEADER = b"\x98%\xb0\xac\xe3\x02\x83h\xe8\xfcl"

_QRC_PATTERN = re.compile(r'<Lyric_1 LyricType="1" LyricContent="(?P<content>.*?)"/>', re.DOTALL)
_TAG_SPLIT_PATTERN = re.compile(r"^\[(\w+):([^\]]*)\]$")
_LINE_SPLIT_PATTERN = re.compile(r"^\[(\d+),(\d+)\](.*)$")  # 逐行匹配
_WORD_SPLIT_PATTERN = re.compile(r"(?:\[\d+,\d+\])?(?P<content>(?:(?!\(\d+,\d+\)).)*)\((?P<start>\d+),(?P<duration>\d+)\)")  # 逐字匹配
_WORD_TIMESTAMP_PATTERN = re.compile(r"^\(\d+,\d+\)$")


def qrc2data(s_qrc: str) -> tuple[dict[str, str], LyricsData]:
    qrc_match = _QRC_PATTERN.search(s_qrc)
    if not qrc_match or not qrc_match.group("content"):
        msg = "不支持的歌词格式"
        raise LyricsProcessingError(msg)
    tags: dict[str, str] = {}
    lrc_list: LyricsData = []

    for raw_line in qrc_match.group("content").splitlines():
        line = raw_line.strip()
        if line_match := _LINE_SPLIT_PATTERN.match(line):
            line_start, line_duration, line_content = line_match.groups()
            line_start_i = int(line_start)
            line_end_i = line_start_i + int(line_duration)

            if line_content.startswith("(") and line_content.endswith(")") and _WORD_TIMESTAMP_PATTERN.match(line_content):
                lrc_list.append(LyricsLine(line_start_i, line_end_i, []))
                continue

            words = [
                LyricsWord(int(word_match.group("start")), int(word_match.group("start")) + int(word_match.group("duration")), word_match.group("content"))
                for word_match in _WORD_SPLIT_PATTERN.finditer(line_content)
                if word_match.group("content") != "\r"
            ]
            if not words:
                words = [LyricsWord(line_start_i, line_end_i, line_content)]

            lrc_list.append(LyricsLine(line_start_i, line_end_i, words))
        else:
            tag_split_content = re.findall(_TAG_SPLIT_PATTERN, line)
            if tag_split_content:
                tags.update({tag_split_content[0][0]: tag_split_content[0][1]})

    return tags, lrc_list


def qrc_str_parse(lyric: str) -> tuple[dict[str, str], LyricsData]:
    if _QRC_PATTERN.search(lyric):
        return qrc2data(lyric)
    if "[" in lyric and "]" in lyric:
        try:
            return lrc2data(lyric)
        except Exception:
            pass
    return {}, plaintext2data(lyric)

