# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

# ruff: noqa: S311

from __future__ import annotations

import json
import random
import secrets
import string
import time
from threading import Lock

import httpx

from lddc_fetch_core.cache import cache
from lddc_fetch_core.decryptor.eapi import eapi_params_encrypt, eapi_response_decrypt, get_anonimous_username
from lddc_fetch_core.exceptions import APIRequestError
from lddc_fetch_core.models import Artist, LyricsBundle, Song, Source
from lddc_fetch_core.parsers.lrc import lrc2data
from lddc_fetch_core.parsers.utils import plaintext2data
from lddc_fetch_core.parsers.yrc import yrc2data
from lddc_fetch_core.version import __version__

from .ne_deviceids import get_device_id


class NEProvider:
    source = Source.NE

    def __init__(self) -> None:
        self.inited = False
        self.init_lock = Lock()
        self.session = httpx.Client(http2=True, timeout=15)
        self.cookies: dict[str, str] = {}
        self.user_id: int | None = None
        self.expire: int = 0
        self.init()

    def init(self) -> None:
        with self.init_lock:
            cached = cache.get(("NE_anon", __version__))
            if isinstance(cached, dict) and time.time() < cached.get("expire", 0):
                self.cookies = dict(cached.get("cookies", {}))
                self.user_id = cached.get("user_id")
                self.expire = int(cached.get("expire", 0))
                self.inited = True
                return

            mac = ":".join([f"{secrets.randbelow(255):02X}" for _ in range(6)])
            random_str = "".join(secrets.choice(string.ascii_uppercase) for _ in range(8))
            hash_part = secrets.token_hex(32)
            client_sign = f"{mac}@@@{random_str}@@@@@@{hash_part}"

            pre_cookies = {
                "os": "pc",
                "deviceId": get_device_id(),
                "osver": f"Microsoft-Windows-10--build-{random.randint(200, 300)}00-64bit",
                "clientSign": client_sign,
                "channel": "netease",
                "mode": random.choice(["MS-iCraft B760M WIFI", "ASUS ROG STRIX Z790", "MSI MAG B550 TOMAHAWK", "ASRock X670E Taichi"]),
                "appver": "3.1.3.203419",
            }

            path = "/eapi/register/anonimous"
            params = {"username": get_anonimous_username(pre_cookies["deviceId"]), "e_r": True, "header": self._get_params_header(pre_cookies)}
            encrypted_params = eapi_params_encrypt(path.replace("eapi", "api").encode(), params)

            resp = httpx.Client(http2=True).post(
                "https://interface.music.163.com" + path,
                headers=self._get_header(pre_cookies),
                content=encrypted_params,
                timeout=15,
            )
            resp.raise_for_status()
            data = json.loads(eapi_response_decrypt(resp.content))
            if data.get("code") not in (200, 201, 204):
                msg = data.get("message") or data.get("msg") or data.get("errmsg") or ""
                raise APIRequestError(f"ne 游客登录失败: {data.get('code')} {msg or data}")

            response_cookies = resp.cookies
            self.cookies = {
                "WEVNSM": "1.0.0",
                "os": pre_cookies["os"],
                "deviceId": pre_cookies["deviceId"],
                "osver": pre_cookies["osver"],
                "clientSign": pre_cookies["clientSign"],
                "channel": "netease",
                "mode": pre_cookies["mode"],
                "NMTID": response_cookies.get("NMTID", ""),
                "MUSIC_A": response_cookies.get("MUSIC_A", ""),
                "__csrf": response_cookies.get("__csrf", ""),
                "appver": pre_cookies["appver"],
                # Seen in upstream LDDC; some endpoints appear to require it.
                "WNMCID": f"{''.join(random.choice(string.ascii_lowercase) for _ in range(6))}."
                f"{int(time.time() * 1000) - random.randint(1000, 10000)}.01.0",
            }
            for k in [k for k, v in self.cookies.items() if not v]:
                self.cookies.pop(k, None)
            self.user_id = int(data.get("userId", 0) or 0)
            self.expire = int(time.time()) + 864000
            cache.set(("NE_anon", __version__), {"user_id": self.user_id, "cookies": self.cookies, "expire": self.expire}, expire_seconds=864000)
            self.inited = True

    def _get_params_header(self, cookies: dict[str, str]) -> str:
        return json.dumps(
            {
                "clientSign": cookies["clientSign"],
                "os": cookies["os"],
                "appver": cookies["appver"],
                "deviceId": cookies["deviceId"],
                "requestId": 0,
                "osver": cookies["osver"],
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )

    def _get_header(self, cookies: dict[str, str]) -> list[tuple[str, str]]:
        return [
            ("accept", "*/*"),
            ("content-type", "application/x-www-form-urlencoded"),
            *[("cookie", f"{k}={v}") for k, v in cookies.items()],
            ("mconfig-info", '{"IuRPVVmc3WWul9fT":{"version":733184,"appver":"3.1.3.203419"}}'),
            ("origin", "orpheus://orpheus"),
            (
                "user-agent",
                "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) "
                "Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.3.203419",
            ),
            # Extra headers used by upstream LDDC (helps when NE tightens checks).
            ("sec-ch-ua", '"Chromium";v="91"'),
            ("sec-ch-ua-mobile", "?0"),
            ("sec-fetch-site", "cross-site"),
            ("sec-fetch-mode", "cors"),
            ("sec-fetch-dest", "empty"),
            ("accept-encoding", "gzip, deflate, br"),
            ("accept-language", "en-US,en;q=0.9"),
        ]

    def request(self, url_path: str, params: dict) -> dict:
        if not self.inited or self.expire < int(time.time()):
            self.init()
        path = url_path
        if "header" not in params:
            params = {**params, "e_r": True, "header": self._get_params_header(self.cookies)}
        encrypted_params = eapi_params_encrypt(path.replace("eapi", "api").encode(), params)
        resp = self.session.post(
            "https://interface.music.163.com" + path,
            headers=self._get_header(self.cookies),
            content=encrypted_params,
        )
        resp.raise_for_status()
        data = json.loads(eapi_response_decrypt(resp.content))
        if data.get("code") != 200:
            raise APIRequestError(f"ne API请求错误,错误码:{data.get('code')} 错误信息:{data.get('message')}")
        return data

    def search(self, keyword: str, page: int = 1) -> list[Song]:
        pagesize = 20
        params = {"limit": str(pagesize), "offset": str((page - 1) * pagesize), "keyword": keyword, "scene": "NORMAL", "needCorrect": "true"}
        data = self.request("/eapi/search/song/list/page", params)
        # Endpoint returns different shapes over time. Most commonly (as in upstream LDDC),
        # `data.data.resources[]` items are wrapper objects containing:
        #   { "baseInfo": { "simpleSongData": { ... song fields ... } } }
        # Fall back to older shapes when present.
        resources = data.get("data", {}).get("resources")
        songs: list[dict] = []
        if isinstance(resources, list):
            for item in resources:
                if isinstance(item, dict):
                    simple = (item.get("baseInfo") or {}).get("simpleSongData")
                    if isinstance(simple, dict):
                        songs.append(simple)
                    else:
                        songs.append(item)
        else:
            legacy = data.get("result", {}).get("songs") or data.get("data", {}).get("songs") or []
            if isinstance(legacy, dict) and "songs" in legacy:
                legacy = legacy["songs"]
            if isinstance(legacy, list):
                songs = [x for x in legacy if isinstance(x, dict)]
        out: list[Song] = []
        for info in songs:
            try:
                song_id = info.get("id") or info.get("songId") or info.get("resourceId")
                # Some responses might nest the real payload under `song`.
                if song_id is None and isinstance(info.get("song"), dict):
                    info = info["song"]
                    song_id = info.get("id") or info.get("songId") or info.get("resourceId")

                artists = info.get("ar") or info.get("artists") or []
                album = info.get("al") or info.get("album") or {}
                out.append(
                    Song(
                        source=self.source,
                        id=str(song_id) if song_id is not None else None,
                        title=info.get("name") or info.get("title"),
                        artist=Artist(s.get("name") for s in artists if isinstance(s, dict) and s.get("name")) if artists else None,
                        album=album.get("name") if isinstance(album, dict) else str(album) if album else None,
                        duration_ms=info.get("dt") or info.get("duration") or info.get("duration_ms"),
                    ),
                )
            except Exception:
                continue
        return out

    def get_lyrics(self, song: Song) -> LyricsBundle:
        if not song.id:
            raise ValueError("ne 歌曲 id 为空")
        params = {"id": int(song.id), "lv": "-1", "tv": "-1", "rv": "-1", "yv": "-1"}
        data = self.request("/eapi/song/lyric/v1", params)

        bundle = LyricsBundle(song=song)
        bundle.tags = {
            "ti": song.title or "",
            "ar": str(song.artist) if song.artist else "",
            "al": song.album or "",
        }

        if "yrc" in data and isinstance(data["yrc"], dict) and data["yrc"].get("lyric"):
            bundle.orig = yrc2data(data["yrc"]["lyric"])
            if isinstance(data.get("tlyric", {}).get("lyric"), str) and data["tlyric"]["lyric"]:
                bundle.ts = lrc2data(data["tlyric"]["lyric"], source=Source.NE)[1]
            if isinstance(data.get("romalrc", {}).get("lyric"), str) and data["romalrc"]["lyric"]:
                bundle.roma = lrc2data(data["romalrc"]["lyric"], source=Source.NE)[1]
        else:
            if isinstance(data.get("lrc", {}).get("lyric"), str) and data["lrc"]["lyric"]:
                bundle.orig = lrc2data(data["lrc"]["lyric"], source=Source.NE)[1]
            if isinstance(data.get("tlyric", {}).get("lyric"), str) and data["tlyric"]["lyric"]:
                bundle.ts = lrc2data(data["tlyric"]["lyric"], source=Source.NE)[1]
            if isinstance(data.get("romalrc", {}).get("lyric"), str) and data["romalrc"]["lyric"]:
                bundle.roma = lrc2data(data["romalrc"]["lyric"], source=Source.NE)[1]

        if bundle.orig is None:
            bundle.orig = plaintext2data("")
        return bundle
