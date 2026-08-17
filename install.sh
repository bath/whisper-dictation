#!/usr/bin/env bash
# whisper-dictation installer.
# Run it either way:
#   curl -fsSL https://raw.githubusercontent.com/bath/whisper-dictation/main/install.sh | bash
#   ./install.sh            (from a local clone)
#
# Does everything that CAN be automated: installs deps via Homebrew, downloads the
# Whisper model, builds the native recorder, drops the configs, and restarts Hammerspoon.
# It CANNOT grant macOS permissions (Microphone/Accessibility/driver approval) —
# those are user-gated by macOS and printed as manual steps at the end.
set -euo pipefail

RAW="https://raw.githubusercontent.com/bath/whisper-dictation/main"
MODEL_DIR="$HOME/.cache/whisper"
MODEL="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
HS_DIR="$HOME/.hammerspoon"
RECORDER_SRC="$HS_DIR/WhisperRecorder.swift"
RECORDER_DIR="$HS_DIR/bin"
RECORDER="$RECORDER_DIR/whisper-recorder"
KB_DIR="$HOME/.config/karabiner/assets/complex_modifications"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-/Applications}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
# When this installer is streamed via `curl | bash`, its source code is stdin.
# Never let Homebrew or one of its subprocesses consume the rest of the script.
brew_install() { brew install "$@" </dev/null; }

# Use local files if run from a clone; otherwise download them.
SELF="${BASH_SOURCE[0]:-}"
SRC_DIR=""
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/whisper-dictation.lua" ]; then
  SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi
fetch() { # <repo-relative-path> <dest>
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "$2"
  else curl -fsSL "$RAW/$1" -o "$2"; fi
}

[ "$(uname)" = "Darwin" ] || { echo "This is macOS-only."; exit 1; }

say "Homebrew"
if ! have brew; then
  echo "Homebrew is required. Install it from https://brew.sh then re-run:"
  echo '  curl -fsSL '"$RAW"'/install.sh | bash'
  exit 1
fi
echo "  ok"

say "Command-line tools (whisper-server, Swift compiler)"
have whisper-server || { echo "  installing whisper-cpp"; brew_install whisper-cpp; }
have xcrun && xcrun --find swiftc >/dev/null 2>&1 || {
  echo "Apple Command Line Tools are required. Run: xcode-select --install"
  exit 1
}
echo "  ok"

say "Apps (Hammerspoon, Karabiner-Elements)"
# Casks may prompt for your password (Karabiner installs a system driver).
[ -d "$APPLICATIONS_DIR/Hammerspoon.app" ]        || { echo "  installing hammerspoon";        brew_install --cask hammerspoon; }
[ -d "$APPLICATIONS_DIR/Karabiner-Elements.app" ] || { echo "  installing karabiner-elements"; brew_install --cask karabiner-elements; }
echo "  ok"

say "Whisper model (~550 MB)"
if [ -f "$MODEL" ]; then echo "  already present"; else
  mkdir -p "$MODEL_DIR"
  curl -fL --progress-bar "$MODEL_URL" -o "$MODEL"
fi

say "Hammerspoon config"
mkdir -p "$HS_DIR"
fetch "whisper-dictation.lua" "$HS_DIR/whisper-dictation.lua"
fetch "recorder/WhisperRecorder.swift" "$RECORDER_SRC"
mkdir -p "$RECORDER_DIR"
xcrun swiftc -O \
  -framework AudioToolbox \
  -framework AudioUnit \
  -framework CoreAudio \
  "$RECORDER_SRC" -o "$RECORDER" </dev/null
touch "$HS_DIR/init.lua"
if ! grep -q 'require("whisper-dictation")' "$HS_DIR/init.lua"; then
  printf '\nrequire("whisper-dictation")\n' >> "$HS_DIR/init.lua"
fi
echo "  installed + native recorder built → $HS_DIR"

say "Karabiner rule (F5 / dictation key → F18)"
mkdir -p "$KB_DIR"
fetch "karabiner/whisper-dictation.json" "$KB_DIR/whisper-dictation.json"
echo "  rule file installed → $KB_DIR"
echo "  IMPORTANT: Karabiner does not enable imported rules automatically."

say "Restarting Hammerspoon"
killall Hammerspoon >/dev/null 2>&1 || true
sleep 1; open -a Hammerspoon
open -a Karabiner-Elements >/dev/null 2>&1 || true

echo
bold "✅ Files installed — setup is not complete until you click these three things:"
cat <<'STEPS'

  1. Hammerspoon permissions — System Settings → Privacy & Security:
       • Microphone    → enable Hammerspoon
       • Accessibility → enable Hammerspoon

  2. Karabiner-Elements (just opened):
       • Approve its driver / system extension + grant Input Monitoring when asked
       • Settings → Complex Modifications → Add rule → enable "F5 / Dictation key → F18"
       • If F5 asks you to enable Apple's Dictation, this rule is still not enabled

  3. (optional) System Settings → Keyboard → Dictation → Off
       so Apple's cloud dictation never fires on that key.

Then click into any text field, press F5, talk, press F5 again — your words appear.
Quick test: ⌥Space should toggle recording even before the Karabiner rule is enabled.
No F5 key / skipping Karabiner? ⌥Space works too (needs only step 1).
STEPS
