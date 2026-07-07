# whisper-dictation

A private, **fully local** replacement for macOS Dictation.

Press the dictation key (F5) → speak → press it again. Your speech is transcribed
on-device by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and pasted
into whatever field is focused. **No audio ever leaves your machine** — unlike the
built-in Dictation, which streams to Apple, and Chrome's speech API, which streams
to Google.

- 🔒 100% offline / private — mic audio is recorded to a temp file, transcribed, deleted
- 🎯 Uses `large-v3-turbo` by default — noticeably more accurate than macOS Dictation
- ⌨️ Remaps the **bare F5/dictation key** — no new shortcut to remember
- 🪶 ~120 lines of Lua on top of tools you probably already have

## How it works

```
F5 / dictation key ──(Karabiner)──▶ F18 ──(Hammerspoon)──▶ toggle
   start:  ffmpeg records the mic → /tmp/whisper-dictate.wav
   stop:   whisper-cli transcribes the wav → text → pasted into the focused app
```

[Hammerspoon](https://www.hammerspoon.org/) owns the record/transcribe/paste logic and
the record-toggle state. [Karabiner-Elements](https://karabiner-elements.pqrs.org/) is
only needed to make the *bare* dictation key trigger it — that key fires a special HID
event that Hammerspoon can't catch on its own, so Karabiner remaps it to the unused F18,
which Hammerspoon binds. An `⌥Space` fallback is bound too, so you can try it before
touching Karabiner.

## Requirements

- macOS (Apple Silicon paths assume Homebrew at `/opt/homebrew`)
- [Homebrew](https://brew.sh)
- `ffmpeg` and `whisper-cli` — `brew install ffmpeg whisper-cpp`
- [Hammerspoon](https://www.hammerspoon.org/) — `brew install --cask hammerspoon`
- A ggml Whisper model (the installer fetches `large-v3-turbo-q5_0`, ~550 MB)
- *(optional, for the F5 key)* [Karabiner-Elements](https://karabiner-elements.pqrs.org/) — `brew install --cask karabiner-elements`

## Install

```sh
git clone https://github.com/bath-tub/whisper-dictation
cd whisper-dictation
./install.sh
```

`install.sh` checks the tools above, downloads the model to `~/.cache/whisper/` if
missing, copies `whisper-dictation.lua` into `~/.hammerspoon/`, wires up
`require("whisper-dictation")` in your `init.lua`, and drops the Karabiner rule into
`~/.config/karabiner/assets/complex_modifications/`. Then finish the manual steps below.

### Manual steps (macOS gates these — no script can click them for you)

1. **Hammerspoon permissions** — System Settings → Privacy & Security:
   - **Microphone** → enable Hammerspoon (so ffmpeg can record)
   - **Accessibility** → enable Hammerspoon (so it can paste)
   Then reload Hammerspoon (menu-bar icon → Reload Config). Test with `⌥Space`.

2. **Karabiner** (for the F5 key):
   - Launch Karabiner-Elements and approve its driver / system extension + grant
     **Input Monitoring** when prompted (a one-time system-extension approval).
   - Settings → **Complex Modifications** → **Add rule** → enable
     *"F5 / Dictation key → F18"*.
   - Verify the key code: open **Karabiner-EventViewer**, press your dictation key.
     If it shows `f5`, you're done. If it shows something else (some keyboards report
     a different code), edit `key_code` in `karabiner/whisper-dictation.json` to match
     and re-import.

3. *(optional)* Turn **off** the built-in Dictation in System Settings → Keyboard →
   Dictation, so the old cloud version never fires.

## Customize

Edit the config block at the top of `whisper-dictation.lua`:

| setting   | default                                   | notes |
|-----------|-------------------------------------------|-------|
| `MODEL`   | `~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin` | any ggml model; smaller = faster/less accurate |
| `MIC`     | `":0"`                                    | avfoundation device index; run `ffmpeg -f avfoundation -list_devices true -i ""` to list |
| `LANG`    | `"en"`                                    | or `"auto"` |
| `HOTKEYS` | `{{}, "f18"}`, `{{"alt"}, "space"}`       | add/replace toggle hotkeys |

Reload Hammerspoon after editing.

## Notes / limitations

- **Batch, not live** — text appears a second or two after you stop, not word-by-word
  while speaking. That's the tradeoff for running a real model locally.
- Pasting uses the clipboard (Cmd+V) and restores your previous clipboard contents
  right after. A handful of secure fields block programmatic paste.
- Paths assume Apple-Silicon Homebrew (`/opt/homebrew`); adjust for Intel (`/usr/local`).

## License

MIT — see [LICENSE](LICENSE).
