# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from dataclasses import dataclass

from lddc_fetch_core.exceptions import LyricsNotFoundError
from lddc_fetch_core.lrc_render import render_lrc
from lddc_fetch_core.match import score_candidate
from lddc_fetch_core.models import LrcMode, LyricsBundle, Song, Source, TranslationMode
from lddc_fetch_core.translate.openai import translate_data_openai

from .providers.kg import KGProvider
from .providers.lrclib import LrclibProvider
from .providers.ne import NEProvider
from .providers.qm import QMProvider


@dataclass(frozen=True)
class _ScoredSong:
    score: float
    song: Song


_PROVIDERS: dict[Source, object] = {}


def _get_provider(source: Source) -> object:
    if source in _PROVIDERS:
        return _PROVIDERS[source]
    provider: object
    if source == Source.LRCLIB:
        provider = LrclibProvider()
    elif source == Source.QM:
        provider = QMProvider()
    elif source == Source.KG:
        provider = KGProvider()
    elif source == Source.NE:
        provider = NEProvider()
    else:
        raise ValueError(f"Unsupported source: {source}")
    _PROVIDERS[source] = provider
    return provider


def _keyword_variants(title: str, artist: str | None) -> list[str]:
    title = title.strip()
    artist = artist.strip() if artist else None
    if not title:
        return []
    if artist:
        return [f"{artist} - {title}", f"{artist} {title}", title]
    return [title]


def _is_verbatim(bundle: LyricsBundle) -> bool:
    if not bundle.orig:
        return False
    for ln in bundle.orig:
        if len(ln.words) > 1 and any(w.start is not None for w in ln.words):
            return True
    return False


def fetch_lyrics_bundle(
    *,
    title: str,
    artist: str | None = None,
    sources: tuple[Source, ...] = (Source.LRCLIB, Source.QM, Source.KG, Source.NE),
    min_score: float = 55.0,
    max_candidates: int = 8,
    mode: LrcMode = "verbatim",  # Used for ranking
    translation: TranslationMode = "none",  # Used for ranking + OpenAI
    # OpenAI translation (only used when translation="openai"/"auto")
    openai_base_url: str = "",
    openai_api_key: str = "",
    openai_model: str = "",
    openai_target_lang: str = "简体中文",
) -> LyricsBundle:
    """获取最佳歌词 Bundle (包含元数据、原文、翻译等)，不进行最终渲染 string。"""
    title = title.strip()
    artist = artist.strip() if artist else None
    if not title:
        raise ValueError("title 不能为空")
    if max_candidates <= 0:
        raise ValueError("max_candidates 必须 > 0")

    keywords = _keyword_variants(title, artist)
    scored: dict[tuple, _ScoredSong] = {}

    # search phase (stop early once we have good candidates)
    for keyword in keywords:
        for src in sources:
            try:
                provider = _get_provider(src)
                results = provider.search(keyword, page=1)  # type: ignore[attr-defined]
            except Exception:
                continue
            for song in results:
                cand_artist = str(song.artist) if song.artist else None
                s = score_candidate(title, artist, song.title, cand_artist)
                if s >= min_score:
                    song_key = (song.source, song.id, song.title, cand_artist, song.album, song.duration_ms)
                    prev = scored.get(song_key)
                    if prev is None or s > prev.score:
                        scored[song_key] = _ScoredSong(s, song)
        if scored:
            break

    if not scored:
        raise LyricsNotFoundError("没有找到符合要求的歌曲")

    candidates = sorted((v for v in scored.values()), key=lambda x: x.score, reverse=True)[:max_candidates]

    fetched: list[tuple[_ScoredSong, LyricsBundle]] = []
    for cand in candidates:
        provider = _get_provider(cand.song.source)
        try:
            bundle = provider.get_lyrics(cand.song)  # type: ignore[attr-defined]
        except Exception:
            continue
        if bundle.orig:
            fetched.append((cand, bundle))

    if not fetched:
        raise LyricsNotFoundError("候选歌曲存在，但获取歌词失败")

    def rank(item: tuple[_ScoredSong, LyricsBundle]) -> tuple:
        cand, bundle = item
        return (
            cand.score,
            1 if (mode != "line" and _is_verbatim(bundle)) else 0,
            1 if (translation != "none" and bundle.ts) else 0,
            # 按 sources 的优先级作为最后 tie-breaker
            -sources.index(bundle.song.source) if bundle.song.source in sources else 0,
        )

    best = max(fetched, key=rank)[1]

    include_translation = translation != "none"
    if translation in ("openai", "auto") and (best.ts is None) and include_translation:
        if best.orig is None:
            include_translation = False
        else:
            try:
                best.ts = translate_data_openai(
                    orig=best.orig,
                    target_lang=openai_target_lang,
                    base_url=openai_base_url,
                    api_key=openai_api_key,
                    model=openai_model,
                )
            except Exception:
                if translation == "openai":
                    raise

    return _clean_lyrics_bundle(best)


def _clean_lyrics_data(data: LyricsData) -> LyricsData:
    out: LyricsData = []
    for line in data:
        text = line.text().strip()
        # QQ 音乐等源经常会有 "//" 这种占位符
        if text == "//":
            continue
        out.append(line)
    return out


def _clean_lyrics_bundle(bundle: LyricsBundle) -> LyricsBundle:
    if bundle.orig:
        bundle.orig = _clean_lyrics_data(bundle.orig)
    if bundle.ts:
        bundle.ts = _clean_lyrics_data(bundle.ts)
    if bundle.roma:
        bundle.roma = _clean_lyrics_data(bundle.roma)
    return bundle


def fetch_lrc(
    *,
    title: str,
    artist: str | None = None,
    sources: tuple[Source, ...] = (Source.LRCLIB, Source.QM, Source.KG, Source.NE),
    min_score: float = 55.0,
    max_candidates: int = 8,
    mode: LrcMode = "verbatim",
    translation: TranslationMode = "none",
    offset_ms: int = 0,
    ms_digits: int = 3,
    add_end_timestamp_line: bool = False,
    # OpenAI translation (only used when translation="openai"/"auto")
    openai_base_url: str = "",
    openai_api_key: str = "",
    openai_model: str = "",
    openai_target_lang: str = "简体中文",
) -> str:
    """输入歌名+歌手，返回 LRC 歌词文本。

    支持：
    - `mode`: "line"(逐行) / "verbatim"(逐字) / "enhanced"(增强)
    - `translation`:
        - "none": 不带翻译
        - "provider": 使用歌词源自带翻译(ts)，如果没有则不输出翻译
        - "openai": 用 OpenAI 翻译生成 ts
        - "auto": 有 ts 就用，否则尝试 OpenAI 翻译
    - `offset_ms`: 时间戳整体偏移(毫秒，可为负)
    """
    best = fetch_lyrics_bundle(
        title=title,
        artist=artist,
        sources=sources,
        min_score=min_score,
        max_candidates=max_candidates,
        mode=mode,
        translation=translation,
        openai_base_url=openai_base_url,
        openai_api_key=openai_api_key,
        openai_model=openai_model,
        openai_target_lang=openai_target_lang,
    )

    include_translation = translation != "none"
    if translation == "provider":
        include_translation = best.ts is not None

    return render_lrc(
        source=best.song.source,
        tags=best.tags,
        orig=best.orig or [],
        ts=best.ts,
        mode=mode,
        include_translation=include_translation,
        offset_ms=offset_ms,
        ms_digits=ms_digits,
        add_end_timestamp_line=add_end_timestamp_line,
    )
