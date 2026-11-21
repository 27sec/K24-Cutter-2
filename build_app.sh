#!/bin/zsh
# Builds "K24 Cutter 2.app" (release) into ./dist
set -e
cd "$(dirname "$0")"
swift build -c release
APP="dist/K24 Cutter 2.app"
rm -rf "dist/K24 Cutter.app"   # old name
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/K24Cutter "$APP/Contents/MacOS/K24Cutter"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional: bundle ffmpeg/ffprobe so the app works without Homebrew
#   cp "$(which ffmpeg)" "$(which ffprobe)" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>K24 Cutter 2</string>
  <key>CFBundleDisplayName</key><string>K24 Cutter 2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.k24.cutter</string>
  <key>CFBundleExecutable</key><string>K24Cutter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Video</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>CFBundleTypeExtensions</key><array>
      <string>ts</string><string>m2ts</string><string>mts</string><string>m2t</string>
      <string>mp4</string><string>m4v</string><string>mkv</string><string>mov</string><string>mpg</string>
    </array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
