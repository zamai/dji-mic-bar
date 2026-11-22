#!/bin/sh
# Builds DJIMicBar.app with libusb statically linked (needs: brew install libusb).
#   ./build.sh             build only
#   ./build.sh --install   build, replace the copy in /Applications and start it
set -e
case "${1:-}" in
  ""|--install) ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")"
APP=build/DJIMicBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BREW=$(brew --prefix)
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridge.h -I "$BREW/include/libusb-1.0" \
  Sources/*.swift "$BREW/lib/libusb-1.0.a" \
  -framework IOKit -framework CoreFoundation -framework Security -lobjc \
  -o "$APP/Contents/MacOS/DJIMicBar"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = --install ]; then
  DEST="/Applications/DJI Mic Bar.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
  # Let the running copy release the receiver before replacing it.
  pkill -x -U "$(id -u)" DJIMicBar || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x -U "$(id -u)" DJIMicBar >/dev/null || break
    sleep 0.3
  done
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Same bundle id as the build copy, so register only the installed one.
  "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST"
  open "$DEST"
  echo "installed and started $DEST"
fi
