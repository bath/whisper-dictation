# whisper-dictation

**Private, on-device dictation for macOS.** Press the **F5 / dictation key**, talk, press it
again — your words appear in whatever you're typing into. No cloud, no account, no telemetry.

Powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) running locally, so it's both
more accurate than the built-in macOS Dictation *and* your voice never leaves the machine.

---

## Install

One command (needs [Homebrew](https://brew.sh)):

```sh
curl -fsSL https://raw.githubusercontent.com/bath/whisper-dictation/main/install.sh | bash
```

It installs the tools, downloads the Whisper model (~550 MB), and copies the required configs.
Karabiner does not allow imported rules to be enabled by the installer, so the clicks below are
required before F5 will work.

## Then click 3 things (macOS won't let a script do these)

1. **System Settings → Privacy & Security** — enable **Hammerspoon** under both **Microphone**
   and **Accessibility**.
2. **Karabiner-Elements** (the installer opens it) — approve its driver / system extension +
   **Input Monitoring** when prompted, then **Settings → Complex Modifications → Add rule →**
   enable **“F5 / Dictation key → F18”**. Merely installing or opening Karabiner does not
   enable the rule.
3. *(optional)* **System Settings → Keyboard → Dictation → Off**, so Apple's cloud dictation
   doesn't also fire on that key.

## Use it

Click into any text field → **press F5** → talk → **press F5 again**. Text appears a second or
two later.

> **No F5 key, or want to skip Karabiner?** `⌥Space` toggles dictation too — that path only
> needs step 1 (Hammerspoon permissions). Karabiner exists solely to make the *bare* dictation
> key work, since macOS sends it as a special event Hammerspoon can't catch on its own.

## Troubleshooting

- **F5 asks whether you want to enable Apple's Dictation:** the Karabiner rule is installed but
  not enabled. In Karabiner-Elements, open **Complex Modifications → Add rule** and enable
  **“F5 / Dictation key → F18”**.
- **F5 does nothing:** try `⌥Space`. If that works, check the Karabiner rule and its Input
  Monitoring permission. If it does not, enable Hammerspoon under both **Microphone** and
  **Accessibility**, then reload its config from the menu-bar icon.
- **The hotkey works:** the Hammerspoon menu icon changes from 🎙 to 🔴 while recording.

---

## How it works

```
F5 / dictation key ──(Karabiner)──▶ F18 ──(Hammerspoon)──▶ toggle
   start:  ffmpeg records the mic → a temp .wav
   stop:   whisper-cli transcribes it → text → pasted into the focused app (clipboard restored)
```

Everything is a temp file that's overwritten each time; nothing is uploaded.

## Requirements

macOS (Apple-Silicon Homebrew paths) · Homebrew · `ffmpeg` · `whisper-cli` · Hammerspoon ·
Karabiner-Elements (for the F5 key). The installer handles all of these.

## Customize

Edit the config block at the top of `~/.hammerspoon/whisper-dictation.lua`, then reload
Hammerspoon (menu-bar 🎙 → *Reload Config*):

| setting   | default                                          | notes |
|-----------|--------------------------------------------------|-------|
| `MODEL`   | `~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin`  | any ggml model; smaller = faster, less accurate |
| `MIC`     | `nil`                                            | auto-detects the Mac's built-in mic; set an avfoundation name such as `":Studio Display Microphone"` to override |
| `LANG`    | `"en"`                                           | or `"auto"` |
| `HOTKEYS` | `{{}, "f18"}`, `{{"alt"}, "space"}`              | add/replace toggle hotkeys |

## Manual install (no curl)

```sh
git clone https://github.com/bath/whisper-dictation
cd whisper-dictation
./install.sh
```

## Uninstall

```sh
rm ~/.hammerspoon/whisper-dictation.lua
rm ~/.config/karabiner/assets/complex_modifications/whisper-dictation.json
# remove the require("whisper-dictation") line from ~/.hammerspoon/init.lua
# disable the rule in Karabiner, and `brew uninstall --cask hammerspoon karabiner-elements` if unused
```

## Notes / limitations

- **Batch, not live** — text appears after you stop, not word-by-word. The tradeoff for a real
  local model.
- The built-in microphone is selected by name so an iPhone Continuity microphone cannot take
  over merely because it appears first in AVFoundation's device list.
- Paste uses Cmd+V and restores your prior clipboard; a few secure fields block programmatic paste.
- Paths assume Apple-Silicon Homebrew (`/opt/homebrew`); adjust for Intel (`/usr/local`).

## License

MIT — see [LICENSE](LICENSE).
