"""Validate completed transitions and compare local-cache audio discontinuities."""
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
results = {}
for codec in ("h264", "hevc"):
    for transport in ("file", "http"):
        for cache in ("default", "500"):
            case = f"{codec}-{transport}-{cache}"
            log = (root / f"rate-{case}-diagnostics.log").read_text()
            segments = re.split(r"^.*rate request=", log, flags=re.M)[2:]
            assert len(segments) == 6, (case, "missing rate transitions")
            silence = []
            flush = []
            for segment in segments:
                target = float(segment.split()[0])
                sample = re.search(r"rate sample after=1.0 .*?nativeRate=([\d.]+)", segment)
                assert sample and abs(float(sample[1]) - target) < 0.01, (case, "rate did not settle")
                silence.extend(-int(x) / 1000 for x in re.findall(r"playback way too early \((-?\d+)\): playing silence", segment))
                flush.extend(int(x) / 1000 for x in re.findall(r"playback (?:way )?too late \((-?\d+)\): flushing buffers", segment))
            results[case] = {"silence_ms": silence, "flush_drift_ms": flush}
# A paired H.264 control detects loss of the latency policy without interpreting
# host-dependent HEVC software decoding as an iPad performance measurement.
for transport in ("file", "http"):
    default = results[f"h264-{transport}-default"]["silence_ms"]
    control = results[f"h264-{transport}-500"]["silence_ms"]
    assert len(control) >= 3, (transport, "control did not reproduce audio resynchronization")
    assert sum(default) < sum(control) * 0.8, (transport, default, control)
(root / "rate-summary.json").write_text(json.dumps(results, indent=2) + "\n")
print("VLC_RATE_COMPARISON_PASSED: rates settle; local defaults reduce inserted silence")
print(json.dumps(results))
