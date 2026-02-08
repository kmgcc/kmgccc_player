# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json

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
                "User-Agent": f"lddc-fetch-core/{__version__}",
                "Accept": "application/json",
            },
            timeout=30,
        )

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
                        extra={"instrumental": bool(item.get("instrumental"))},
                    ),
                )
            except Exception:
                continue
        return songs

    def get_lyrics(self, song: Song) -> LyricsBundle:
        if not song.title or not song.artist or not song.album or not song.duration_ms:
            raise APIParamsError("lrclib 缺少必要参数(需要 title/artist/album/duration)")

        params = {
            "track_name": song.title,
            "artist_name": song.artist.str(),
            "album_name": song.album,
            "duration": song.duration_ms / 1000,
        }
        data = self._make_request("/get", params)
        if not isinstance(data, dict):
            raise APIRequestError("lrclib /get 响应格式异常")
        if "error" in data:
            raise APIRequestError(f"lrclib API错误: {data['error']}")

        bundle = LyricsBundle(song=song)
        bundle.tags = {
            "ti": data.get("trackName") or song.title,
            "ar": data.get("artistName") or song.artist.str(),
            "al": data.get("albumName") or song.album,
        }

        if data.get("syncedLyrics"):
            tags, orig = lrc2data(str(data["syncedLyrics"]))
            bundle.tags.update(tags)
            bundle.orig = orig
        elif data.get("plainLyrics"):
            bundle.orig = plaintext2data(str(data["plainLyrics"]))
        else:
            bundle.orig = plaintext2data("")

        return bundle

