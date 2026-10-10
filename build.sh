#!/bin/zsh
# Build Headroom.app.
#   ./build.sh            build into build/
#   ./build.sh --install  build, install to /Applications and (re)launch
set -euo pipefail
cd "${0:A:h}"

APP=build/Headroom.app
rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources} build/tmp

swiftc -O -parse-as-library -target arm64-apple-macos26.0 Sources/*.swift -o $APP/Contents/MacOS/Headroom

if [[ ! -f build/icon/Headroom.icns || icon/render.swift -nt build/icon/Headroom.icns ]]; then
  mkdir -p build/icon/Headroom.iconset
  swiftc -O icon/render.swift -o build/tmp/render-icon
  build/tmp/render-icon build/icon/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon/icon.png --out build/icon/Headroom.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon/icon.png --out build/icon/Headroom.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon/Headroom.iconset -o build/icon/Headroom.icns
fi
cp build/icon/Headroom.icns $APP/Contents/Resources/

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.yask.headroom</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Yask Srivastava</string>
</dict></plist>
PLIST

# A stable identity keeps the keychain item and the login item across rebuilds.
# Uses your first Apple Development certificate if you have one, otherwise signs ad hoc.
IDENTITY=${HEADROOM_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"')}
codesign --force --sign "${IDENTITY:--}" --identifier com.yask.headroom $APP 2>/dev/null \
  || codesign --force --sign - --identifier com.yask.headroom $APP

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Headroom 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Headroom.app && cp -R $APP /Applications/Headroom.app
  open /Applications/Headroom.app
  echo "Headroom installed and running."
fi
