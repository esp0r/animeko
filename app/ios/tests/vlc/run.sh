#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
pod install
arch=$(uname -m)
framework=$(find Pods/MobileVLCKit/MobileVLCKit.xcframework -name MobileVLCKit.framework -path '*simulator*' | head -1)
test -n "$framework"
app="$PWD/build/VlcHarness.app"
mkdir -p "$app"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -D VLC_TESTING -sdk "$sdk" -target "${arch}-apple-ios16.0-simulator" \
  -F "$(dirname "$framework")" -framework MobileVLCKit \
  -framework UIKit -framework AVFoundation -framework AudioToolbox \
  -framework VideoToolbox -framework CoreMedia -framework CFNetwork \
  -framework Security -framework CoreText -framework OpenGLES -framework QuartzCore \
  -lc++ -lxml2 -lz -lbz2 -liconv -Xlinker -ObjC \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  BridgeStub.swift ../../Animeko/SwiftVlcPlayer.swift main.swift -o "$app/VlcHarness"
cp fixture.mkv "$app/"
mkdir -p "$app/Frameworks"
cp -R "$framework" "$app/Frameworks/"
codesign --force --sign - "$app/Frameworks/MobileVLCKit.framework"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.animeko.vlctest</string>
<key>CFBundleExecutable</key><string>VlcHarness</string>
<key>CFBundleName</key><string>VlcHarness</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if "iPhone" in x["name"]))')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch --console "$device" org.animeko.vlctest | tee build/native-vlc.log
grep -q VLC_TEST_PASSED build/native-vlc.log
