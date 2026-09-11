# Oma TV

Free-streaming TV for the Omarchy shell. A bar-widget button (television icon)
opens a popup to browse Roku channels — or any m3u playlist you add by URL —
and plays them in a single shared `mpv` window that can be cycled between
picture-in-picture, windowed and fullscreen modes.

Free Roku TV channels are available, you can add your own m3u playlists given by your IPTV providers 

## Requirements

- `mpv` (playback)
- `curl`, `jq` (channel refresh)
- `hyprctl` (window placement for PiP / windowed / fullscreen modes)

## Install

The plugin can be installed from this repository with:

```bash
omarchy plugin add https://github.com/asifmahmud1515/OmaTV.git --enable
```

or placed in `~/.config/omarchy/plugins/user.oma-tv/` manually. Download the
channel lists before first use:

```bash
~/.config/omarchy/plugins/user.oma-tv/scripts/refresh-channels.sh
```

(Channel lists are intentionally not committed to this repo — they roll daily
upstream.)

## Usage

- **Open popup** — click the Oma TV icon in the bar (top-right). Click again
  (or press `Escape`) to close.
- **Browse** — pick the service (Roku) to load its channel list, click a group
  chip to filter by category, or just type to search.
- **Play** — selecting a channel starts `mpv` in ~10s. Repeat for any other
  channel to swap instantly (no relaunch).
- **Custom playlists** — press **Add m3u playlist**, type (or paste) an
  `https://` URL of an `.m3u`/`.m3u8` file, and press `Enter`. The list is
  downloaded to `channels/custom/` and registered in `channels/custom.json`,
  then appears as its own service row (with a `×` chip to remove it).
  Custom lists survive `refresh-channels.sh` and the usual search group/filter
  all apply. Managing playlists via the CLI:
  `oma-tv-ctl add <url> [name]` / `oma-tv-ctl remove <custom-id>` /
  `oma-tv-ctl services`.
- **Channel switching** — Roku masters advertise 6 quality variants; `mpv`
  would probe every variant's chunklist (~1s each) before the first frame,
  which is what made channels take ~20-30s. The controller "unfolds" the master
  once into a single-variant (720p) playlist stored at `channels/.flat/`, so
  in-player and popup channel changes start in ~3-5s. The flat list is rebuilt
  automatically in the background when `channels/<service>.m3u` changes.
- **Mode** — click the bar icon with the **right mouse button** to cycle
  PiP → Windowed → Fullscreen (fullscreen cycles back to windowed). The popup
  footer also has a mode switch. `Escape` on the player returns from
  fullscreen to windowed, otherwise stops playback.
- **Stop** — middle-click the bar icon or use the stop button in the popup.
- **In-player keys** — `Up/Down/Left/Right` change channel (bound via the
  `--input-conf` file `mpv-keys.conf`, because `mpv` drops `Up`/`Down` bound
  through Lua's `mp.add_key_binding` on this build), `F` toggles pause,
  `Escape` exits fullscreen or stops. Player startup uses `--cache-pause=no`
  with small seek cache so channel switches start as soon as segments arrive;
  total switch time is bounded by the stream's network latency.

### Controls

| Key            | Action                              |
|----------------|-------------------------------------|
| `Up` / `Down`  | Navigate channels                   |
| `Enter`        | Play selected channel               |
| `Escape`       | Close popup (or exit fullscreen)    |
| letters/digits | Type to search channel names        |
| `Return`       | In the URL editor: download playlist |
| `Backspace` / `Escape` | In the URL editor: edit / cancel  |

Bar icon | Right-click cycles mode, middle-click stops, left-click toggles popup.

### Refresh channels

Channel lists are cached under `channels/`. To re-download them:

```bash
~/.config/omarchy/plugins/user.oma-tv/scripts/refresh-channels.sh
```

or press the refresh button in the popup header. Refreshing also clears the
`.flat/` cache so the next play re-unfolds variants against the new masters
(Samsung / Pluto were removed because they are blocked upstream; see the
header note). Playlists you added are kept untouched under `channels/custom/`.

## Components

```
user.oma-tv/
├── manifest.json        # Plugin manifest (panel, bar-widget kinds)
├── BarWidget.qml        # Bar button + popup UI
├── Panel.qml            # Panel UI (channel list + now-playing footer)
├── ChannelsModel.js     # Filter/group/search helpers
└── scripts/
        ├── oma-tv-ctl       # Controller: play/next/prev/stop/mode/pause/refresh/status
        │                    #   plus add/remove/services for custom m3u playlists;
        │                    #   launches mpv idle, loads playlist via IPC;
        │                    #   unfolds multi-variant masters into .flat/ playlists
        ├── parse-m3u.sh     # M3U/M3U8 → JSON channel list (incl. 0-based index)
        ├── mpv-zap.lua      # In-player keybindings (mode/pause/esc, auto-skip dead)
        ├── mpv-keys.conf    # Arrow-key zapping via --input-conf (see note above)
        └── refresh-channels.sh # Re-downloads the Roku list (opt-in Plex too)
```

## Troubleshooting

- **"No channels found"** — the list parsed with zero channels. Run
  `refresh-channels.sh`, or check the file in `channels/` has `#EXTM3U` +
  `#EXTINF`/URL pairs.
- **Popup won't open** — plugin must be enabled:
  `omarchy plugin list | grep oma-tv`
- **Player window missing** — the controller waits up to 8s for the mpv window
  to map before applying PiP geometry; if nothing appears check `mpv` is on
  `PATH`. For current playback status:
  `~/.config/omarchy/plugins/user.oma-tv/scripts/oma-tv-ctl status`
- **One-off dead channel** — playback auto-skips to the next channel after
  ~1s with the OSD "Channel unavailable, skipping". If a whole service shows
  nothing, run `refresh-channels.sh` (lists roll daily).
