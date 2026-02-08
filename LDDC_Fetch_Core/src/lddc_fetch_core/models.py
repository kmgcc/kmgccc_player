# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable, Literal

LrcMode = Literal["line", "verbatim", "enhanced"]
TranslationMode = Literal["none", "provider", "openai", "auto"]


class Source(str, Enum):
    LRCLIB = "LRCLIB"
    QM = "QM"
    KG = "KG"
    NE = "NE"


class Artist(tuple[str]):
    def __new__(cls, artist: str | Iterable[str]) -> "Artist":
        if isinstance(artist, str):
            items = [artist]
        else:
            items = list(artist)
        # dedupe keep-order
        seen: set[str] = set()
        out: list[str] = []
        for s in items:
            s = (s or "").strip()
            if not s or s in seen:
                continue
            seen.add(s)
            out.append(s)
        return super().__new__(cls, out)

    def __str__(self) -> str:
        return self.str()

    def str(self, sep: str = "/") -> str:
        return sep.join(self)

    def __bool__(self) -> bool:  # noqa: D105
        return bool(self.str())


@dataclass(frozen=True, slots=True)
class Song:
    source: Source
    id: str | None = None
    title: str | None = None
    artist: Artist | None = None
    album: str | None = None
    duration_ms: int | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def artist_title(self) -> str:
        a = str(self.artist) if self.artist else ""
        t = self.title or ""
        if a and t:
            return f"{a} - {t}"
        return a + t


@dataclass(frozen=True, slots=True)
class LyricsWord:
    start: int | None
    end: int | None
    text: str


@dataclass(frozen=True, slots=True)
class LyricsLine:
    start: int | None
    end: int | None
    words: list[LyricsWord]

    def text(self) -> str:
        return "".join(w.text for w in self.words)


LyricsData = list[LyricsLine]


@dataclass(slots=True)
class LyricsBundle:
    song: Song
    tags: dict[str, str] = field(default_factory=dict)
    orig: LyricsData | None = None
    ts: LyricsData | None = None
    roma: LyricsData | None = None

