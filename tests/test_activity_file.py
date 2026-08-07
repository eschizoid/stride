import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools" / "stride_activity_file.py"
sys.path.insert(0, str(HELPER.parent))
import stride_activity_file as decoder  # noqa: E402


def tiny_fit() -> bytes:
    # Definition: record(global 20), timestamp(uint32), HR(uint8), distance(uint32).
    payload = bytes(
        [
            0x40, 0, 0, 20, 0, 3, 253, 4, 0x86, 3, 1, 0x02, 5, 4, 0x86,
            0x00, 100, 0, 0, 0, 120, 0, 0, 0, 0,
            0x00, 101, 0, 0, 0, 121, 100, 0, 0, 0,
        ]
    )
    return bytes([12, 0x20, 0, 0]) + len(payload).to_bytes(4, "little") + b".FIT" + payload


class ActivityFileTests(unittest.TestCase):
    def test_fit_streams(self) -> None:
        streams = json.loads(decoder.decode_fit(tiny_fit()))
        self.assertEqual(streams["time"]["data"], [0, 1])
        self.assertEqual(streams["heartrate"]["data"], [120.0, 121.0])
        self.assertEqual(streams["distance"]["data"], [0.0, 1.0])

    def test_gpx_streams(self) -> None:
        gpx = b"""<gpx xmlns:g=\"urn:test\"><trk><trkseg>
        <trkpt lat=\"30.0\" lon=\"-97.0\"><ele>100</ele><time>2026-08-06T12:00:00Z</time><extensions><g:hr>120</g:hr></extensions></trkpt>
        <trkpt lat=\"30.0001\" lon=\"-97.0\"><ele>101</ele><time>2026-08-06T12:00:01Z</time><extensions><g:hr>121</g:hr></extensions></trkpt>
        </trkseg></trk></gpx>"""
        streams = json.loads(decoder.decode_gpx(gpx))
        self.assertEqual(streams["time"]["data"], [0, 1])
        self.assertEqual(streams["heartrate"]["data"], [120.0, 121.0])
        self.assertGreater(streams["distance"]["data"][1], 10.0)

    def test_rejects_unsafe_member(self) -> None:
        self.assertFalse(decoder.safe_member("../activity.fit"))
        self.assertFalse(decoder.safe_member("activities/../../secret.fit"))
        self.assertTrue(decoder.safe_member("activities/123.fit.gz"))

    def test_stream_metrics_match_stride_boundaries(self) -> None:
        streams = {
            "time": list(range(60)),
            "heartrate": [150.0] * 60,
            "watts": [200.0] * 60,
            "altitude": [0.0] * 60,
            "distance": [float(value * 3) for value in range(60)],
        }
        metrics = decoder.stream_metrics(streams, (118.0, 147.0, 162.0, 177.0), 200.0, 0.0)
        self.assertEqual(metrics["zones"], [0, 0, 59, 0, 0])
        self.assertAlmostEqual(metrics["np"], 200.0)
        self.assertAlmostEqual(metrics["curve"][0], 200.0)
        self.assertEqual(metrics["intensity"], [0, 0, 59])

    def test_store_mode_upserts_stream_and_invalidates_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "export.zip"
            database = root / "db.sqlite"
            member = "activities/123.fit"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(member, tiny_fit())
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE streams (activity_id INTEGER PRIMARY KEY, raw_json TEXT)")
                connection.execute("CREATE TABLE activity_metrics (activity_id INTEGER PRIMARY KEY)")
                connection.execute("INSERT INTO activity_metrics VALUES (123)")
            subprocess.run(
                [sys.executable, str(HELPER), "--store", str(database), str(archive), member, "123"],
                check=True,
            )
            with sqlite3.connect(database) as connection:
                raw = connection.execute("SELECT raw_json FROM streams WHERE activity_id = 123").fetchone()[0]
                metrics = connection.execute("SELECT COUNT(*) FROM activity_metrics WHERE activity_id = 123").fetchone()[0]
            self.assertTrue(raw.startswith("stride-stream-v1:h=1;"))
            self.assertEqual(raw.splitlines()[1], "0,1")
            self.assertEqual(metrics, 0)


if __name__ == "__main__":
    unittest.main()
