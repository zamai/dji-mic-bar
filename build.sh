#!/bin/sh
# Builds DJIMicBar.app with libusb statically linked (needs: brew install libusb).
set -e
cd "$(dirname "$0")"
APP=build/DJIMicBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
BREW=$(brew --prefix)
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridge.h -I "$BREW/include/libusb-1.0" \
  Sources/*.swift "$BREW/lib/libusb-1.0.a" \
  -framework IOKit -framework CoreFoundation -framework Security -lobjc \
  -o "$APP/Contents/MacOS/DJIMicBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
