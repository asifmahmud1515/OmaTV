#!/bin/bash
set -euo pipefail

# parse-m3u.sh — Parse M3U/M3U8 playlists into JSON
# Usage: parse-m3u.sh <path-or-url>
# Output: JSON array of {name, group, url} objects

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <m3u-file-or-url>" >&2
  exit 1
fi

SRC="$1"

# Fetch to temp file if it's a URL
if [[ "$SRC" =~ ^https?:// ]]; then
  TMPFILE=$(mktemp /tmp/oma-tv-m3u.XXXXXX)
  trap 'rm -f "$TMPFILE"' EXIT
  curl -fsSL --connect-timeout 10 --max-time 30 "$SRC" -o "$TMPFILE" 2>/dev/null || {
    echo "[]"
    exit 0
  }
  SRC="$TMPFILE"
fi

if [[ ! -f "$SRC" ]]; then
  echo "[]"
  exit 0
fi

# Parse M3U with awk — output JSON array
awk '
BEGIN { printf "["; sep = ""; count = 0 }

# Skip the header line
/^#EXTM3U/ { next }

# Skip full-line comments
/^#/ && !/^#EXTINF:/ { next }

# Parse #EXTINF lines for metadata
/^#EXTINF:/ {
    inf = $0
    # Extract group-title="..."
    group = ""
    if (match(inf, /group-title="([^"]*)"/, m)) {
        group = m[1]
    }
    # Extract tvg-name="..."
    tvgname = ""
    if (match(inf, /tvg-name="([^"]*)"/, m)) {
        tvgname = m[1]
    }
    # Extract display name after the last comma
    name = ""
    idx = index(inf, ",")
    if (idx > 0) {
        name = substr(inf, idx + 1)
    }
    # Trim leading/trailing whitespace from name
    gsub(/^[ \t]+|[ \t]+$/, "", name)
    # Use tvg-name as fallback
    if (name == "" && tvgname != "") name = tvgname
    if (name == "") name = "Unknown"
    next
}

# Only treat lines that look like stream URLs as URLs
/^(http|https|rtsp|rtmp|rtmps|udp|mms|file|sttp):\/\// && NF > 0 {
    url = $0
    gsub(/^[ \t]+|[ \t]+$/, "", url)
    gsub(/\r$/, "", url)
    # Skip if this is a plain text continuation (not a URL)
    if (url !~ /^(http|https|rtsp|rtmp|rtmps|udp|mms|file|sttp):\/\//) next
    if (group == "") group = "Ungrouped"
    if (name == "") name = "Unknown"
    gsub(/\r$/, "", name)
    gsub(/\r$/, "", group)

    # Escape JSON special characters in name and group
    gsub(/\\/, "\\\\", name)
    gsub(/"/, "\\\"", name)
    gsub(/\\/, "\\\\", group)
    gsub(/"/, "\\\"", group)
    gsub(/\\/, "\\\\", url)
    gsub(/"/, "\\\"", url)

    idx = count
    printf "%s{\"name\":\"%s\",\"group\":\"%s\",\"url\":\"%s\",\"index\":%d}", sep, name, group, url, idx
    sep = ","
    count++
    name = ""
    group = ""
    tvgname = ""
}

END { printf "]\n" }
' "$SRC"