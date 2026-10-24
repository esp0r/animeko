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
cp -R ../../Animeko/SubtitleFonts "$app/"
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
data=$(xcrun simctl get_app_container "$device" org.animeko.vlctest data)
rm -f "$data/Documents/subtitle-captured"
xcrun simctl launch --console "$device" org.animeko.vlctest > build/native-vlc.log 2>&1 &
launch_pid=$!
trap 'kill "$launch_pid" 2>/dev/null || true' EXIT
ready=false
# A fresh CI simulator may still be starting system services after bootstatus.
for attempt in $(seq 1 900); do
  if grep -q VLC_SUBTITLE_READY build/native-vlc.log; then ready=true; break; fi
  if ! kill -0 "$launch_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$ready" != true ]; then echo 'VLC_TEST_FAILED: simulator did not reach subtitle frame'; cat build/native-vlc.log; exit 1; fi
xcrun simctl io "$device" screenshot build/chinese-subtitles.png
touch "$data/Documents/subtitle-captured"
wait "$launch_pid" || { cat build/native-vlc.log; exit 1; }
cat build/native-vlc.log
xcrun swift verify_subtitles.swift build/chinese-subtitles.png
grep -q VLC_TEST_PASSED build/native-vlc.log
