"""Synthetic CFURL cache fixtures; never access the user's Music cache."""

from __future__ import annotations

import gzip
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1] / "music_enrichment_cache.py"
SPEC = importlib.util.spec_from_file_location("music_enrichment_cache", MODULE)
cache = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(cache)


TTML = '<tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en"><body><div><p begin="0s" end="2s"><span begin="0s" end="1s">One</span><span begin="1s" end="2s">two</span></p></div></body></tt>'


def song(song_id="100", *, title="Example Song", album="Example Album", duration=180000):
    return {
        "id": song_id, "type": "songs",
        "attributes": {"name": title, "artistName": "Example Artist", "albumName": album, "durationInMillis": duration, "isrc": "XXEXA2600001", "genreNames": ["Example"], "artwork": {"url": "https://is1-ssl.mzstatic.com/example/{w}x{h}.jpg"}},
        "relationships": {"albums": {"data": [{"id": "200", "type": "albums"}]}},
    }


def album():
    return {
        "id": "200", "type": "albums",
        "attributes": {"name": "Example Album", "artistName": "Example Artist", "recordLabel": "Example Label", "copyright": "Example copyright", "upc": "000000000000", "editorialVideo": {"motionSquareVideo1x1": {"video": "https://mvod.itunes.apple.com/example/square.m3u8", "width": 1080, "height": 1080}, "motionTallVideo3x4": {"video": "https://mvod.itunes.apple.com/example/tall.m3u8", "width": 900, "height": 1200}}},
    }


class CacheFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "fsCachedData").mkdir()
        self.db = sqlite3.connect(self.root / "Cache.db")
        self.db.executescript(
            "CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp TEXT);"
            "CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);"
            "CREATE TABLE cfurl_cache_blob_data(entry_ID INTEGER PRIMARY KEY, request_object BLOB, response_object BLOB);"
        )
        self.counter = 0

    def tearDown(self):
        self.db.close()
        self.directory.cleanup()

    def add(self, payload, *, fs=False, sf="us", stamp="2026-01-01 00:00:00", raw=None, reference=None):
        self.counter += 1
        eid = self.counter
        data = raw if raw is not None else json.dumps(payload).encode()
        if fs:
            filename = reference or f"fixture-{eid}.json"
            if reference is None:
                (self.root / "fsCachedData" / filename).write_bytes(data)
            data = filename
        self.db.execute("INSERT INTO cfurl_cache_response VALUES(?,?,?)", (eid, f"https://amp-api.music.apple.com/v1/catalog/{sf}/songs/100?include=syllable-lyrics", stamp))
        self.db.execute("INSERT INTO cfurl_cache_receiver_data VALUES(?,?,?)", (eid, int(fs), data))
        self.db.execute("INSERT INTO cfurl_cache_blob_data VALUES(?,?,?)", (eid, b"SENSITIVE_REQUEST_SENTINEL", b"SENSITIVE_RESPONSE_SENTINEL"))
        self.db.commit()

    def test_exact_song_id_returns_public_metadata_ttml_and_album_motion(self):
        track = song()
        track["relationships"]["syllable-lyrics"] = {"data": [{"type": "syllable-lyrics", "id": "100", "attributes": {"ttmlLocalizations": {"en-US": TTML}}}]}
        self.add({"data": [track, album()]})
        result = cache.fetch({"appleSongID": "100", "storefront": "us"}, self.root)
        self.assertEqual(result["source"], "appleCache")
        self.assertEqual(result["confidence"], 1.0)
        self.assertEqual(result["songID"], "100")
        self.assertEqual(result["albumID"], "200")
        self.assertEqual(result["attributes"]["recordLabel"], "Example Label")
        self.assertEqual(result["lyricsTTML"], TTML)
        self.assertEqual({x["kind"] for x in result["motion"]}, {"square", "tall"})
        self.assertNotIn("SENSITIVE_", json.dumps(result))

    def test_fs_normalized_resources_text_match_requires_recording_evidence(self):
        self.add({"data": [{"id": "100", "type": "songs"}], "resources": {"songs": {"100": song()}, "albums": {"200": album()}}}, fs=True)
        result = cache.fetch({"title": "Example Song", "artist": "Example Artist", "album": "Example Album", "duration": 180}, self.root)
        self.assertEqual(result["songID"], "100")
        self.assertEqual(result["matchKind"], "metadata")
        self.assertIsNone(cache.fetch({"title": "Example Song (Live)", "artist": "Example Artist", "album": "Example Album", "duration": 180}, self.root))
        self.assertIsNone(cache.fetch({"title": "Example Song", "artist": "Example Artist", "album": "Different Album", "duration": 180}, self.root))
        self.assertIsNone(cache.fetch({"title": "Example Song", "artist": "Example Artist", "duration": 240}, self.root))

    def test_explicit_missing_catalog_id_never_falls_back_to_title(self):
        self.add({"data": [song()]})
        self.assertIsNone(cache.fetch({"appleSongID": "999", "title": "Example Song", "artist": "Example Artist", "duration": 180}, self.root))

    def test_no_query_never_returns_first_cached_song(self):
        self.add({"data": [song()]})
        self.assertIsNone(cache.fetch({}, self.root))
        self.assertIsNone(cache.fetch({"title": "Example Song"}, self.root))

    def test_storefront_is_an_identity_boundary(self):
        self.add({"data": [song()]}, sf="tr")
        self.assertIsNone(cache.fetch({"appleSongID": "100", "storefront": "us"}, self.root))
        self.assertEqual(cache.fetch({"appleSongID": "100", "storefront": "tr"}, self.root)["storefront"], "tr")

    def test_unrelated_and_account_routes_are_not_read(self):
        self.add({"data": [song()]})
        self.db.execute("UPDATE cfurl_cache_response SET request_key='https://amp-api.music.apple.com/v1/me/library/songs'")
        self.db.commit()
        result = cache.read_catalog_resources(self.root)
        self.assertEqual(result["responsesExamined"], 0)
        self.assertEqual(result["status"], "empty")

    def test_path_traversal_reference_is_rejected(self):
        self.add({}, fs=True, reference="../outside.json")
        result = cache.read_catalog_resources(self.root)
        self.assertEqual(result["status"], "empty")
        self.assertEqual(result["failures"], {"ValueError": 1})

    def test_sensitive_keys_and_urls_are_not_returned(self):
        track = song()
        track["attributes"]["authorization"] = "SENSITIVE_AUTH_SENTINEL"
        track["attributes"]["artwork"]["token"] = "SENSITIVE_TOKEN_SENTINEL"
        track["attributes"]["artwork"]["url"] = "https://is1-ssl.mzstatic.com/image?userToken=SENSITIVE_QUERY_SENTINEL"
        track["relationships"]["albums"]["authorization"] = "SENSITIVE_RELATIONSHIP_SENTINEL"
        self.add({"data": [track]})
        result = cache.fetch({"appleSongID": "100"}, self.root)
        self.assertNotIn("SENSITIVE_", json.dumps(result))

    def test_gzip_body_and_decompression_limit(self):
        self.add(None, raw=gzip.compress(json.dumps({"data": [song()]}).encode()))
        self.assertIsNotNone(cache.fetch({"appleSongID": "100"}, self.root))
        self.add(None, raw=gzip.compress(json.dumps({"padding": "x" * 5000}).encode()))
        result = cache.read_catalog_resources(self.root, maximum_body_bytes=1024)
        self.assertEqual(result["failures"], {"ValueError": 1})

    def test_newest_fields_win_but_older_missing_fields_are_retained(self):
        old = song(title="Old title")
        old["attributes"]["releaseDate"] = "2026-01-01"
        new = song(title="New title")
        self.add({"data": [old]}, stamp="2026-01-01 00:00:00")
        self.add({"data": [new]}, stamp="2026-01-02 00:00:00")
        result = cache.fetch({"appleSongID": "100"}, self.root)
        self.assertEqual(result["attributes"]["name"], "New title")
        self.assertEqual(result["attributes"]["releaseDate"], "2026-01-01")

    def test_ambiguous_recordings_require_id(self):
        self.add({"data": [song("100"), song("101")]})
        self.assertIsNone(cache.fetch({"title": "Example Song", "artist": "Example Artist", "duration": 180}, self.root))

    def test_isrc_selects_only_the_requested_recording(self):
        self.add({"data": [song()]})
        result = cache.fetch({"isrc": "XXEXA2600001"}, self.root)
        self.assertEqual(result["songID"], "100")
        self.assertEqual(result["matchKind"], "isrc")
        self.assertIsNone(cache.fetch({"isrc": "XXEXA2699999"}, self.root))

    def test_album_id_does_not_invent_song_id(self):
        self.add({"data": [album()]})
        result = cache.fetch({"appleAlbumID": "200"}, self.root)
        self.assertEqual(result["albumID"], "200")
        self.assertNotIn("songID", result)
        self.assertNotIn("lyricsTTML", result)

    def test_missing_cache_is_reported_as_empty(self):
        result = cache.read_catalog_resources(self.root / "missing")
        self.assertEqual(result["status"], "empty")
        self.assertEqual(result["reason"], "cache_database_missing")
        self.assertIsNone(cache.fetch({"appleSongID": "100"}, self.root / "missing"))

    def test_enhanced_hls_audio_is_not_misidentified_as_motion_artwork(self):
        track = song()
        track["attributes"]["extendedAssetUrls"] = {"enhancedHls": "https://audio.itunes.apple.com/audio.m3u8"}
        self.add({"data": [track]})
        result = cache.fetch({"appleSongID": "100"}, self.root)
        self.assertEqual(result["motion"], [])

    def test_string_ttml_and_unsafe_xml(self):
        track = song()
        track["relationships"]["syllable-lyrics"] = {"data": [{"attributes": {"ttmlLocalizations": TTML}}]}
        self.add({"data": [track]})
        self.assertEqual(cache.fetch({"appleSongID": "100"}, self.root)["lyricsTTML"], TTML)
        unsafe = '<!DOCTYPE tt [<!ENTITY data SYSTEM "file:///never-read">]><tt>&data;</tt>'
        self.assertEqual(cache._ttml_localizations({"attributes": {"ttml": unsafe}}), {})

    def test_normalized_artist_and_lyrics_resources_follow_only_linked_ids(self):
        track = song()
        track["relationships"].update({"artists": {"data": [{"type": "artists", "id": "300"}]},
                                       "syllable-lyrics": {"data": [{"type": "syllable-lyrics", "id": "100"}]}})
        track["attributes"]["audioTraits"] = ["lossless"]
        artist = {"id": "300", "type": "artists", "attributes": {"name": "Example Artist", "artistBio": {"standard": "Biography"}, "origin": "Origin"}}
        lyrics = {"id": "100", "type": "syllable-lyrics", "attributes": {"ttmlLocalizations": {"en": TTML}}}
        unrelated_lyrics = {"id": "999", "type": "syllable-lyrics", "attributes": {"ttml": "UNRELATED_LYRICS"}}
        self.add({"resources": {"songs": {"100": track}, "artists": {"300": artist}, "syllable-lyrics": {"100": lyrics, "999": unrelated_lyrics}}})
        result = cache.fetch({"appleSongID": "100"}, self.root)
        self.assertEqual(result["attributes"]["artistBiography"], {"standard": "Biography"})
        self.assertEqual(result["attributes"]["artistOrigin"], "Origin")
        self.assertEqual(result["attributes"]["audioVariants"], ["lossless"])
        self.assertEqual(result["lyricsTTML"], TTML)
        self.assertEqual(len(result["resources"]["lyrics"]), 1)
        self.assertNotIn("UNRELATED_LYRICS", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
