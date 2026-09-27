#!/usr/bin/env bash
#
# record-demos.sh — records the README demo GIFs.
#
# Runs each scripted walkthrough in OnsideTVUITests on a Simulator, records
# just the part between the test's DEMO_READY and DEMO_DONE markers, and turns
# every clip into a GIF in docs/demo/. The raw MP4s are kept in build/demo/
# (ignored by git) for editing in Screen Studio or iMovie.
#
# Usage:
#   ./record-demos.sh                 # all four clips
#   ./record-demos.sh home watch      # just some of them
#   DEVICE="iPhone 17" ./record-demos.sh
#
# Needs Xcode and ffmpeg (brew install ffmpeg).

set -euo pipefail
cd "$(dirname "$0")"

PROJECT="OnsideTV.xcodeproj"
SCHEME="OnsideTV"
TEST_CLASS="OnsideTVUITests/OnsideTVDemoTests"
# Build products go OUTSIDE the project folder. A project on the Desktop or in
# Documents is usually synced by iCloud, which tags new files with extended
# attributes — and codesign refuses to sign an app containing them
# ("Command CodeSign failed ... resource fork, Finder information, or similar
# detritus not allowed").
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/OnsideTV-Demo"
RAW_DIR="build/demo"
GIF_DIR="docs/demo"
GIF_WIDTH="${GIF_WIDTH:-320}"
GIF_FPS="${GIF_FPS:-15}"
MAX_GIF_MB="${MAX_GIF_MB:-8}"

# clip name -> test method
clip_test() {
  case "$1" in
    home)   echo "testDemo1_Home" ;;
    watch)  echo "testDemo2_Watch" ;;
    search) echo "testDemo3_Search" ;;
    sports) echo "testDemo4_Sports" ;;
    *) return 1 ;;
  esac
}

CLIPS=("$@")
[ ${#CLIPS[@]} -eq 0 ] && CLIPS=(home watch search sports)
for c in "${CLIPS[@]}"; do
  clip_test "$c" >/dev/null || { echo "Unknown clip '$c' (use: home watch search sports)"; exit 1; }
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*"; }

# ── Tools ──────────────────────────────────────────────────────────────────
command -v xcodebuild >/dev/null || { echo "Xcode is required."; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg"; exit 1; }

# ── Pick a Simulator ───────────────────────────────────────────────────────
if [ -n "${SIM_UDID:-}" ]; then
  UDID="$SIM_UDID"
else
  WANT="${DEVICE:-}"
  LIST="$(xcrun simctl list devices available)"
  if [ -n "$WANT" ]; then
    LINE="$(echo "$LIST" | grep -F "    $WANT (" | head -1 || true)"
  else
    # Prefer a current Pro (not Max) iPhone, then any iPhone.
    LINE="$(echo "$LIST" | grep -E '^ +iPhone [0-9]+ Pro \(' | tail -1 || true)"
    [ -z "$LINE" ] && LINE="$(echo "$LIST" | grep -E '^ +iPhone ' | tail -1 || true)"
  fi
  [ -z "$LINE" ] && { echo "No matching iPhone simulator found. Install one in Xcode → Settings → Components."; exit 1; }
  UDID="$(echo "$LINE" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
  say "Using $(echo "$LINE" | sed -E 's/^ +//; s/ \(.*//') ($UDID)"
fi

# ── Check the demo streams are reachable ───────────────────────────────────
say "Checking demo streams"
STREAMS=$(grep -oE '"https://[^"]+\.m3u8"' OnsideTV/Utilities/DemoMode.swift | tr -d '"')
for url in $STREAMS; do
  if curl -sfIL -m 8 "$url" >/dev/null 2>&1 || curl -sfL -m 8 -r 0-200 "$url" -o /dev/null 2>&1; then
    echo "  ok    $url"
  else
    warn "down  $url  (swap it in DemoMode.swift → Stream if its channel shows an error)"
  fi
done

# ── Prepare the Simulator ──────────────────────────────────────────────────
say "Booting and preparing the Simulator"
# Software keyboard on screen, so typing in the search clip is visible.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

cleanup() {
  [ -n "${REC_PID:-}" ] && kill -INT "$REC_PID" 2>/dev/null || true
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
}
trap cleanup EXIT

# ── Build once ─────────────────────────────────────────────────────────────
# Strip iCloud/Finder attributes from the sources for the same codesign reason,
# and drop the old in-project build folder from earlier versions of this script.
xattr -cr OnsideTV OnsideTVWidget OnsideTVUITests 2>/dev/null || true
rm -rf build/DemoDerivedData
say "Building the app and UI tests (first run takes a few minutes)"
xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -quiet

mkdir -p "$RAW_DIR" "$GIF_DIR"

# ── Record each clip ───────────────────────────────────────────────────────
record_clip() {
  local name="$1" test mp4 started=0
  test="$(clip_test "$name")"
  mp4="$RAW_DIR/$name.mp4"
  rm -f "$mp4"
  REC_PID=""

  say "Recording '$name'"
  # NSUnbufferedIO makes xcodebuild pass the test's output through line by
  # line, which is what lets the markers start and stop the recording on time.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      *DEMO_READY*)
        xcrun simctl io "$UDID" recordVideo --codec h264 --force "$mp4" >/dev/null 2>&1 &
        REC_PID=$!
        started=1
        echo "  ● recording"
        ;;
      *DEMO_DONE*)
        if [ -n "$REC_PID" ]; then
          kill -INT "$REC_PID" 2>/dev/null || true
          wait "$REC_PID" 2>/dev/null || true
          REC_PID=""
          echo "  ■ stopped"
        fi
        ;;
      *"error:"*|*"failed"*|*"XCTAssert"*)
        echo "  $line"
        ;;
    esac
  done < <(NSUnbufferedIO=YES xcodebuild test-without-building \
             -project "$PROJECT" -scheme "$SCHEME" \
             -destination "id=$UDID" -derivedDataPath "$DERIVED" \
             -only-testing:"$TEST_CLASS/$test" 2>&1)

  # Test ended without its DONE marker (a failure) — stop what we have.
  if [ -n "${REC_PID:-}" ]; then
    kill -INT "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
    REC_PID=""
  fi

  if [ "$started" -eq 0 ] || [ ! -s "$mp4" ]; then
    warn "'$name' produced no video — run the test from Xcode to see why."
    return 0
  fi

  make_gif "$name"
}

make_gif() {
  local name="$1" mp4="$RAW_DIR/$1.mp4" gif="$GIF_DIR/$1.gif" width="$GIF_WIDTH" fps="$GIF_FPS"
  while :; do
    ffmpeg -loglevel error -y -i "$mp4" \
      -vf "fps=$fps,scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
      "$gif"
    local mb=$(( $(stat -f%z "$gif") / 1048576 ))
    if [ "$mb" -lt "$MAX_GIF_MB" ] || [ "$width" -le 240 ]; then
      echo "  → $gif (${mb} MB, ${width}px, ${fps}fps)"
      break
    fi
    width=$(( width - 40 )); fps=12
    echo "  $gif is ${mb} MB — retrying smaller"
  done
}

for c in "${CLIPS[@]}"; do record_clip "$c"; done

say "Done"
echo "GIFs:        $GIF_DIR/"
echo "Raw videos:  $RAW_DIR/  (for Screen Studio / device frames)"
echo "Commit the GIFs:  git add $GIF_DIR && git commit -m 'Add demo GIFs'"
