#!/bin/bash
# Builds DroidFinder.app in this folder. Run ./build.sh --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=DroidFinder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: build each architecture in turn (both land in .build/release), then merge.
BIN=$(mktemp -d)
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0"
  cp .build/release/DroidFinder "$BIN/DroidFinder-$arch"
done
lipo -create "$BIN/DroidFinder-arm64" "$BIN/DroidFinder-x86_64" -output "$APP/Contents/MacOS/DroidFinder"

# Bundle libmtp + libusb (for File transfer mode) so people don't need Homebrew for it.
# The app opens them at runtime and falls back to Homebrew's copies if these are missing.
if MTP_PREFIX=$(brew --prefix libmtp 2>/dev/null) && [[ -f "$MTP_PREFIX/lib/libmtp.9.dylib" ]]; then
  FW="$APP/Contents/Frameworks"
  mkdir -p "$FW"
  USB_LIB=$(otool -L "$MTP_PREFIX/lib/libmtp.9.dylib" | awk '/libusb/ {print $1}')
  cp "$MTP_PREFIX/lib/libmtp.9.dylib" "$FW/"
  cp "$USB_LIB" "$FW/libusb-1.0.0.dylib"
  chmod u+w "$FW"/*.dylib
  install_name_tool -id @rpath/libmtp.9.dylib "$FW/libmtp.9.dylib" 2>/dev/null
  install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib" 2>/dev/null
  install_name_tool -change "$USB_LIB" @loader_path/libusb-1.0.0.dylib "$FW/libmtp.9.dylib" 2>/dev/null
else
  echo "note: libmtp not found (brew install libmtp) — building without File transfer support bundled"
fi

# App icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
cp Resources/AppIcon.png "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DroidFinder</string>
  <key>CFBundleDisplayName</key><string>DroidFinder</string>
  <key>CFBundleIdentifier</key><string>com.akhil.droidfinder</string>
  <key>CFBundleExecutable</key><string>DroidFinder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.2</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit politely so the app can close its session with the phone.
  osascript -e 'quit app "DroidFinder"' 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x DroidFinder >/dev/null || break; sleep 1; done
  pkill -x DroidFinder || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/$APP"
fi
