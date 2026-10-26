"""MusicBrainz recording/release enrichment using only the bundled stdlib.

Apple catalog identifiers remain separate from MusicBrainz UUIDs. The selected
release is retained with the recording so later callers can reproduce a match.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import tempfile
import time
import unicodedata
import uuid
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen

_USER_AGENT = "myPlayer2/development (https://github.com/kmgcc/kmgccc_player)"
_VERSION = re.compile(r"\b(live|acoustic|remaster(?:ed)?|instrumental|karaoke|demo|radio edit|re[ -]?record(?:ed|ing)?)\b|国语|粤语|现场|伴奏|重录", re.I)


def _request_slot() -> None:
    # Helpers are short lived; a process-local timer cannot enforce MB's limit.
    path = Path(tempfile.gettempdir()) / f"kmgccc-player-musicbrainz-{os.getuid()}.rate"
    with path.open("a+") as state:
        fcntl.flock(state, fcntl.LOCK_EX)
        state.seek(0)
        try:
            previous = float(state.read() or "0")
        except ValueError:
            previous = 0
        delay = min(1.0, max(0.0, 1.0 - (time.monotonic() - previous)))
        if delay:
            time.sleep(delay)
        state.seek(0)
        state.truncate()
        state.write(str(time.monotonic()))
        state.flush()


def _get(path: str, **params: str) -> dict[str, Any]:
    url = "https://musicbrainz.org/ws/2/" + path + "?" + urlencode({"fmt": "json", **params})
    request = Request(url, headers={"User-Agent": _USER_AGENT, "Accept": "application/json"})
    # MusicBrainz sheds load with 503 even within its rate limit; a short
    # wait usually gets through.
    for attempt in range(3):
        _request_slot()
        try:
            with urlopen(request, timeout=15) as response:
                raw = response.read(8_000_001)
            break
        except HTTPError as error:
            if error.code not in (429, 503) or attempt == 2:
                raise
            try:
                wait = float(error.headers.get("Retry-After") or 0)
            except (TypeError, ValueError):
                wait = 0
            time.sleep(min(5.0, max(wait, 1.5 * (attempt + 1))))
    if len(raw) > 8_000_000:
        raise ValueError("response_exceeds_limit")
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise ValueError("invalid_response")
    return result


def _normalized(value: Any) -> str:
    value = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return " ".join(re.sub(r"[^\w]+", " ", value).split())


def _similarity(left: Any, right: Any) -> float:
    a, b = _normalized(left), _normalized(right)
    return SequenceMatcher(None, a, b).ratio() if a and b else 0.0


def _quoted(value: Any) -> str:
    return '"' + str(value or "").strip().replace("\\", "\\\\").replace('"', '\\"') + '"'


def _identifier(value: Any) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return None


def _artist(recording: dict[str, Any]) -> str:
    credits = recording.get("artist-credit") or []
    return "".join(str(c.get("name") or c.get("artist", {}).get("name") or "") + str(c.get("joinphrase") or "") for c in credits if isinstance(c, dict))


def _best_release(releases: list[dict], album: str) -> dict | None:
    if not releases:
        return None
    if not album.strip():
        return releases[0]
    # Match the existing automation provider: album similarity then oldest date.
    return min(releases, key=lambda release: (-_similarity(album, release.get("title")), release.get("date") or "9999"))


def _score(query: dict, recording: dict) -> float:
    release = _best_release(recording.get("releases") or [], str(query.get("album") or ""))
    candidate_title = recording.get("title") or ""
    requested_versions = {_normalized(m.group(0)).replace("remastered", "remaster") for m in _VERSION.finditer(str(query.get("title") or "") + " " + str(query.get("album") or ""))}
    candidate_versions = {_normalized(m.group(0)).replace("remastered", "remaster") for m in _VERSION.finditer(candidate_title + " " + str((release or {}).get("title") or ""))}
    if requested_versions != candidate_versions:
        return 0.0
    components = []
    for requested, actual, weight, minimum in ((query.get("title"), candidate_title, .5, .72),
                                                 (query.get("artist"), _artist(recording), .3, .55)):
        if requested:
            score = _similarity(requested, actual)
            if score < minimum:
                return 0.0
            components.append((score, weight))
    if query.get("album"):
        components.append((_similarity(query["album"], (release or {}).get("title")), .15))
    try:
        expected, actual = float(query.get("duration") or 0), float(recording.get("length") or 0) / 1000
    except (ValueError, TypeError):
        expected = actual = 0
    if expected > 0 and actual > 0:
        delta = abs(expected - actual)
        if delta > 12:
            return 0.0
        components.append((max(0.0, 1 - delta / 12), .05))
    return sum(score * weight for score, weight in components) / sum(weight for _, weight in components) if components else 0.0


def _credits(recording: dict) -> list[dict]:
    result = []
    relations = list(recording.get("relations") or [])
    for relation in list(relations):
        relations.extend((relation.get("work") or {}).get("relations") or [])
    for relation in relations:
        person = relation.get("artist")
        if not isinstance(person, dict) or not person.get("name"):
            continue
        item = {"role": relation.get("type") or "credit", "name": person["name"], "artistID": person.get("id"), "attributes": relation.get("attributes") or []}
        if item not in result:
            result.append(item)
    return result


def fetch(query: dict[str, Any]) -> dict[str, Any] | None:
    """Resolve a recording, then enrich only its selected release and credits."""
    recording_id = _identifier(query.get("musicBrainzRecordingID"))
    confidence = 1.0
    if not recording_id:
        if query.get("isrc"):
            terms = "isrc:" + _quoted(query["isrc"])
        elif query.get("title"):
            terms = " AND ".join(f"{field}:{_quoted(query[key])}" for key, field in (("title", "recording"), ("artist", "artist"), ("album", "release")) if query.get(key))
        else:
            return None
        candidates = _get("recording", query=terms, limit="10").get("recordings") or []
        ranked = sorted(((_score(query, candidate), candidate) for candidate in candidates), key=lambda pair: pair[0], reverse=True)
        if not ranked or ranked[0][0] < .78:
            return None
        confidence, candidate = ranked[0]
        recording_id = _identifier(candidate.get("id"))
        if not recording_id:
            return None
    recording = _get("recording/" + recording_id, inc="artists+releases+isrcs+genres+tags+artist-rels+work-rels+work-level-rels")
    releases = recording.get("releases") or []
    requested_release = _identifier(query.get("musicBrainzReleaseID"))
    selected = next((release for release in releases if release.get("id") == requested_release), None) if requested_release else _best_release(releases, str(query.get("album") or ""))
    release_id = _identifier((selected or {}).get("id"))
    release = _get("release/" + release_id, inc="artists+labels+release-groups+genres+tags+artist-rels") if release_id else None
    attributes: dict[str, Any] = {"name": recording.get("title"), "artistName": _artist(recording), "musicBrainzRecordingID": recording_id,
                                  "genreNames": sorted({tag["name"] for tag in (recording.get("genres") or []) + (recording.get("tags") or []) if tag.get("name")})[:12],
                                  "credits": _credits(recording)}
    if recording.get("length"):
        attributes["durationInMillis"] = recording["length"]
    isrcs = recording.get("isrcs") or []
    if isrcs:
        attributes["isrc"] = query["isrc"] if query.get("isrc") in isrcs else isrcs[0]
        attributes["isrcs"] = isrcs
    if release:
        attributes.update({"musicBrainzReleaseID": release_id, "albumName": release.get("title"), "releaseDate": release.get("date") or recording.get("first-release-date")})
        if release.get("barcode"):
            attributes["upc"] = release["barcode"]
        labels = [item["label"]["name"] for item in release.get("label-info") or [] if isinstance(item.get("label"), dict) and item["label"].get("name")]
        if labels:
            attributes["recordLabel"] = ", ".join(dict.fromkeys(labels))
    elif recording.get("first-release-date"):
        attributes["releaseDate"] = recording["first-release-date"]
    return {"source": "musicBrainz", "confidence": confidence, "attributes": attributes,
            "resources": {**{"recording": recording}, **({"release": release} if release else {})}}
