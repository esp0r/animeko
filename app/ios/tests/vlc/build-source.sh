#!/bin/bash
set -euo pipefail
root=${1:?absolute source directory required}
platform=${VLC_SOURCE_PLATFORM:-simulator}
case "$platform" in
  simulator) sdk=iphonesimulator; wrapper_args=(-a aarch64 -s -n -v) ;;
  device) sdk=iphoneos; wrapper_args=(-a aarch64 -n -v) ;;
  *) echo "Unsupported VLC platform: $platform" >&2; exit 1 ;;
esac
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
if [ -f "$root/.animeko-clock-boundary.patch" ]; then
  git -C "$root/libvlc/vlc" apply --reverse "$root/.animeko-clock-boundary.patch"
  rm "$root/.animeko-clock-boundary.patch"
fi
for name in rate-trace pcm-probe; do
  trace_patch="$script_dir/patches/$name.patch"
  if git -C "$root/libvlc/vlc" apply --reverse --check "$trace_patch" 2>/dev/null; then
    git -C "$root/libvlc/vlc" apply --reverse "$trace_patch"
  fi
  if [ "${VLC_RATE_TRACE:-0}" = 1 ]; then
    git -C "$root/libvlc/vlc" apply --check "$trace_patch"
    git -C "$root/libvlc/vlc" apply "$trace_patch"
  fi
done
if [ "${VLC_RATE_BOUNDARY:-0}" = 1 ]; then
  git -C "$root/libvlc/vlc" apply --check "$script_dir/patches/clock-boundary.patch"
  git -C "$root/libvlc/vlc" apply "$script_dir/patches/clock-boundary.patch"
  cp "$script_dir/patches/clock-boundary.patch" "$root/.animeko-clock-boundary.patch"
fi
cp "$script_dir/rate_timeline.h" "$root/libvlc/vlc/src/input/animeko_rate_timeline.h"
cp "$script_dir/pcm_probe.h" "$root/libvlc/vlc/modules/audio_output/animeko_pcm_probe.h"
# The upstream symbol collector assumes an arm64 build also has a device slice.
# Each job produces one arm64 slice, with the app's iOS minimum.
git -C "$root" show "$kit:buildMobileVLCKit.sh" > "$root/buildMobileVLCKit-simulator.sh.new"
python3 - "$root/buildMobileVLCKit-simulator.sh.new" "$platform" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
edits = {
    'SDK_MIN=9.0': 'SDK_MIN=16.0',
    'if [ "$1" = "x86_64" ];then': 'if [ "$1" = "x86_64" ] || { [ "$1" = "aarch64" ] && [ "$BUILD_DEVICE" = "no" ]; };then',
    'spushd $arch/lib/vlc/plugins': 'spushd $actual_arch/lib/vlc/plugins',
    '--disable-qt --disable-skins2': '--disable-qt --disable-skins2 --disable-ncurses --disable-gnutls',
    'blacklist="\n    stats': 'blacklist="\n    gnutls\n    stats',
}
if sys.argv[2] == 'device':
    edits['\nBUILD_SIMULATOR=yes\n'] = '\nBUILD_SIMULATOR=no\n'
simulator_plugin = r'''SIMULATORLDFLAGS+="\$(PROJECT_DIR)/libvlc/vlc/install-"$OSSTYLE"Simulator/$actual_arch/lib/vlc/plugins/$file "'''
edits[simulator_plugin] = simulator_plugin + r'''
            if [ -z "$DEVICEARCHS" ]; then
                symbols=$(nm -g -arch $actual_arch install-"$OSSTYLE"Simulator/$actual_arch/lib/vlc/plugins/$file)
                entryname=$(get_symbol "$symbols" _)
                test -n "$entryname"
                DEFINITIONS+="int $entryname (int (*)(void *, void *, int, ...), void *);\n"
                BUILTINS+=" $entryname,\n"
            fi'''
for old, new in edits.items():
    assert s.count(old) == 1, (old, s.count(old))
    s = s.replace(old, new)
p.write_text(s)
PY
# Preserve the wrapper timestamp when its configure options are unchanged.
if ! cmp -s "$root/buildMobileVLCKit-simulator.sh.new" "$root/buildMobileVLCKit-simulator.sh"; then
  cp "$root/buildMobileVLCKit-simulator.sh.new" "$root/buildMobileVLCKit-simulator.sh"
fi
cd "$root"
# GNU Make 4.4 provides the FIFO jobserver used by current Ninja builds.
mkdir -p "$root/host-tools"
ln -sf "$(command -v gmake)" "$root/host-tools/make"
gmake --version
export VLC_PATH="$root/host-tools:$PATH"
# Contrib's autoreconf searches the private tools prefix for pkg.m4.
pkg_macro="$(brew --prefix)/share/aclocal/pkg.m4"
test -f "$pkg_macro"
mkdir -p "$root/libvlc/vlc/extras/tools/build/share/aclocal"
cp "$pkg_macro" "$root/libvlc/vlc/extras/tools/build/share/aclocal/pkg.m4"
# The cached configure step checks this path to detect changed options.
export THIS_SCRIPT_PATH="$root/buildMobileVLCKit-simulator.sh"
bash -O xpg_echo buildMobileVLCKit-simulator.sh "${wrapper_args[@]}"
xcodebuild archive -project MobileVLCKit.xcodeproj -scheme MobileVLCKit \
  -sdk "$sdk" -configuration Release -archivePath "build/source-$platform.xcarchive" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SKIP_INSTALL=NO ENABLE_BITCODE=NO
test -f "build/source-$platform.xcarchive/Products/Library/Frameworks/MobileVLCKit.framework/MobileVLCKit"
