"""Measure drawable presentation intervals around each requested rate change."""
import json
import re
import statistics
import sys
from pathlib import Path


def analyze(log):
    summaries = re.findall(r"ANIMEKO_FRAMES count=(\d+) overflow=(\d+) requests=(\d+) request_overflow=(\d+)", log)
    if len(summaries) != 1:
        raise ValueError("Missing or duplicate frame measurement")
    count, overflow, requested, request_overflow = map(int, summaries[0])
    frames = list(map(int, re.findall(r"ANIMEKO_FRAME at_us=(\d+)", log)))
    requests = [(int(at), int(rate)) for at, rate in re.findall(
        r"ANIMEKO_FRAME_RATE at_us=(\d+) target_milli=(\d+)", log)]
    if overflow or request_overflow or count != len(frames) or requested != len(requests):
        raise ValueError("Incomplete frame measurement")
    if [rate for _, rate in requests] != [1250, 2500, 1250, 2500, 1250, 2500, 1250]:
        raise ValueError("Missing rate requests")
    if len(frames) < 2 or any(b <= a for a, b in zip(frames, frames[1:])):
        raise ValueError("Invalid presentation timestamps")
    windows = []
    for index, (start, rate) in enumerate(requests[1:], 1):
        end = min(start + 1_500_000, requests[index + 1][0] if index + 1 < len(requests) else start + 1_500_000)
        if frames[0] > start or frames[-1] < end:
            raise ValueError("Frames do not cover the rate window")
        gaps = [(b - a) / 1000 for a, b in zip(frames, frames[1:]) if b > start and a < end]
        if not gaps:
            raise ValueError("No drawable presentations in rate window")
        windows.append({"target": rate / 1000, "start_us": start,
                        "maximum_gap_ms": max(gaps), "median_gap_ms": statistics.median(gaps),
                        "interval_count": len(gaps)})
    return {"windows": windows, "scope": "Drawable presentation timing; does not identify displayed content or prove A/V alignment"}


if __name__ == "__main__":
    root = Path(sys.argv[1])
    results = {}
    for codec in ("h264", "hevc"):
        for transport in ("file", "http"):
            for cache in ("default", "500"):
                case = f"{codec}-{transport}-{cache}"
                results[case] = analyze((root / f"rate-{case}-frames.log").read_text())
    (root / "frame-summary.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
