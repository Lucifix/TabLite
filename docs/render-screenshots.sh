#!/bin/bash
# Renders docs/screenshot.html into docs/screenshot-dark.jpg and docs/screenshot-light.jpg
# using any installed Chromium-based browser in headless mode.
set -euo pipefail
cd "$(dirname "$0")"

for b in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [ -x "$b" ] && BROWSER="$b" && break
done
: "${BROWSER:?No Chromium-based browser found}"

PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
for theme in dark light; do
  "$BROWSER" --headless=new --user-data-dir="$PROFILE" --no-first-run --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=1440,900 --virtual-time-budget=1500 \
    --screenshot="$PROFILE/shot.png" "file://$PWD/screenshot.html#$theme" 2>/dev/null
  # JPEG keeps the gradients smooth at a fraction of the PNG size.
  sips -s format jpeg -s formatOptions 88 "$PROFILE/shot.png" --out "$PWD/screenshot-$theme.jpg" >/dev/null
  echo "Wrote docs/screenshot-$theme.jpg"
done
