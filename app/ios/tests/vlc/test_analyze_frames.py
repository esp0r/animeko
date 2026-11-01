import unittest
from analyze_frames import analyze


def log(frames=None):
    if frames is None:
        frames = range(0, 16_000_001, 10_000)
    rows = [f"ANIMEKO_FRAMES count={len(frames)} overflow=0 requests=7 request_overflow=0"]
    rows += [f"ANIMEKO_FRAME_RATE at_us={at} target_milli={rate}" for at, rate in
             zip([0, 3_000_000, 5_000_000, 7_000_000, 9_000_000, 11_000_000, 13_000_000],
                 [1250, 2500, 1250, 2500, 1250, 2500, 1250])]
    rows += [f"ANIMEKO_FRAME at_us={at}" for at in frames]
    return "\n".join(rows)


class FrameAnalysisTest(unittest.TestCase):
    def test_continuous_output(self):
        self.assertEqual([w["maximum_gap_ms"] for w in analyze(log())["windows"]], [10] * 6)

    def test_gap_crossing_request_is_included(self):
        frames = [x for x in range(0, 16_000_001, 10_000) if x not in (3_000_000, 3_010_000)]
        self.assertEqual(analyze(log(frames))["windows"][0]["maximum_gap_ms"], 30)

    def test_missing_records(self):
        with self.assertRaises(ValueError):
            analyze(log().replace("ANIMEKO_FRAME at_us=0\n", ""))

    def test_overflow(self):
        with self.assertRaises(ValueError):
            analyze(log().replace("count=1601 overflow=0", "count=1601 overflow=1"))

    def test_truncated_window(self):
        with self.assertRaises(ValueError):
            analyze(log(list(range(0, 13_000_001, 10_000))))


if __name__ == "__main__":
    unittest.main()
