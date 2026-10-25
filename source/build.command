#!/bin/zsh
set -eu
cd "$(dirname "$0")"
app="../Luma.app"
compile_arch=()
minimum="12.0"
if [[ "${1:-}" == "--universal" ]]; then
  compile_arch=(-arch arm64 -arch x86_64)
  minimum="14.0"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="assets/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -f "$app/Contents/Resources/SidebarLamp.png" "$app/Contents/Resources/"menu_*.png(N) "$app/Contents/Resources/"icon_*_off.png(N)
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter "${compile_arch[@]}" -mmacosx-version-min="$minimum" main.m -framework Cocoa -framework Carbon -framework IOKit -framework UniformTypeIdentifiers -framework AVFoundation -framework ApplicationServices -o "$app/Contents/MacOS/Luma"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Luma</string>
<key>CFBundleIdentifier</key><string>local.barlight.usb</string>
<key>CFBundleName</key><string>Luma</string>
<key>CFBundleDisplayName</key><string>Luma</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.12</string>
<key>CFBundleVersion</key><string>27</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>读取相机使用状态以联动视频灯光，不采集画面。</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
