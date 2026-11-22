#!/bin/bash
# Builds TabLite.app (universal: Intel + Apple Silicon, targets macOS 10.15+)
set -euo pipefail
cd "$(dirname "$0")"

APP=TabLite.app
VERSION=1.0.1
BUILD_NUMBER=2
rm -rf "$APP" .build && mkdir -p "$APP/Contents/MacOS" .build

for arch in x86_64 arm64; do
  # ScreenCaptureKit is weak-linked so the app still launches on macOS 10.15–12.2, where it doesn't exist.
  swiftc -O -swift-version 5 -target "$arch-apple-macos10.15" main.swift -o ".build/TabLite-$arch" -suppress-warnings \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit
done
lipo -create .build/TabLite-x86_64 .build/TabLite-arm64 -output "$APP/Contents/MacOS/TabLite"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate with: swift icon/make_icon.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TabLite</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.lucifix.tablite</string>
  <key>CFBundleName</key><string>TabLite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

# Sign with a stable self-signed cert so macOS keeps the Accessibility / Screen Recording
# permissions across rebuilds. Falls back to ad-hoc (permissions reset every build).
IDENTITY="${TABLITE_SIGN:-TabLite Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with '$IDENTITY'"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "warning: no '$IDENTITY' certificate found, ad-hoc signed (permissions reset on every rebuild)"
fi
echo "Built $APP $VERSION — run: open $APP"

# ./build.sh --zip  →  dist/TabLite-<version>.zip for a GitHub release (ditto keeps the signature intact)
if [ "${1:-}" = "--zip" ]; then
  mkdir -p dist
  ditto -c -k --keepParent "$APP" "dist/TabLite-$VERSION.zip"
  echo "Packaged dist/TabLite-$VERSION.zip"
fi
