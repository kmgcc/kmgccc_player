import base64
import importlib.util
import json
import os
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

MODULE_PATH = Path(__file__).resolve().parents[1] / "music_enrichment_web.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("music_enrichment_web", MODULE_PATH)
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


def box(kind, data):
    return struct.pack(">I4s", len(data) + 8, kind) + data


def timed_mp4():
    # A 20-second fragment starts at media time 10, the real Apple sample issue.
    tkhd = box(b"tkhd", b"\0" * 12 + struct.pack(">I", 1))
    mdhd = box(b"mdhd", b"\0" * 12 + struct.pack(">I", 24))
    moov = box(b"moov", box(b"trak", tkhd + box(b"mdia", mdhd)))
    tfhd = box(b"tfhd", b"\0\0\0\x08" + struct.pack(">II", 1, 24))
    tfdt = box(b"tfdt", b"\x01\0\0\0" + struct.pack(">Q", 240))
    trun = box(b"trun", b"\0" * 4 + struct.pack(">I", 20))
    return moov + box(b"moof", box(b"traf", tfhd + tfdt + trun))


class RecordingMatchTests(unittest.TestCase):
    def test_cover_only_fetch_skips_related_resources_and_lyrics(self):
        song = {"id": "123", "attributes": {"name": "Song", "artwork": {"url": "https://example.test/{w}x{h}.jpg"}}}
        with patch.object(web, "_song", return_value=(song, 0.98)), \
             patch.object(web, "_catalog", side_effect=AssertionError("unnecessary related request")), \
             patch.object(web, "_lyrics", side_effect=AssertionError("unnecessary lyric request")):
            result = web._fetch({"title": "Song"}, "us", "test", artwork_only=True)
        self.assertEqual(result["attributes"]["artwork"], song["attributes"]["artwork"])
        self.assertEqual(result["confidence"], 0.98)

    def setUp(self):
        self.query = {"title": "Song", "artist": "Artist", "album": "Album", "duration": 200}
        self.song = {"id": "123", "attributes": {"name": "Song", "artistName": "Artist", "albumName": "Album", "durationInMillis": 200000}}

    def test_same_title_does_not_accept_live_version(self):
        self.song["attributes"]["name"] = "Song (Live)"
        self.assertEqual(web._score(self.query, self.song), 0)

    def test_same_title_artist_does_not_override_duration_conflict(self):
        self.song["attributes"]["durationInMillis"] = 220000
        self.assertEqual(web._score(self.query, self.song), 0)

    def test_similar_artist_is_not_automatic_identity(self):
        self.song["attributes"]["artistName"] = "Elara Mae"
        self.query.update(title="Youth", artist="Crispy")
        self.song["attributes"]["name"] = "Youth"
        self.assertEqual(web._score(self.query, self.song), 0)

    def test_ambiguous_recording_is_not_chosen_by_arrival_order(self):
        duplicate = {**self.song, "id": "456"}
        with patch.object(web, "_catalog", return_value={"results": {"songs": {"data": [self.song, duplicate]}}}):
            self.assertEqual(web._song(self.query, "us", "in-memory-only"), (None, 0.0))

    def test_matching_recording_scores_one(self):
        self.assertEqual(web._score(self.query, self.song), 1)

    def test_every_search_candidate_is_scored(self):
        wrong = {"id": "999", "attributes": {**self.song["attributes"], "name": "Song (Live)"}}
        responses = [{"results": {"songs": {"data": [wrong, self.song]}}}, {"data": [self.song]}]
        with patch.object(web, "_catalog", side_effect=responses):
            song, confidence = web._song(self.query, "us", "in-memory-only")
        self.assertEqual(song["id"], "123")
        self.assertEqual(confidence, 1)


class CatalogMergeTests(unittest.TestCase):
    def test_song_identity_survives_album_and_artist_enrichment(self):
        song = {"id": "123", "attributes": {"name": "Song", "artistName": "Artist", "audioTraits": ["lossless"]},
                "relationships": {"albums": {"data": [{"id": "456"}]}, "artists": {"data": [{"id": "789"}]}}}
        album = {"id": "456", "attributes": {"name": "Album", "recordLabel": "Label", "editorialVideo": {
            "motionDetailSquare": {"video": "https://mvod.itunes.apple.com/square.m3u8"}}}}
        artist = {"id": "789", "attributes": {"name": "Artist", "artistBio": "Biography", "isGroup": True}}
        # Album and artist lookups run concurrently, so answer by path, not call order.
        responses = {"us/songs/123": song, "us/albums/456": album, "us/artists/789": artist}
        with patch.object(web, "_client_token", return_value="do-not-persist-this-token"), \
             patch.object(web, "_catalog", side_effect=lambda path, *_args, **_kwargs: {"data": [responses[path]]}), \
             patch.object(web, "_lyrics", return_value=None):
            result = web.fetch({"appleSongID": "123", "title": "Song"})
        self.assertEqual(result["attributes"]["name"], "Song")
        self.assertEqual(result["attributes"]["recordLabel"], "Label")
        self.assertEqual(result["attributes"]["artistBiography"], "Biography")
        self.assertEqual(result["attributes"]["audioVariants"], ["lossless"])
        self.assertEqual(result["resources"]["album"], album)
        self.assertEqual(result["motion"][0]["kind"], "square")
        self.assertNotIn("do-not-persist-this-token", json.dumps(result))

    def test_missing_title_and_id_skip_network(self):
        with patch.object(web, "_client_token") as token:
            self.assertEqual(web.fetch({}), {})
            token.assert_not_called()

    def test_amll_missing_id_is_a_normal_lyrics_miss(self):
        self.assertIsNone(web._lyrics({}, "not-a-catalog-id"))

    def test_amll_has_its_own_source_and_needs_no_apple_bearer(self):
        ttml = b'<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>'
        with patch.object(web, "_bytes", return_value=ttml), patch.object(web, "_client_token") as token:
            result = web.fetch_amll({"appleSongID": "123"})
        self.assertEqual(result["source"], "amllDB")
        self.assertEqual(result["songID"], "123")
        self.assertEqual(result["lyricsTTML"], ttml.decode())
        token.assert_not_called()

    def test_amll_html_and_entity_documents_are_normal_misses(self):
        for document in (b'<html><body>404</body></html>', b'<!DOCTYPE tt [<!ENTITY x "value">]><tt/>'):
            with patch.object(web, "_bytes", return_value=document):
                self.assertIsNone(web.fetch_amll({"appleSongID": "123"}))

    def test_web_does_not_attribute_amll_lyrics_to_apple(self):
        with patch.object(web, "_bytes") as get:
            self.assertIsNone(web._lyrics({}, "123"))
        get.assert_not_called()


class MotionSearchTests(unittest.TestCase):
    def album(self, identifier="456", motion=True):
        return {"id": identifier, "attributes": {"name": "Album " + identifier, "artistName": "Artist", "releaseDate": "2020-01-01", "artwork": {"url": "https://is1-ssl.mzstatic.com/test.jpg"},
                **({"editorialVideo": {"motionSquareVideo1x1": {"video": "https://mvod.itunes.apple.com/square.m3u8"}, "motionTallVideo3x4": {"video": "https://mvod.itunes.apple.com/tall.m3u8"}}} if motion else {})}}

    def test_candidates_keep_album_identity_both_motion_variants_and_display_fields(self):
        song = {"id": "123", "attributes": {"name": "A different version"}, "relationships": {"albums": {"data": [{"id": "456"}]}}}
        album = self.album()
        search = {"results": {"songs": {"data": [song]}, "albums": {"data": [album]}}}
        with patch.object(web, "_client_token", return_value="private-in-memory"), patch.object(web, "_catalog", side_effect=[search, {"data": [album]}]) as get:
            result = web.search_motion({"title": "Some user's search", "storefront": "tr"})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["albumID"], "456")
        self.assertEqual(result[0]["songID"], "123")
        self.assertEqual(result[0]["storefront"], "tr")
        self.assertEqual(result[0]["attributes"]["albumName"], "Album 456")
        self.assertEqual({motion["kind"] for motion in result[0]["motion"]}, {"square", "tall"})
        self.assertEqual(get.call_count, 2)
        self.assertNotIn("private-in-memory", json.dumps(result))

    def test_no_motion_albums_are_omitted(self):
        album = self.album(motion=False)
        with patch.object(web, "_client_token", return_value="token"), patch.object(web, "_catalog", side_effect=[{"results": {"albums": {"data": [album]}}}, {"data": [album]}]):
            self.assertEqual(web.search_motion({"artist": "Artist"}), [])

    def test_at_most_six_distinct_albums_are_requested_in_one_call(self):
        albums = [self.album(str(identifier)) for identifier in range(100, 110)]
        search = {"results": {"albums": {"data": albums}}}
        with patch.object(web, "_client_token", return_value="token"), patch.object(web, "_catalog", side_effect=[search, {"data": albums[:6]}]) as get:
            result = web.search_motion({"album": "Album"})
        self.assertEqual(len(result), 6)
        self.assertEqual(get.call_count, 2)
        self.assertEqual(get.call_args.args[2]["ids"], ",".join(str(identifier) for identifier in range(100, 106)))

    def test_song_only_search_can_resolve_missing_relationship(self):
        song = {"id": "123"}
        full_song = {**song, "relationships": {"albums": {"data": [{"id": "456"}]}}}
        with patch.object(web, "_client_token", return_value="token"), patch.object(web, "_catalog", side_effect=[{"results": {"songs": {"data": [song]}}}, {"data": [full_song]}, {"data": [self.album()]}]):
            result = web.search_motion({"title": "Song"})
        self.assertEqual(result[0]["songID"], "123")

    def test_empty_manual_search_skips_network(self):
        with patch.object(web, "_client_token") as token:
            self.assertEqual(web.search_motion({}), [])
        token.assert_not_called()


class TokenCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        patcher = patch.object(web, "TOKEN_CACHE_DIRECTORY", self.directory.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def token(expires: float) -> str:
        payload = base64.urlsafe_b64encode(json.dumps({"exp": expires}).encode()).decode().rstrip("=")
        return f"eyJhbGciOiJFUzI1NiJ9.{payload}.c2lnbmF0dXJl"

    def test_second_invocation_reuses_the_cached_token(self):
        token = self.token(time.time() + 86400)
        with patch.object(web, "_client_token", return_value=token) as discover:
            self.assertEqual(web._with_token("us", lambda value: value), token)
            self.assertEqual(web._with_token("us", lambda value: value), token)
        self.assertEqual(discover.call_count, 1)
        mode = os.stat(os.path.join(self.directory.name, "apple-web-token.json")).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_refused_cached_token_is_rediscovered_once(self):
        stale, fresh = self.token(time.time() + 86400), self.token(time.time() + 2 * 86400)
        web._store_token(stale)
        def operation(value):
            if value == stale:
                raise HTTPError("https://amp-api.music.apple.com", 401, "Unauthorized", {}, None)
            return value
        with patch.object(web, "_client_token", return_value=fresh) as discover:
            self.assertEqual(web._with_token("us", operation), fresh)
        self.assertEqual(discover.call_count, 1)

    def test_expiring_token_is_not_reused(self):
        web._store_token(self.token(time.time() + 60))
        self.assertIsNone(web._cached_token())


class MotionPersistenceTests(unittest.TestCase):
    def test_timing_preserves_nonzero_start_without_artificial_dead_time(self):
        self.assertEqual(web._mp4_timing(timed_mp4()), (10, 20))

    def test_truncated_mp4_is_rejected(self):
        with self.assertRaises(ValueError):
            web._mp4_timing(timed_mp4()[:-5])

    def test_entire_shared_mp4_is_saved_once_and_time_range_returned(self):
        playlist = b'''#EXTM3U
#EXT-X-MAP:URI="video.mp4",BYTERANGE="20@0"
#EXTINF:20,
#EXT-X-BYTERANGE:100@20
video.mp4
#EXT-X-ENDLIST
'''
        media = timed_mp4()
        with tempfile.TemporaryDirectory() as temporary, patch.object(web, "_bytes", side_effect=[playlist, media]) as get:
            path = Path(temporary) / "motion.mp4"
            result = web.materialize_motion("https://mvod.itunes.apple.com/sample.m3u8", str(path))
            self.assertEqual(path.read_bytes(), media)
            self.assertEqual(result, {"path": str(path), "startTime": 10, "duration": 20})
            self.assertEqual(get.call_count, 2)

    def test_encrypted_assets_are_not_written(self):
        playlist = b'#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset"\n#EXT-X-ENDLIST\n'
        with tempfile.TemporaryDirectory() as temporary, patch.object(web, "_bytes", return_value=playlist):
            path = Path(temporary) / "motion.mp4"
            with self.assertRaises(ValueError):
                web.materialize_motion("https://mvod.itunes.apple.com/sample.m3u8", str(path))
            self.assertFalse(path.exists())

    def test_non_apple_assets_are_rejected_before_network(self):
        with patch.object(web, "_bytes") as get, self.assertRaises(ValueError):
            web.materialize_motion("https://example.com/video.m3u8", "/unused")
        get.assert_not_called()


if __name__ == "__main__":
    unittest.main()
