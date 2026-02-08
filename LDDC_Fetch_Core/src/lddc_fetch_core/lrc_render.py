# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from typing import Callable

from lddc_fetch_core.models import LyricsData, LyricsLine, LyricsWord, Source
from lddc_fetch_core.timeutil import ms2formattime, ms2roundedtime


def _formattime_sub1(formattime: str) -> str:
    m, s_ms = formattime.split(":")
    s, ms = s_ms.split(".")
    ms_len = len(ms)
    if ms not in ("00", "000"):
        ms = f"{int(ms) - 1:0{ms_len}d}"
    elif s != "00":
        s = str(int(s) - 1)
    elif m != "00":
        m = str(int(m) - 1)
    return f"{m}:{s}.{ms}"


def _line_text(words: list[LyricsWord]) -> str:
    return "".join(w.text for w in words if w.text != "")


def lyrics_line2str(
    line: LyricsLine,
    *,
    mode: str,
    line_start_time: int | None,
    line_end_time: int | None,
    ms_converter: Callable[[int], str],
) -> str:
    text = ""
    if line_start_time is not None:
        text += f"[{ms_converter(line_start_time)}]"

    if mode == "line":
        return text + _line_text(line.words)

    symbols = ("[", "]") if mode == "verbatim" else ("<", ">")

    last_end = line.start if mode == "verbatim" else None
    for word in line.words:
        start, end, wtxt = word.start, word.end, word.text
        if start is not None and start != last_end:
            text += f"{symbols[0]}{ms_converter(max(start, line_start_time if line_start_time is not None else start))}{symbols[1]}"
        text += wtxt
        if end is not None:
            text += f"{symbols[0]}{ms_converter(end)}{symbols[1]}"
        last_end = end

    if line_end_time is not None and not text.endswith(symbols[1]):
        text += f"{symbols[0]}{ms_converter(line_end_time)}{symbols[1]}"

    return text


def align_translation(orig: LyricsData, ts: LyricsData) -> dict[int, LyricsLine]:
    """把翻译行对齐到原文行：优先同 start，其次同长度按 index，否则取最近 start。"""
    out: dict[int, LyricsLine] = {}
    ts_by_start = {ln.start: ln for ln in ts if ln.start is not None}

    # exact start match
    for i, o in enumerate(orig):
        if o.start is not None and o.start in ts_by_start:
            out[i] = ts_by_start[o.start]

    if len(out) == len(orig):
        return out

    # index match when same length
    if len(orig) == len(ts):
        for i, t in enumerate(ts):
            out.setdefault(i, t)
        return out

    # nearest start
    ts_with_start = [ln for ln in ts if ln.start is not None]
    if not ts_with_start:
        return out

    for i, o in enumerate(orig):
        if i in out:
            continue
        if o.start is None:
            continue
        best = min(ts_with_start, key=lambda t: abs((t.start or 0) - o.start))
        out[i] = best
    return out


def render_lrc(
    *,
    source: Source,
    tags: dict[str, str],
    orig: LyricsData,
    ts: LyricsData | None,
    mode: str,
    include_translation: bool,
    offset_ms: int,
    ms_digits: int = 3,
    add_end_timestamp_line: bool = False,
) -> str:
    ms_converter = ms2roundedtime if ms_digits == 2 else ms2formattime

    def adj(t: int | None) -> int | None:
        return max(t + offset_ms, 0) if t is not None else None

    lines: list[str] = []
    head = []
    for k in ("ti", "ar", "al", "by"):
        if tags.get(k):
            head.append(f"[{k}:{tags[k]}]")
    if offset_ms:
        head.append(f"[offset:{offset_ms}]")
    head.append("[tool:lddc-fetch-core]")
    if head:
        lines.append("\n".join(head))
        lines.append("")

    ts_map = align_translation(orig, ts) if (include_translation and ts) else {}

    for idx, oline in enumerate(orig):
        line_start_time = oline.words[0].start if oline.words and oline.words[0].start is not None else oline.start
        line_end_time = oline.words[-1].end if oline.words and oline.words[-1].end is not None else oline.end

        text = lyrics_line2str(
            LyricsLine(adj(oline.start), adj(oline.end), [LyricsWord(adj(w.start), adj(w.end), w.text) for w in oline.words]),
            mode=mode,
            line_start_time=adj(line_start_time),
            line_end_time=adj(line_end_time),
            ms_converter=ms_converter,
        )
        lines.append(text)

        if idx in ts_map:
            tline = ts_map[idx]
            t_start = tline.start if tline.start is not None else oline.start
            t_text = lyrics_line2str(
                LyricsLine(adj(tline.start), adj(tline.end), [LyricsWord(adj(w.start), adj(w.end), w.text) for w in tline.words]),
                mode="line",
                line_start_time=adj(t_start),
                line_end_time=adj(tline.end),
                ms_converter=ms_converter,
            )
            lines.append(t_text)

        if mode == "line" and add_end_timestamp_line and line_end_time is not None:
            lines.append(f"[{ms_converter(adj(line_end_time) or 0)}]")

    return "\n".join(lines).strip() + "\n"

