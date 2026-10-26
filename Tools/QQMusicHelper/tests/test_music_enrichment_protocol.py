import contextlib
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import main


class MusicEnrichmentProtocolTests(unittest.TestCase):
    def test_artwork_provider_requests_only_cover_metadata(self):
        with patch.object(main.music_enrichment_web, "fetch", return_value={"source": "appleWeb"}) as fetch:
            response, stderr = self.run_request({"provider": "appleArtwork", "query": {"title": "Song"}})
        self.assertEqual(response, {"ok": True, "result": {"source": "appleWeb"}})
        self.assertEqual(stderr, "")
        fetch.assert_called_once_with({"title": "Song"}, artwork_only=True)

    def run_request(self, request):
        stdin = io.TextIOWrapper(io.BytesIO(json.dumps(request).encode()))
        output = io.StringIO()
        error = io.StringIO()
        with patch.object(main.sys, "stdin", stdin), contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            self.assertEqual(main.music_enrichment_main(), 0)
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        return json.loads(output.getvalue()), error.getvalue()

    def test_independent_providers_use_the_same_one_shot_contract(self):
        for provider, module, name in (("appleWeb", main.music_enrichment_web, "fetch"),
                                       ("appleCache", main.music_enrichment_cache, "fetch"),
                                       ("amllDB", main.music_enrichment_web, "fetch_amll"),
                                       ("musicBrainz", main.music_enrichment_musicbrainz, "fetch")):
            with self.subTest(provider=provider), patch.object(module, name, return_value={"source": provider}) as fetch:
                response, stderr = self.run_request({"provider": provider, "query": {"title": "Song"}})
            self.assertEqual(response, {"ok": True, "result": {"source": provider}})
            self.assertEqual(stderr, "")
            fetch.assert_called_once_with({"title": "Song"})

    def test_credential_bearing_exception_never_crosses_protocol_or_stderr(self):
        with patch.object(main.music_enrichment_web, "fetch", side_effect=ValueError("Authorization: Bearer SECRET https://host/?token=SECRET")):
            response, stderr = self.run_request({"provider": "appleWeb"})
        self.assertEqual(response, {"ok": False, "error": "ValueError", "retryable": False})
        self.assertEqual(stderr, "")

    def test_network_trouble_is_marked_retryable(self):
        from urllib.error import HTTPError, URLError
        for error, retryable in ((HTTPError("https://host", 503, "busy", {}, None), True),
                                 (HTTPError("https://host", 404, "missing", {}, None), False),
                                 (URLError("offline"), True), (TimeoutError(), True)):
            with self.subTest(error=error), patch.object(main.music_enrichment_web, "fetch", side_effect=error):
                response, _ = self.run_request({"provider": "appleWeb"})
            self.assertEqual(response["retryable"], retryable)

    def test_credential_fields_are_removed_before_returning_provider_values(self):
        with patch.object(main.music_enrichment_web, "fetch", return_value={"source": "appleWeb", "attributes": {"name": "Song", "authorization": "SECRET", "url": "https://host?userToken=SECRET", "notes": "Bearer SECRET"}}):
            response, _ = self.run_request({"provider": "appleWeb"})
        self.assertNotIn("SECRET", json.dumps(response))
        self.assertEqual(response["result"]["attributes"]["name"], "Song")

    def test_motion_has_asset_instead_of_result(self):
        asset = {"path": "/library/motion.mp4", "startTime": 10, "duration": 20}
        with patch.object(main.music_enrichment_web, "materialize_motion", return_value=asset):
            response, _ = self.run_request({"provider": "motion", "url": "https://mvod.itunes.apple.com/a.m3u8", "destination": asset["path"]})
        self.assertEqual(response, {"ok": True, "asset": asset})

    def test_motion_search_returns_candidates_for_explicit_selection(self):
        candidates = [{"source": "appleWeb", "albumID": "123", "motion": [{"kind": "square", "url": "https://mvod.itunes.apple.com/a.m3u8"}]}]
        with patch.object(main.music_enrichment_web, "search_motion", return_value=candidates) as search:
            response, stderr = self.run_request({"provider": "motionSearch", "query": {"artist": "Artist"}})
        self.assertEqual(response, {"ok": True, "candidates": candidates})
        self.assertEqual(stderr, "")
        search.assert_called_once_with({"artist": "Artist"})

    def test_empty_result_is_successful_miss(self):
        with patch.object(main.music_enrichment_cache, "fetch", return_value=None):
            response, _ = self.run_request({"provider": "appleCache"})
        self.assertEqual(response, {"ok": True, "result": None})

    def test_real_entrypoint_needs_no_qqmusic_dependency_or_startup_diagnostics(self):
        process = subprocess.run([sys.executable, str(ROOT / "main.py"), "--music-enrichment"], input=b'{"provider":"amllDB","query":{}}', capture_output=True, timeout=10)
        self.assertEqual(json.loads(process.stdout), {"ok": True, "result": None})
        self.assertEqual(process.stderr, b"")

    def test_legacy_qqmusic_protocol_remains_line_oriented(self):
        process = subprocess.run([sys.executable, str(ROOT / "main.py")], input=b'{"id":"legacy-check","method":"unsupported","params":{}}\n', capture_output=True, timeout=10)
        response = json.loads(process.stdout)
        self.assertFalse(response["ok"])
        self.assertEqual(response["id"], "legacy-check")


if __name__ == "__main__":
    unittest.main()
