#!/bin/bash
set -euo pipefail
root=${1:?absolute source directory required}
script_dir=$(cd "$(dirname "$0")" && pwd)
kit=54bba6d95502d0f3f7a9da581727935b21d55fb2
core=6de05adcbaf2e8b85fe86aad4169393098628119
checkout() {
  local url=$1 revision=$2 directory=$3
  if [ ! -d "$directory/.git" ]; then
    git init "$directory"
    git -C "$directory" remote add origin "$url"
    git -C "$directory" fetch --depth 1 origin "$revision"
    git -C "$directory" checkout --detach FETCH_HEAD
  fi
  git -C "$directory" cat-file -e "$revision^{commit}"
}
checkout https://github.com/videolan/vlckit.git "$kit" "$root"
checkout https://github.com/videolan/vlc.git "$core" "$root/libvlc/vlc"
test "$(git -C "$root" rev-parse HEAD)" = "$kit"
git -C "$root/libvlc/vlc" merge-base --is-ancestor "$core" HEAD
if [ ! -f "$root/.official-patches-applied" ]; then
  git -C "$root/libvlc/vlc" -c user.name='Animeko CI' -c user.email='ci@localhost' am "$root"/libvlc/patches/*.patch
  git -C "$root/libvlc/vlc" rev-parse HEAD > "$root/.official-patches-applied"
fi
trace_patch="$script_dir/patches/rate-trace.patch"
if git -C "$root/libvlc/vlc" apply --reverse --check "$trace_patch" 2>/dev/null; then
  git -C "$root/libvlc/vlc" apply --reverse "$trace_patch"
fi
if [ "${VLC_RATE_TRACE:-0}" = 1 ]; then
  git -C "$root/libvlc/vlc" apply --check "$trace_patch"
  git -C "$root/libvlc/vlc" apply "$trace_patch"
fi
# The upstream symbol collector assumes an arm64 build also has a device slice.
# This job produces only an arm64 simulator slice, with the app's iOS minimum.
git -C "$root" show "$kit:buildMobileVLCKit.sh" > "$root/buildMobileVLCKit-simulator.sh"
python3 - "$root/buildMobileVLCKit-simulator.sh" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
edits = {
    'SDK_MIN=9.0': 'SDK_MIN=16.0',
    'if [ "$1" = "x86_64" ];then': 'if [ "$1" = "x86_64" ] || { [ "$1" = "aarch64" ] && [ "$BUILD_DEVICE" = "no" ]; };then',
    'spushd $arch/lib/vlc/plugins': 'spushd $actual_arch/lib/vlc/plugins',
}
for old, new in edits.items():
    assert s.count(old) == 1, (old, s.count(old))
    s = s.replace(old, new)
p.write_text(s)
PY
cd "$root"
export VLC_PATH="$PATH"
bash buildMobileVLCKit-simulator.sh -a aarch64 -s -n -v
xcodebuild archive -project MobileVLCKit.xcodeproj -scheme MobileVLCKit \
  -sdk iphonesimulator -configuration Release -archivePath build/source-simulator.xcarchive \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SKIP_INSTALL=NO ENABLE_BITCODE=NO
test -f build/source-simulator.xcarchive/Products/Library/Frameworks/MobileVLCKit.framework/MobileVLCKit
