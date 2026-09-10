# channels/

The `.m3u` files here are **downloaded**, not committed — they roll daily
upstream (BuddyChewChew/app-m3u-generator). Populate them before playing:

```bash
~/.config/omarchy/plugins/user.oma-tv/scripts/refresh-channels.sh
```

or press the refresh button in the popup header.

- `roku.m3u` — Roku FAST channels (the shipped service).
- `plex.m3u` — Plex FAST opt-in (only ~10% of channels deliver video).

`.flat/` holds the single-variant (720p) playlists the controller unfolds from
each Roku master to skip mpv's slow multi-variant probing; it is rebuilt
automatically. `/tmp/oma-flat-*.lck` guards the background rebuild.