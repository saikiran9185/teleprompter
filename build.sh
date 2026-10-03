#!/bin/bash
# Build Teleprompter.app.   ./build.sh            -> build/Teleprompter.app
#                          ./build.sh --install  -> also copy to /Applications and open it
#                          ./build.sh --zip      -> also make build/Teleprompter.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0
APP=build/Teleprompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/Teleprompter-arm64"
swiftc -swift-version 5 -O -parse-as-library -target x86_64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/Teleprompter-x86_64"
lipo -create "$APP/Contents/MacOS/Teleprompter-arm64" "$APP/Contents/MacOS/Teleprompter-x86_64" -output "$APP/Contents/MacOS/Teleprompter"
rm "$APP/Contents/MacOS/Teleprompter-arm64" "$APP/Contents/MacOS/Teleprompter-x86_64"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.saikiran.Teleprompter</string>
  <key>CFBundleName</key><string>Teleprompter</string>
  <key>CFBundleDisplayName</key><string>Teleprompter</string>
  <key>CFBundleExecutable</key><string>Teleprompter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Teleprompter records your voice-over takes.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Teleprompter listens while you read so the next word lights up, and checks each take word by word. Recognition runs on your Mac when available.</string>
</dict></plist>
PLIST

# A real signing identity keeps the microphone/speech permissions across rebuilds; otherwise sign ad hoc.
# Release zips (--zip) are signed ad hoc so no personal certificate details ship inside the public download.
IDENTITY=""
if [[ "${1:-}" != "--zip" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--zip" ]]; then
  (cd build && rm -f Teleprompter.zip && ditto -c -k --keepParent Teleprompter.app Teleprompter.zip)
  echo "Release zip: build/Teleprompter.zip"
fi
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Teleprompter || true
  rm -rf /Applications/Teleprompter.app
  cp -R "$APP" /Applications/
  open /Applications/Teleprompter.app
  echo "Installed /Applications/Teleprompter.app"
fi
