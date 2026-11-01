#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Synthetic H.264/AAC media derived from the existing generated subtitle fixture.
ffmpeg -hide_banner -loglevel error -y -stream_loop 6 -i fixture.mkv \
  -map 0:v -map 0:a -c copy -t 50 rate-fixture.mkv
ffmpeg -hide_banner -loglevel error -y -i rate-fixture.mkv \
  -map 0:v -map 0:a -vf scale=1920:1080 -c:v libx265 -preset ultrafast \
  -pix_fmt yuv420p10le -x265-params log-level=error:pools=4:frame-threads=2 \
  -crf 32 -c:a copy rate-hevc-fixture.mkv
