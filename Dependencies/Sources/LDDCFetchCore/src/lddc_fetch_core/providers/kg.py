# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

# ruff: noqa: S311, S324

from __future__ import annotations

import hashlib
import json
import random
import time
from base64 import b64decode, b64encode
from threading import Lock

import httpx

from lddc_fetch_core.cache import cache
from lddc_fetch_core.decryptor import krc_decrypt
from lddc_fetch_core.exceptions import APIRequestError, LyricsNotFoundError
from lddc_fetch_core.models import Artist, LyricsBundle, Song, Source
from lddc_fetch_core.parsers.krc import krc2bundle
from lddc_fetch_core.parsers.utils import plaintext2data
from lddc_fetch_core.version import __version__


class KGProvider:
    source = Source.KG

    def __init__(self) -> None:
        self.client = httpx.Client()
        self.dfid: str | None = None
        self.init_lock = Lock()
        self.init()

    def init(self) -> None:
        with self.init_lock:
            if self.dfid is not None:
                return
            dfid = cache.get(("KG_dfid", __version__))
            if not dfid:
                mid = hashlib.md5(str(int(time.time() * 1000)).encode("utf-8")).hexdigest()
                params = {"appid": "1014", "platid": "4", "mid": mid}
                sorted_values = sorted([str(v) for v in params.values() if v != ""])
                params["signature"] = hashlib.md5(f"1014{''.join(sorted_values)}1014".encode()).hexdigest()
                data = b64encode(b'{"uuid":""}').decode()
                resp = httpx.post("https://userservice.kugou.com/risk/v1/r_register_dev", content=data, params=params, timeout=15)
                dfid = resp.json().get("data", {}).get("dfid") if resp.is_success else None
                if isinstance(dfid, str):
                    cache.set(("KG_dfid", __version__), dfid, expire_seconds=1800)
                else:
                    dfid = "-"
            self.dfid = str(dfid)

    def request(self, url: str, params: dict, module: str, method: str = "GET", data: str | None = None, headers: dict | None = None) -> dict:
        headers = {
            "User-Agent": f"Android14-1070-11070-201-0-{module}-wifi",
            "Connection": "Keep-Alive",
            "Accept-Encoding": "gzip, deflate",
            "KG-Rec": "1",
            "KG-RC": "1",
            "KG-CLIENTTIMEMS": str(int(time.time() * 1000)),
            **(headers or {}),
        }

        mid = hashlib.md5(str(int(time.time() * 1000)).encode("utf-8")).hexdigest()

        if module == "Lyric":
            params = {"appid": "3116", "clientver": "11070", **params}
        else:
            params = {
                "userid": "0",
                "appid": "3116",
                "token": "",
                "clienttime": int(time.time()),
                "iscorrection": "1",
                "uuid": "-",
                "mid": mid,
                # Upstream LDDC intentionally uses "-" here. Using a real dfid can trigger
                # risk control errors like 20028 on newer endpoints.
                "dfid": "-",
                "clientver": "11070",
                "platform": "AndroidFilter",
                **params,
            }
        headers["mid"] = mid
        params["signature"] = hashlib.md5(
            (
                "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
                + "".join([f"{k}={json.dumps(v) if isinstance(v, dict) else v}" for k, v in sorted(params.items())])
                + (data or "")
                + "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
            ).encode(),
        ).hexdigest()

        resp = self.client.get(url, params=params, headers=headers) if method == "GET" else self.client.post(url, params=params, headers=headers, content=data)
        resp.raise_for_status()
        payload = resp.json()
        if payload.get("error_code", 0) not in (0, 200):
            raise APIRequestError(f"kg API请求错误,错误码:{payload.get('error_code')} 错误信息:{payload.get('error_msg')}")
        return payload

    def search(self, keyword: str, page: int = 1) -> list[Song]:
        pagesize = 20
        params = {"sorttype": "0", "keyword": keyword, "pagesize": pagesize, "page": page}
        url = "http://complexsearch.kugou.com/v2/search/song"
        try:
            data = self.request(url, params, "SearchSong", headers={"x-router": "complexsearch.kugou.com"})
        except APIRequestError:
            # Complexsearch is flaky / rate-limited; fall back to legacy search (as in upstream LDDC).
            return self._old_search(keyword, page=page)
        items = data.get("data", {}).get("lists", []) or []
        out: list[Song] = []
        for info in items:
            out.append(
                Song(
                    source=self.source,
                    id=str(info.get("ID")) if info.get("ID") is not None else None,
                    title=info.get("SongName"),
                    artist=Artist(s["name"] for s in info.get("Singers", []) if s.get("name")),
                    album=info.get("AlbumName"),
                    duration_ms=(info.get("Duration") * 1000) if info.get("Duration") is not None else None,
                    extra={"hash": info.get("FileHash")},
                ),
            )
        return out

    def _old_search(self, keyword: str, page: int = 1) -> list[Song]:
        domain = random.choice(["mobiles.kugou.com", "msearchcdn.kugou.com", "mobilecdnbj.kugou.com", "msearch.kugou.com"])
        url = f"http://{domain}/api/v3/search/song"
        params = {
            "showtype": "14",
            "highlight": "",
            "pagesize": "30",
            "tag_aggr": "1",
            "plat": "0",
            "sver": "5",
            "keyword": keyword,
            "correct": "1",
            "api_ver": "1",
            "version": "9108",
            "page": page,
        }
        resp = self.client.get(url, params=params, timeout=3)
        resp.raise_for_status()
        data = resp.json()
        items = data.get("data", {}).get("info", []) or []
        out: list[Song] = []
        for info in items:
            out.append(
                Song(
                    source=self.source,
                    id=str(info.get("album_audio_id")) if info.get("album_audio_id") is not None else None,
                    title=info.get("songname"),
                    artist=Artist((info.get("singername") or "").split("、")) if info.get("singername") else None,
                    album=info.get("album_name"),
                    duration_ms=(info.get("duration") * 1000) if info.get("duration") is not None else None,
                    extra={"hash": info.get("hash")},
                ),
            )
        return out

    def _get_lyrics_candidate(self, song: Song) -> dict:
        if not song.id or not song.duration_ms or not song.extra.get("hash") or not song.title:
            raise LyricsNotFoundError("kg 缺少 hash/id/duration/title，无法搜索歌词")
        keyword = f"{(song.artist.str('、') if song.artist else '')} - {song.title}"
        params = {
            "album_audio_id": song.id,
            "duration": song.duration_ms,
            "hash": song.extra["hash"],
            "keyword": keyword,
            "lrctxt": "1",
            "man": "no",
        }
        url = "https://lyrics.kugou.com/v1/search"
        data = self.request(url, params, "Lyric")
        candidates = data.get("candidates", []) or []
        if not candidates:
            raise LyricsNotFoundError("kg 没有找到歌词候选")
        return candidates[0]

    def get_lyrics(self, song: Song) -> LyricsBundle:
        cand = self._get_lyrics_candidate(song)
        params = {
            "accesskey": cand["accesskey"],
            "charset": "utf8",
            "client": "mobi",
            "fmt": "krc",
            "id": cand["id"],
            "ver": "1",
        }
        url = "http://lyrics.kugou.com/download"
        data = self.request(url, params, "Lyric")
        bundle = LyricsBundle(song=song)

        if data.get("contenttype") == 2:
            bundle.orig = plaintext2data(b64decode(data["content"]).decode("utf-8"))
        else:
            tags, orig, ts, roma = krc2bundle(krc_decrypt(b64decode(data["content"])))
            bundle.tags.update(tags)
            bundle.orig = orig
            bundle.ts = ts
            bundle.roma = roma

        bundle.tags.setdefault("ti", song.title or "")
        bundle.tags.setdefault("ar", str(song.artist) if song.artist else "")
        bundle.tags.setdefault("al", song.album or "")
        return bundle
