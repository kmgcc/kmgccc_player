# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations


def ms2formattime(ms: int) -> str:
    ms = max(ms, 0)
    m = ms // 60000
    s = (ms % 60000) // 1000
    ms_part = ms % 1000
    return f"{m:02d}:{s:02d}.{ms_part:03d}"


def ms2roundedtime(ms: int) -> str:
    # 2-digit millisecond rounding (centisecond)
    ms = max(ms, 0)
    m = ms // 60000
    s = (ms % 60000) // 1000
    cs = (ms % 1000) // 10
    return f"{m:02d}:{s:02d}.{cs:02d}"


def time2ms(m: str, s: str, ms: str) -> int:
    # LDDC parser uses variable-digit ms (2 or 3); support both.
    mm = int(m)
    ss = int(s)
    mss = int(ms)
    if len(ms) == 2:
        mss *= 10
    return (mm * 60 + ss) * 1000 + mss

