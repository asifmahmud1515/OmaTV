-- mpv-zap.lua — in-window Oma TV controls for the shared player window.
--
--   UP / DOWN / LEFT / RIGHT   zap channels (bound via mpv-keys.conf)
--   MOUSE_BTN0                 click to cycle PiP -> window -> fullscreen -> window
--   ESC                        exit fullscreen to windowed; second press stops playback
--
-- The controller script lives next to this file (see oma-tv-ctl).

local ctl = (mp.get_script_directory()
    or os.getenv("OMA_TV_SCRIPTS_DIR")
    or "/home/DEAN/.config/omarchy/plugins/user.oma-tv/scripts") .. "/oma-tv-ctl"

local function run_ctl(args, cb)
  local argv = { ctl }
  for _, a in ipairs(args) do
    argv[#argv + 1] = a
  end
  mp.command_native_async({ name = "subprocess", capture_stdout = true, args = argv },
    function(success, res)
      if cb then
        cb(success and res and (res.stdout or "") or "")
      end
    end)
end

local function ctl_mode()
  run_ctl({ "mode" }, function(out)
    local mode = out:match('"mode"%s*:%s*"([^"]+)"') or out:match("^%s*(%S+)%s*$")
    if mode and mode ~= "error" then
      mp.osd_message("Oma TV · " .. mode, 1.8)
    end
  end)
end

local function ctl_esc()
  run_ctl({ "esc" })
end

local function ctl_pause()
  mp.commandv("cycle", "pause")
  local paused = mp.get_property_bool("pause")
  mp.osd_message(paused and "Paused" or "Playing", 1.8)
end

mp.add_key_binding("MOUSE_BTN0", "oma-mode", ctl_mode)
mp.add_key_binding("ESC", "oma-esc", ctl_esc)
mp.add_key_binding("F", "oma-pause", ctl_pause)

local skip_streak = 0
local function on_end_file(e)
  local reason = e and e.reason or ""
  if reason ~= "error" and reason ~= "eof" then
    return
  end
  local count = mp.get_property_number("playlist-count", 0)
  local pos = mp.get_property_number("playlist-pos", -1)
  if pos >= 0 and pos + 1 < count and skip_streak < 5 then
    skip_streak = skip_streak + 1
    mp.osd_message("Channel unavailable, skipping", 2.5)
    mp.commandv("playlist-next", "force")
  end
end
mp.register_event("end-file", on_end_file)
mp.register_event("file-loaded", function() skip_streak = 0 end)