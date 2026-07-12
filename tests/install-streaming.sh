#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisper-dictation-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home"

cat >"$TMP/bin/uname" <<'MOCK'
#!/usr/bin/env bash
echo Darwin
MOCK

cat >"$TMP/bin/brew" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BREW_LOG"
# Homebrew subprocesses may read inherited stdin. Deliberately do so here to
# reproduce the failure mode of a curl-streamed installer.
if IFS= read -r line; then
  printf 'consumed: %s\n' "$line" >>"$BREW_STDIN_LOG"
  cat >/dev/null
fi
MOCK

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      dest="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */whisper-dictation.lua)
    cp "$REPO_ROOT/whisper-dictation.lua" "$dest"
    ;;
  */karabiner/whisper-dictation.json)
    cp "$REPO_ROOT/karabiner/whisper-dictation.json" "$dest"
    ;;
  */ggml-large-v3-turbo-q5_0.bin)
    : >"$dest"
    ;;
  *)
    echo "Unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
MOCK

for command in open killall sleep; do
  cat >"$TMP/bin/$command" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
done
chmod +x "$TMP/bin/"*

: >"$TMP/brew.log"
: >"$TMP/brew-stdin.log"

# Feed the script slowly so Bash cannot buffer the whole installer before a
# child process gets a chance to steal the pipe. This makes the regression
# deterministic instead of dependent on pipe-buffer timing.
stream_installer() {
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    /bin/sleep 0.003
  done <"$ROOT/install.sh"
}

output="$({ stream_installer; } | env \
  PATH="$TMP/bin:/usr/bin:/bin" \
  HOME="$TMP/home" \
  BREW_LOG="$TMP/brew.log" \
  BREW_STDIN_LOG="$TMP/brew-stdin.log" \
  REPO_ROOT="$ROOT" \
  bash 2>&1)"

if [ -s "$TMP/brew-stdin.log" ]; then
  echo "FAIL: a Homebrew command consumed the streamed installer:" >&2
  cat "$TMP/brew-stdin.log" >&2
  exit 1
fi

for invocation in \
  "install ffmpeg" \
  "install whisper-cpp" \
  "install --cask hammerspoon" \
  "install --cask karabiner-elements"; do
  if ! grep -Fxq "$invocation" "$TMP/brew.log"; then
    echo "FAIL: missing Homebrew invocation: $invocation" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

for artifact in \
  "$TMP/home/.cache/whisper/ggml-large-v3-turbo-q5_0.bin" \
  "$TMP/home/.hammerspoon/whisper-dictation.lua" \
  "$TMP/home/.config/karabiner/assets/complex_modifications/whisper-dictation.json"; do
  if [ ! -f "$artifact" ]; then
    echo "FAIL: installer did not create $artifact" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

grep -Fq 'Installed. Three things macOS makes you click yourself:' <<<"$output"
echo "PASS: streamed installer survives child processes reading stdin"
