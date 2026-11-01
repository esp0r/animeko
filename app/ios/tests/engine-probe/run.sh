#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
engine=${1:?engine required}
if [ "$engine" = 3 ]; then pod=MobileVLCKit; version=3.7.4; else pod=VLCKit; version=4.0.0a25; fi
printf "install! 'cocoapods', :integrate_targets => false\nplatform :ios, '16.0'\ntarget 'EngineProbe' do\n  pod '%s', '%s'\nend\n" "$pod" "$version" > Podfile
pod install
framework=$(find "Pods/$pod" -name "$pod.framework" -path '*simulator*' | head -1)
test -n "$framework"
app="$PWD/build/EngineProbe.app"
mkdir -p "$app/Frameworks"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -sdk "$sdk" -target "$(uname -m)-apple-ios16.0-simulator" \
  -F "$(dirname "$framework")" -framework "$pod" -framework UIKit -framework AVFoundation \
  -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CFNetwork \
  -framework Security -framework CoreText -framework OpenGLES -framework QuartzCore \
  -framework Metal -framework MetalKit -framework AVKit -framework CoreVideo -framework SystemConfiguration \
  -lc++ -lxml2 -lz -lbz2 -liconv -Xlinker -ObjC -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  main.swift -o "$app/EngineProbe"
cp -R "$framework" "$app/Frameworks/"
codesign --force --sign - "$app/Frameworks/$pod.framework"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.animeko.engineprobe</string><key>CFBundleExecutable</key><string>EngineProbe</string><key>CFBundleName</key><string>EngineProbe</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundlePackageType</key><string>APPL</string><key>LSRequiresIPhoneOS</key><true/><key>MinimumOSVersion</key><string>16.0</string></dict></plist>
PLIST
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if "iPhone" in x["name"]))')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
for codec in h264 hevc; do
  if [ "$codec" = h264 ]; then fixture=rate-fixture; else fixture=rate-hevc-fixture; fi
  cp "../vlc/$fixture.mkv" "$app/fixture.mkv"
  codesign --force --sign - "$app"
  xcrun simctl install "$device" "$app"
  xcrun simctl launch --terminate-running-process --console "$device" org.animeko.engineprobe > "build/$codec.log" 2>&1
  cat "build/$codec.log"
  grep -q ENGINE_PROBE_PASSED "build/$codec.log"
done
