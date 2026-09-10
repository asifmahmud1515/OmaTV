#!/bin/bash
set -euo pipefail

# launch-player.sh — Launch mpv for an IPTV stream
# Usage: launch-player.sh <stream-url>

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <stream-url>" >&2
  exit 1
fi

URL="$1"

# Launch mpv detached so it survives the shell process
setsid mpv \
  --fullscreen \
  --no-terminal \
  --really-quiet \
  --ytdl=no \
  --cache=yes \
  --demuxer-max-bytes=50MiB \
  --demuxer-readahead-secs=30 \
  "$URL" \
  </dev/null >/dev/null 2>&1 &
