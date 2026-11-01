import unittest
from analyze_pcm import analyze


def fixture(gaps=(), overflow=0):
    clocks = "\n".join(f"ANIMEKO_CLOCK now={1_000_000 + i * 2_000_000} old={old} new={new}"
                       for i, (old, new) in enumerate(zip([1000, 800, 400, 800, 400, 800, 400],
                                                         [800, 400, 800, 400, 800, 400, 800])))
    summary = f"ANIMEKO_PCM rate=48000 frames=960000 audible=900000 events={len(gaps)} overflow={overflow} missing_host=0"
    events = "\n".join(f"ANIMEKO_PCM silence start_us={start} frames={frames}" for start, frames in gaps)
    return clocks + "\n" + summary + "\n" + events


class MeasurementTests(unittest.TestCase):
    def test_startup_silence_is_not_a_rate_gap(self):
        self.assertTrue(analyze(fixture([(500_000, 4800)]))["no_measured_silence_in_rate_windows"])

    def test_crossing_boundary_is_clipped(self):
        result = analyze(fixture([(2_950_000, 4800)]))
        self.assertAlmostEqual(result["windows"][0]["total_silence_ms"], 50)
        self.assertFalse(result["no_measured_silence_in_rate_windows"])

    def test_missing_capture_is_not_success(self):
        with self.assertRaises(ValueError):
            analyze("")

    def test_overflow_is_not_success(self):
        with self.assertRaises(ValueError):
            analyze(fixture(overflow=1))

    def test_incomplete_events_are_rejected(self):
        with self.assertRaises(ValueError):
            analyze(fixture().replace("events=0", "events=1"))

    def test_unrelated_timebase_is_rejected(self):
        with self.assertRaises(ValueError):
            analyze(fixture([(999_000_000, 4800)]))


if __name__ == "__main__":
    unittest.main()
