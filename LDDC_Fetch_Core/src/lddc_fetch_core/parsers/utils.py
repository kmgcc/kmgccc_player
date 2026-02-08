# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord


def plaintext2data(plaintext: str) -> LyricsData:
    data: LyricsData = []
    for line in plaintext.splitlines():
        data.append(LyricsLine(None, None, [LyricsWord(None, None, line)]))
    return data

