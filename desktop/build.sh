#!/bin/bash
# Builds Buddy.app from source. Pass --install to put it in ~/Applications and start it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Run: xcode-select --install  (Apple's free Command Line Tools), then try again." >&2
  exit 2
fi

BUILD="${BUDDY_BUILD_DIR:-$(mktemp -d)}"
APP="$BUILD/Buddy.app"
rm -rf "$APP" "$BUILD/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/AppIcon.iconset"

swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI \
  -o "$APP/Contents/MacOS/Buddy" "$HERE/Buddy.swift"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# App icon, drawn by Buddy itself
"$APP/Contents/MacOS/Buddy" --render-icon "$BUILD/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Buddy.app"
  if [[ -d "$DEST" ]]; then
    ID=$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    if [[ "$ID" != "local.buddy.desktop-pet" ]]; then
      echo "Refusing to replace $DEST: it is not Buddy." >&2
      exit 1
    fi
    pkill -x Buddy 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST"
  fi
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and started $DEST"
fi
