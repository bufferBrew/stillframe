#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
mkdir -p .build/cache .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache"
APP="$PWD/Stillframe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stillframe "$APP/Contents/MacOS/Stillframe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Stillframe</string>
<key>CFBundleDisplayName</key><string>Stillframe</string>
<key>CFBundleIdentifier</key><string>dev.bufferbrew.stillframe</string>
<key>CFBundleExecutable</key><string>Stillframe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Stillframe captures screenshots and screen recordings when you request them.</string>
<key>NSAudioCaptureUsageDescription</key><string>Stillframe optionally includes system audio in your screen recordings.</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Image</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSItemContentTypes</key><array><string>public.image</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
