# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

# ruff: noqa: S311

from __future__ import annotations

import json
import random
import time
from base64 import b64encode
from threading import Lock

import httpx

from lddc_fetch_core.exceptions import APIParamsError, APIRequestError
from lddc_fetch_core.decryptor import qrc_decrypt
from lddc_fetch_core.models import Artist, LyricsBundle, Song, Source
from lddc_fetch_core.parsers.qrc import qrc_str_parse
from lddc_fetch_core.version import __version__


class QMProvider:
    source = Source.QM

    def __init__(self) -> None:
        self.client = httpx.Client(
            headers={
                "cookie": "tmeLoginType=-1;",
                "content-type": "application/json",
                "accept-encoding": "gzip",
                "user-agent": "okhttp/3.14.9",
            },
            http2=True,
        )
        self.comm = {
            "ct": 11,
            "cv": "1003006",
            "v": "1003006",
            "os_ver": "15",
            "phonetype": "24122RKC7C",
            "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
            "tmeAppID": "qqmusiclight",
            "nettype": "NETWORK_WIFI",
            "udid": "0",
        }
        self.inited = False
        self.init_lock = Lock()
        self.init()

    def init(self) -> None:
        with self.init_lock:
            if self.inited:
                return
            data = self.request("GetSession", "music.getSession.session", {"caller": 0, "uid": "0", "vkey": 0})
            self.comm = {
                **self.comm,
                "uid": data["session"]["uid"],
                "sid": data["session"]["sid"],
                "userip": data["session"]["userip"],
            }
            self.inited = True

    def request(self, method: str, module: str, param: dict) -> dict:
        if not self.inited and method != "GetSession":
            self.init()
        payload = json.dumps(
            {"comm": self.comm, "request": {"method": method, "module": module, "param": param}},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        response = self.client.post("https://u.y.qq.com/cgi-bin/musicu.fcg", content=payload)
        response.raise_for_status()
        response_data = response.json()
        if response_data.get("code") != 0 or response_data.get("request", {}).get("code") != 0:
            raise APIRequestError(f"qm API请求错误,错误码:{response_data.get('code')}")
        return response_data["request"]["data"]

    def search(self, keyword: str, page: int = 1) -> list[Song]:
        pagesize = 20
        param = {
            "search_id": str(random.randint(1, 20) * 18014398509481984 + random.randint(0, 4194304) * 4294967296 + round(time.time() * 1000) % 86400000),
            "remoteplace": "search.android.keyboard",
            "query": keyword,
            "search_type": 0,
            "num_per_page": pagesize,
            "page_num": page,
            "highlight": 0,
            "nqc_flag": 0,
            "page_id": 1,
            "grp": 1,
        }
        data = self.request("DoSearchForQQMusicLite", "music.search.SearchCgiService", param)
        songs = data.get("body", {}).get("item_song", []) or []
        out: list[Song] = []
        for info in songs:
            out.append(
                Song(
                    source=self.source,
                    id=str(info.get("id")) if info.get("id") is not None else None,
                    title=info.get("title"),
                    artist=Artist(s["name"] for s in info.get("singer", []) if s.get("name")),
                    album=(info.get("album") or {}).get("name"),
                    duration_ms=(info.get("interval") * 1000) if info.get("interval") is not None else None,
                ),
            )
        return out

    def get_lyrics(self, song: Song) -> LyricsBundle:
        if song.title is None or song.album is None or not song.id or song.duration_ms is None:
            raise APIParamsError("qm 缺少必要参数(需要 id/title/album/duration)")

        param = {
            "albumName": b64encode(song.album.encode()).decode(),
            "crypt": 1,
            "ct": 19,
            "cv": 2111,
            "interval": song.duration_ms // 1000,
            "lrc_t": 0,
            "qrc": 1,
            "qrc_t": 0,
            "roma": 1,
            "roma_t": 0,
            "singerName": b64encode(str(song.artist).encode()).decode() if song.artist else b64encode(b"").decode(),
            "songID": int(song.id),
            "songName": b64encode(song.title.encode()).decode(),
            "trans": 1,
            "trans_t": 0,
            "type": 0,
        }

        resp = self.request("GetPlayLyricInfo", "music.musichallSong.PlayLyricInfo", param)
        bundle = LyricsBundle(song=song)

        for key, field in (("orig", "lyric"), ("ts", "trans"), ("roma", "roma")):
            encrypted = resp.get(field) or ""
            ts_flag = (resp.get("qrc_t") if resp.get("qrc_t") != 0 else resp.get("lrc_t")) if field == "lyric" else resp.get(field + "_t")
            if encrypted and ts_flag != "0":
                decrypted = qrc_decrypt(encrypted, local_qrc=False)
                tags, data = qrc_str_parse(decrypted)
                if key == "orig":
                    bundle.tags.update(tags)
                    bundle.tags.setdefault("ti", song.title or "")
                    bundle.tags.setdefault("ar", str(song.artist) if song.artist else "")
                    bundle.tags.setdefault("al", song.album or "")
                    bundle.orig = data
                elif key == "ts":
                    bundle.ts = data
                elif key == "roma":
                    bundle.roma = data

        if not bundle.tags:
            bundle.tags = {
                "ti": song.title or "",
                "ar": str(song.artist) if song.artist else "",
                "al": song.album or "",
                "tool": f"lddc-fetch-core/{__version__}",
            }
        return bundle

