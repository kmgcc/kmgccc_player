import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import music_enrichment_musicbrainz as mb

RECORDING_ID = "a61e2346-fdee-404a-bc81-879b0cf51e4d"
RELEASE_ID = "9f04efc2-e3ce-4b47-91ae-c95c84c49ac8"
OTHER_RELEASE = "27a56c0c-44db-4892-a449-156d62056ab1"


class MusicBrainzTests(unittest.TestCase):
    def setUp(self):
        self.query = {"title": "Song", "artist": "Artist", "album": "Album", "duration": 200}
        self.recording = {"id": RECORDING_ID, "title": "Song", "length": 200000,
                          "artist-credit": [{"name": "Artist"}], "isrcs": ["ISRC123"],
                          "releases": [{"id": OTHER_RELEASE, "title": "Other", "date": "1999"},
                                       {"id": RELEASE_ID, "title": "Album", "date": "2000"}],
                          "relations": [{"type": "producer", "artist": {"id": "person", "name": "Producer"}},
                                        {"type": "performance", "work": {"relations": [{"type": "composer", "artist": {"id": "writer", "name": "Composer"}}]}}]}
        self.release = {"id": RELEASE_ID, "title": "Album", "date": "2000", "barcode": "1234567890", "label-info": [{"label": {"name": "Label"}}]}

    def test_selected_release_and_recording_survive_credits_enrichment(self):
        with patch.object(mb, "_get", side_effect=[{"recordings": [self.recording]}, self.recording, self.release]) as get:
            result = mb.fetch(self.query)
        self.assertEqual(get.call_args_list[2].args[0], "release/" + RELEASE_ID)
        self.assertEqual(result["resources"], {"recording": self.recording, "release": self.release})
        self.assertEqual(result["attributes"]["musicBrainzRecordingID"], RECORDING_ID)
        self.assertEqual(result["attributes"]["musicBrainzReleaseID"], RELEASE_ID)
        self.assertEqual([c["role"] for c in result["attributes"]["credits"]], ["producer", "composer"])
        self.assertNotIn("songID", result)
        self.assertNotIn("albumID", result)

    def test_wrong_live_version_or_duration_does_not_get_fetched(self):
        for change in ({"title": "Song (Live)"}, {"length": 250000}):
            candidate = {**self.recording, **change}
            with patch.object(mb, "_get", return_value={"recordings": [candidate]}) as get:
                self.assertIsNone(mb.fetch(self.query))
                self.assertEqual(get.call_count, 1)

    def test_empty_query_skips_network(self):
        with patch.object(mb, "_get") as get:
            self.assertIsNone(mb.fetch({}))
            get.assert_not_called()

    def test_explicit_recording_and_release_ids_skip_search_and_keep_release(self):
        with patch.object(mb, "_get", side_effect=[self.recording, self.release]) as get:
            result = mb.fetch({"musicBrainzRecordingID": RECORDING_ID, "musicBrainzReleaseID": RELEASE_ID})
        self.assertEqual(get.call_args_list[0].args[0], "recording/" + RECORDING_ID)
        self.assertEqual(result["attributes"]["musicBrainzReleaseID"], RELEASE_ID)

    def test_isrc_query_does_not_change_version_selection(self):
        query = {**self.query, "isrc": "ISRC123"}
        with patch.object(mb, "_get", side_effect=[{"recordings": [self.recording]}, self.recording, self.release]) as get:
            result = mb.fetch(query)
        self.assertEqual(get.call_args_list[0].kwargs["query"], 'isrc:"ISRC123"')
        self.assertEqual(result["attributes"]["isrc"], "ISRC123")

    def test_release_tie_uses_oldest_date_like_existing_automation_provider(self):
        releases = [{"id": "new", "title": "Album", "date": "2020"}, {"id": "old", "title": "Album", "date": "1990"}]
        self.assertEqual(mb._best_release(releases, "Album")["id"], "old")


if __name__ == "__main__":
    unittest.main()
