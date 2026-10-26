# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json
from dataclasses import replace

import httpx

from lddc_fetch_core.exceptions import APIParamsError, APIRequestError
from lddc_fetch_core.models import Artist, LyricsBundle, Song, Source
from lddc_fetch_core.parsers.lrc import lrc2data
from lddc_fetch_core.parsers.utils import plaintext2data
from lddc_fetch_core.version import __version__


class LrclibProvider:
    source = Source.LRCLIB

    def __init__(self) -> None:
        self.client = httpx.Client(
            headers={
                "User-Agent": f"lddc-fetch-core/{__version__} (https://github.com/kmgcc/kmgccc_player)",
                "Accept": "application/json",
            },
            timeout=30,
        )
        # Search already returns the complete lyrics record. Retain only the
        # current page, keyed by exact ID, rather than fetching it a second time.
        self._search_records: dict[str, dict] = {}

    def _make_request(self, endpoint: str, params: dict | None = None) -> dict | list:
        url = f"https://lrclib.net/api{endpoint}"
        resp = self.client.get(url, params=params)
        try:
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise APIRequestError(f"lrclib API请求失败: {resp.status_code}") from e
        try:
            return resp.json()
        except json.JSONDecodeError as e:
            raise APIRequestError("lrclib API响应解析失败") from e

    def search(self, keyword: str, page: int = 1) -> list[Song]:
        data = self._make_request("/search", {"q": keyword})
        if not isinstance(data, list):
            raise APIRequestError("lrclib /search 响应格式异常")
        items = data[(page - 1) * 20 : page * 20]
        songs: list[Song] = []
        records: dict[str, dict] = {}
        for item in items:
            try:
                songs.append(
                    Song(
                        source=self.source,
                        id=str(item.get("id")) if item.get("id") is not None else None,
                        title=item.get("trackName"),
                        artist=Artist(item.get("artistName") or "") if item.get("artistName") else None,
                        album=item.get("albumName"),
                        duration_ms=int(float(item.get("duration", 0)) * 1000) if item.get("duration") is not None else None,
                        # Candidate extras cross the helper's JSON boundary as
                        # string values, matching the native client's model.
                        extra={"instrumental": "true" if item.get("instrumental") else "false"},
                    ),
                )
                if songs[-1].id:
                    records[songs[-1].id] = item
            except Exception:
                continue
        # Replace the page atomically; concurrent readers keep a complete old
        # or new snapshot, and unrelated searches cannot grow this cache.
        self._search_records = records
        return songs

    def get_lyrics(self, song: Song) -> LyricsBundle:
        if song.id:
            record_id = str(song.id).strip()
            if not record_id.isascii() or not record_id.isdecimal():
                raise APIParamsError("lrclib 记录 ID 无效")
            # Keep the selected recording even when its album or duration is
            # absent. A failed ID lookup must not silently select another one.
            data = self._search_records.get(record_id)
            if data is None:
                data = self._make_request(f"/get/{record_id}")
        else:
            if not song.title or not song.artist:
                raise APIParamsError("lrclib 缺少必要参数(需要 title/artist 或记录 ID)")
            params = {
                "track_name": song.title,
                "artist_name": song.artist.str(),
            }
            if song.album:
                params["album_name"] = song.album
            if song.duration_ms:
                params["duration"] = song.duration_ms / 1000
            data = self._make_request("/get", params)
        if not isinstance(data, dict):
            raise APIRequestError("lrclib /get 响应格式异常")
        if "error" in data:
            raise APIRequestError(f"lrclib API错误: {data['error']}")

        bundle = LyricsBundle(song=replace(
            song,
            extra={**song.extra, "instrumental": "true" if data.get("instrumental") else "false"},
        ))
        bundle.tags = {
            "ti": data.get("trackName") or song.title or "",
            "ar": data.get("artistName") or (song.artist.str() if song.artist else ""),
            "al": data.get("albumName") or song.album or "",
        }

        if data.get("syncedLyrics"):
            tags, orig = lrc2data(str(data["syncedLyrics"]))
            bundle.tags.update(tags)
            bundle.orig = orig
        if not bundle.orig and data.get("plainLyrics"):
            bundle.orig = plaintext2data(str(data["plainLyrics"]))
        if bundle.orig is None:
            # Instrumental records legitimately have no lyric text. Keep the
            # flag above and let the existing empty-content path handle them.
            bundle.orig = []

        return bundle
