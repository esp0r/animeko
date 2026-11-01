"""Correlate native rate boundaries with measured AudioUnit output silence."""
import argparse
import json
import re
from pathlib import Path


def analyze(native: str) -> dict:
    summaries = re.findall(
        r"ANIMEKO_PCM rate=(\d+) frames=(\d+) audible=(\d+) events=(\d+) overflow=(\d+) missing_host=(\d+)",
        native,
    )
    if len(summaries) != 1:
        raise ValueError(f"Expected one complete output measurement, got {len(summaries)}")
    rate, frames, audible, count, overflow, missing_host = map(int, summaries[0])
    if rate <= 0 or audible < rate or frames < audible or overflow or missing_host:
        raise ValueError("Incomplete or invalid PCM output measurement")
    gaps = [(int(start), int(length)) for start, length in re.findall(
        r"ANIMEKO_PCM silence start_us=(\d+) frames=(\d+)", native)]
    if len(gaps) != count:
        raise ValueError("PCM silence event count does not match the summary")
    clocks = [(int(now), int(old), int(new)) for now, old, new in re.findall(
        r"ANIMEKO_CLOCK now=(\d+) old=(\d+) new=(\d+)", native)
        if old != new]
    if [new for _, _, new in clocks] != [800, 400, 800, 400, 800, 400, 800]:
        raise ValueError("Expected initial 1.25x followed by three 2.5x/1.25x cycles")
    # Both timestamps are native monotonic microseconds. Reject an unrelated
    # epoch instead of reporting apparent continuity from disjoint timelines.
    if any(start < clocks[0][0] - 60_000_000 or start > clocks[-1][0] + 60_000_000
           for start, _ in gaps):
        raise ValueError("PCM and clock timestamps do not share the expected time range")
    windows = []
    for index, (start, _, inverse_rate) in enumerate(clocks[1:], 1):
        end = min(start + 1_500_000, clocks[index + 1][0] if index + 1 < len(clocks) else start + 1_500_000)
        overlaps = []
        for gap_start, gap_frames in gaps:
            gap_end = gap_start + gap_frames * 1_000_000 / rate
            duration = min(end, gap_end) - max(start, gap_start)
            if duration > 0:
                overlaps.append(duration / 1000)
        windows.append({"target": 1000 / inverse_rate, "start_us": start,
                        "silence_ms": overlaps, "total_silence_ms": sum(overlaps)})
    return {"sample_rate": rate, "rendered_frames": frames, "audible_frames": audible,
            "windows": windows,
            "no_measured_silence_in_rate_windows": all(not w["silence_ms"] for w in windows),
            "scope": "AudioUnit PCM only; video continuity and content A/V alignment require separate verification"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    results = {}
    for codec in ("h264", "hevc"):
        for transport in ("file", "http"):
            for cache in ("default", "500"):
                case = f"{codec}-{transport}-{cache}"
                results[case] = analyze((args.directory / f"rate-{case}.log").read_text())
    destination = args.directory / "pcm-summary.json"
    destination.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
