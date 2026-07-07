#!/usr/bin/env bash
# Install whisper-dictation: check deps, fetch the model, wire up Hammerspoon + Karabiner.
# Safe to re-run. Does NOT touch macOS permissions — see the README for those.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$HOME/.cache/whisper"
MODEL="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
HS_DIR="$HOME/.hammerspoon"
KB_DIR="$HOME/.config/karabiner/assets/complex_modifications"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Checking dependencies"
missing=()
have ffmpeg      || missing+=("ffmpeg (brew install ffmpeg)")
have whisper-cli || missing+=("whisper-cli (brew install whisper-cpp)")
[ -d /Applications/Hammerspoon.app ] || missing+=("Hammerspoon (brew install --cask hammerspoon)")
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'Missing:\n'; printf '  - %s\n' "${missing[@]}"
  echo "Install the above, then re-run ./install.sh"; exit 1
fi
if [ ! -d /Applications/Karabiner-Elements.app ]; then
  echo "  (optional) Karabiner-Elements not found — needed for the F5 key remap."
  echo "             brew install --cask karabiner-elements"
fi

say "Whisper model"
if [ -f "$MODEL" ]; then
  echo "  already present: $MODEL"
else
  mkdir -p "$MODEL_DIR"
  echo "  downloading (~550 MB) → $MODEL"
  curl -fL --progress-bar "$MODEL_URL" -o "$MODEL"
fi

say "Hammerspoon config"
mkdir -p "$HS_DIR"
cp "$REPO/whisper-dictation.lua" "$HS_DIR/whisper-dictation.lua"
echo "  copied whisper-dictation.lua → $HS_DIR"
touch "$HS_DIR/init.lua"
if ! grep -q 'require("whisper-dictation")' "$HS_DIR/init.lua"; then
  printf '\nrequire("whisper-dictation")\n' >> "$HS_DIR/init.lua"
  echo "  added require(\"whisper-dictation\") to init.lua"
else
  echo "  init.lua already loads whisper-dictation"
fi

say "Karabiner rule"
mkdir -p "$KB_DIR"
cp "$REPO/karabiner/whisper-dictation.json" "$KB_DIR/whisper-dictation.json"
echo "  copied rule → $KB_DIR"

cat <<'DONE'

==> Done. Remaining MANUAL steps (macOS gates these):
  1. System Settings → Privacy & Security:
       Microphone    → enable Hammerspoon
       Accessibility → enable Hammerspoon
     Then reload Hammerspoon (menu-bar icon → Reload Config). Try it with ⌥Space.
  2. For the F5 key: launch Karabiner-Elements, approve its driver + Input Monitoring,
     then Settings → Complex Modifications → Add rule → enable
     "F5 / Dictation key → F18". Verify the key with Karabiner-EventViewer (see README).
DONE
