#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/Beauty 注册助手.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/BeautyRegistration" "$app_dir/Contents/MacOS/BeautyRegistration"
for bundle in "$binary_dir"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$app_dir/Contents/Resources/"
done
swift scripts/make-icon.swift "$project_dir/.build/Beauty.iconset"
iconutil -c icns "$project_dir/.build/Beauty.iconset" -o "$app_dir/Contents/Resources/Beauty.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BeautyRegistration</string>
<key>CFBundleIdentifier</key><string>local.beauty.registration</string>
<key>CFBundleName</key><string>Beauty 注册助手</string>
<key>CFBundleDisplayName</key><string>Beauty 注册助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Beauty.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.31</string>
<key>CFBundleVersion</key><string>32</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
printf '\nBuilt: %s\n' "$app_dir"
