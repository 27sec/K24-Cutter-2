#!/bin/zsh
# Builds "K24 Cutter 2.app" (release) into ./dist and installs it to /Applications
#   ./build_app.sh               build + install (quits a running copy, relaunches it)
#   ./build_app.sh --no-install  build only
#   ./build_app.sh --universal   universal binary (Apple Silicon + Intel)
#   ./build_app.sh --release     universal + zip for GitHub (dist/K24-Cutter-2-v<ver>-macOS.zip), no install
# Flags can be combined.
set -e
VERSION="1.1"
BUILD="2"
INSTALL=1
UNIVERSAL=0
ZIP=0
for a in "$@"; do
  case "$a" in
    --no-install) INSTALL=0 ;;
    --universal)  UNIVERSAL=1 ;;
    --release)    UNIVERSAL=1; ZIP=1; INSTALL=0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
cd "$(dirname "$0")"
if (( UNIVERSAL )); then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/K24Cutter"
APP="dist/K24 Cutter 2.app"
rm -rf "dist/K24 Cutter.app"   # old name
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/K24Cutter"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
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
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/K24Cutter"))"

if (( ZIP )); then
  ZIPFILE="dist/K24-Cutter-2-v$VERSION-macOS.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPFILE"
  echo "Zipped: $ZIPFILE"
fi

if (( INSTALL )); then
  DEST="/Applications/K24 Cutter 2.app"
  WAS_RUNNING=0
  if pgrep -f "$DEST/Contents/MacOS/K24Cutter" >/dev/null; then
    WAS_RUNNING=1
    osascript -e 'tell application id "local.k24.cutter" to quit' >/dev/null 2>&1 || true
    for i in {1..20}; do pgrep -f "$DEST/Contents/MacOS/K24Cutter" >/dev/null || break; sleep 0.25; done
    pkill -f "$DEST/Contents/MacOS/K24Cutter" 2>/dev/null || true
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
  echo "Installed: $DEST"
  if (( WAS_RUNNING )); then open "$DEST"; echo "Relaunched"; fi
fi
