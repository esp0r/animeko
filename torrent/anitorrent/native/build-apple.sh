#!/usr/bin/env bash
set -euo pipefail

# Each SDK has independent object files and OpenSSL configuration.
sdk=${1:?Usage: build-apple.sh iphoneos|iphonesimulator output-directory}
output=${2:?Missing output directory}
case "$sdk" in
  iphoneos) openssl_target=ios64-xcrun ;;
  iphonesimulator) openssl_target=iossimulator-arm64-xcrun ;;
  *) echo "Unsupported Apple SDK: $sdk" >&2; exit 1 ;;
esac
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$output"
output=$(cd "$output" && pwd)
export SDKROOT
SDKROOT=$(xcrun --sdk "$sdk" --show-sdk-path)
export IPHONEOS_DEPLOYMENT_TARGET=16.0
openssl_prefix="$output/openssl"
if [ ! -f "$openssl_prefix/lib/libssl.a" ]; then
  if [ ! -d "$output/openssl-source/.git" ]; then
    git clone --depth 1 --branch openssl-3.5.4 https://github.com/openssl/openssl.git "$output/openssl-source"
  fi
  test "$(git -C "$output/openssl-source" rev-parse HEAD)" = c1eeb9406b6142148f267594197d853403d10208
  (
    cd "$output/openssl-source"
    ./Configure "$openssl_target" no-shared no-tests --prefix="$openssl_prefix" --libdir=lib
    make -j 3
    make install_sw
  )
fi
cmake -S "$source_dir" -B "$output/cmake" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="$openssl_prefix" \
  -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
  -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a"
cmake --build "$output/cmake" --target anitorrent_c --parallel 3
mkdir -p "$output/lib" "$output/include"
# Kotlin/Native embeds this archive into its klib; consumers need no extra paths.
xcrun libtool -static -o "$output/lib/libanitorrent_c.a" \
  "$output/cmake/libanitorrent_c.a" \
  "$output/cmake/_deps/libtorrent-build/libtorrent-rasterbar.a" \
  "$openssl_prefix/lib/libssl.a" "$openssl_prefix/lib/libcrypto.a"
cp "$source_dir/include/anitorrent_c.h" "$output/include/"
