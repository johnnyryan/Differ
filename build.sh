#!/bin/zsh
# Builds "Differ.app" (universal) into ./build.
# Ad-hoc signed by default; set SIGN_ID to a "Developer ID Application" identity for distribution.
set -euo pipefail
cd "${0:A:h}"

APP="build/Differ.app"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  echo "Compiling $arch…"
  swiftc -O -parse-as-library -target $arch-apple-macos14.0 Sources/*.swift -o build/obj/Differ-$arch
done
lipo -create build/obj/Differ-arm64 build/obj/Differ-x86_64 -output "$APP/Contents/MacOS/Differ"

echo "Making icon…"
ICONSET=build/obj/AppIcon.iconset
mkdir -p $ICONSET
swift Tools/make_icon.swift build/obj/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/obj/icon_1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/obj/icon_1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Differ</string>
  <key>CFBundleDisplayName</key><string>Differ</string>
  <key>CFBundleIdentifier</key><string>io.github.johnnyryan.differ</string>
  <key>CFBundleExecutable</key><string>Differ</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.1</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>NSHumanReadableCopyright</key><string>Differ. Johnny Ryan 2026</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Web Location</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.apple.web-internet-location</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
else
  codesign --force --options runtime -s - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
