import unittest

import httpx

from lddc_fetch_core.exceptions import APIParamsError, APIRequestError
from lddc_fetch_core.models import Artist, Song, Source
from lddc_fetch_core.providers.lrclib import LrclibProvider


class LrclibProviderTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.payload = {
            "id": 42,
            "trackName": "Selected song",
            "artistName": "Selected artist",
            "albumName": "",
            "instrumental": False,
            "syncedLyrics": "[00:10.00]Timed line",
            "plainLyrics": "Plain line",
        }
        self.status = 200

        def respond(request):
            self.requests.append(request)
            return httpx.Response(self.status, json=self.payload)

        self.provider = LrclibProvider()
        self.provider.client.close()
        self.provider.client = httpx.Client(transport=httpx.MockTransport(respond))

    def tearDown(self):
        self.provider.client.close()

    def test_id_lookup_needs_no_album_duration_or_display_fields(self):
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(self.requests[0].url.path, "/api/get/42")
        self.assertFalse(self.requests[0].url.query)
        self.assertEqual(bundle.tags, {"ti": "Selected song", "ar": "Selected artist", "al": ""})
        self.assertEqual(bundle.orig[0].start, 10000)
        self.assertEqual(bundle.orig[0].text(), "Timed line")

    def test_selected_id_wins_over_conflicting_text_metadata(self):
        self.provider.get_lyrics(Song(
            source=Source.LRCLIB, id="42", title="Another song",
            artist=Artist("Another artist"), album="Another album", duration_ms=200000,
        ))
        self.assertEqual(self.requests[0].url.path, "/api/get/42")
        self.assertFalse(self.requests[0].url.query)

    def test_selected_search_record_avoids_a_second_network_request(self):
        self.payload = [self.payload]
        self.provider.search("Song")
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0].url.path, "/api/search")
        self.assertEqual(bundle.orig[0].text(), "Timed line")

    def test_cache_uses_exact_id_instead_of_another_search_match(self):
        self.payload = [dict(self.payload, id=43)]
        self.provider.search("Song")
        self.status = 404
        with self.assertRaisesRegex(APIRequestError, "404"):
            self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(self.requests[-1].url.path, "/api/get/42")

    def test_new_search_replaces_the_previous_page_cache(self):
        self.payload = [self.payload]
        self.provider.search("First search")
        self.payload = [dict(self.payload[0], id=43)]
        self.provider.search("Second search")
        self.payload = dict(self.payload[0], id=42)
        self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(self.requests[-1].url.path, "/api/get/42")

    def test_failed_search_keeps_the_previous_successful_page(self):
        self.payload = [self.payload]
        self.provider.search("First search")
        self.status = 503
        with self.assertRaises(APIRequestError):
            self.provider.search("Second search")
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(bundle.orig[0].text(), "Timed line")

    def test_text_lookup_allows_missing_album_and_duration(self):
        self.provider.get_lyrics(Song(source=Source.LRCLIB, title="Song", artist=Artist("Artist")))
        self.assertEqual(self.requests[0].url.path, "/api/get")
        self.assertEqual(dict(self.requests[0].url.params), {"track_name": "Song", "artist_name": "Artist"})

    def test_text_lookup_preserves_available_album_and_duration(self):
        self.provider.get_lyrics(Song(
            source=Source.LRCLIB, title="Song", artist=Artist("Artist"),
            album="Album", duration_ms=200500,
        ))
        self.assertEqual(self.requests[0].url.params["album_name"], "Album")
        self.assertEqual(self.requests[0].url.params["duration"], "200.5")

    def test_failed_id_does_not_fall_back_to_text(self):
        self.status = 404
        with self.assertRaisesRegex(APIRequestError, "404"):
            self.provider.get_lyrics(Song(
                source=Source.LRCLIB, id="42", title="Song", artist=Artist("Artist"),
            ))
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0].url.path, "/api/get/42")

    def test_invalid_id_is_rejected_without_network_request(self):
        with self.assertRaises(APIParamsError):
            self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42/another-record"))
        self.assertFalse(self.requests)

    def test_missing_title_or_artist_without_id_is_rejected(self):
        for song in [Song(source=Source.LRCLIB, title="Song"), Song(source=Source.LRCLIB, artist=Artist("Artist"))]:
            with self.subTest(song=song), self.assertRaises(APIParamsError):
                self.provider.get_lyrics(song)
        self.assertFalse(self.requests)

    def test_plain_lyrics_remain_untimed(self):
        self.payload["syncedLyrics"] = None
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertIsNone(bundle.orig[0].start)
        self.assertEqual(bundle.orig[0].text(), "Plain line")

    def test_unparseable_synced_lyrics_fall_back_to_plain(self):
        self.payload["syncedLyrics"] = "not timed lyrics"
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(bundle.orig[0].text(), "Plain line")

    def test_instrumental_record_keeps_flag_without_fabricating_text(self):
        self.payload.update(instrumental=True, syncedLyrics=None, plainLyrics=None)
        song = Song(source=Source.LRCLIB, id="42", extra={"existing": "value"})
        bundle = self.provider.get_lyrics(song)
        self.assertEqual(bundle.orig, [])
        self.assertEqual(bundle.song.extra, {"existing": "value", "instrumental": "true"})
        self.assertEqual(song.extra, {"existing": "value"})

    def test_empty_non_instrumental_record_stays_empty(self):
        self.payload.update(syncedLyrics=None, plainLyrics=None)
        bundle = self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))
        self.assertEqual(bundle.orig, [])
        self.assertEqual(bundle.song.extra["instrumental"], "false")

    def test_search_extra_values_match_native_string_dictionary(self):
        self.payload = [dict(self.payload, instrumental=True), dict(self.payload, id=43)]
        songs = self.provider.search("Song")
        self.assertEqual([song.extra["instrumental"] for song in songs], ["true", "false"])
        self.assertTrue(all(isinstance(value, str) for song in songs for value in song.extra.values()))

    def test_bad_response_shape_is_reported(self):
        self.payload = []
        with self.assertRaises(APIRequestError):
            self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))

    def test_service_error_does_not_silently_return_empty_lyrics(self):
        self.status = 503
        with self.assertRaisesRegex(APIRequestError, "503"):
            self.provider.get_lyrics(Song(source=Source.LRCLIB, id="42"))


if __name__ == "__main__":
    unittest.main()
