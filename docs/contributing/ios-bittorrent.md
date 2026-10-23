# iOS BitTorrent

The iOS target uses the same Anitorrent download sessions, cache database, episode
selection, download queue, piece scheduling and peer filtering as Android. Its
platform adapter calls libtorrent through a small C ABI instead of JNI.

## Native library

`torrent/anitorrent/native/build-apple.sh` builds arm64 archives for `iphoneos`
and `iphonesimulator`. Dependencies are pinned in the script and CMake project.
The resulting archive includes libtorrent and OpenSSL; the cinterop klib embeds
it so application consumers do not need additional archive search paths.

The CMake project applies a checked connection-policy adaptation to the pinned
Anitorrent source: it retains peers while the file selection is empty and uses
a shorter reconnect delay if a remote seed closes an idle connection. Without
this, the only peer in a magnet swarm can be dropped between metadata discovery
and selecting an episode.

Normal Gradle builds invoke this script automatically. CI builds both archives
in separate jobs, then passes `-Pani.anitorrent.prebuilt=true` when consuming them.
Do not use this property without the archives under
`torrent/anitorrent/build/native/<sdk>/lib/`.

## Build an IPA

On macOS with Xcode, CocoaPods, JBR 21 and the repository's Android SDK installed:

```properties
# local.properties
ani.enable.ios=true
ani.build.framework=true
```

```shell
./gradlew :app:ios:podInstall :app:ios:buildDebugIpa
```

The IPA is written to `app/ios/build/archives/debug/Animeko.ipa`. It has no Apple
distribution provisioning profile and must be signed for the destination device
before installation. The `iOS BitTorrent IPA` workflow reproduces this build on
a hosted Mac and publishes the IPA only after the selected iOS tests pass.

## Playback and persistence

AVKit does not accept the application's seekable torrent input directly. On iOS,
`TorrentPlaybackProxy` exposes verified pieces through a random path on a
loopback-only HTTP server, with GET, HEAD and single byte-range responses. The
same adapter serves completed local cache files. Progress, prefetch and sharing
recover the original source through `unwrapTorrentPlayback`.

Completed local MKV downloads are remuxed to a temporary MP4 before AVKit opens
them. Video and audio packets are copied; text subtitles become MP4 timed text
(without ASS styling). The original download is preserved. Temporary output is
removed on failure, cancellation, switching media or closing playback. Video/audio
codec support still follows AVKit; image subtitles and incomplete MKV streams are
not converted by this local-file adapter.

The IPA workflow builds the pinned mediamp FFmpeg runtime with the `movtext`
encoder. Local builds must supply that archive via `ani.ios.ffmpegRuntime` in
`gradle.properties` (also read by CocoaPods nested Gradle builds).

Resume data is requested periodically and when the application resigns active.
The shared cache database restores queued work after relaunch. iOS may suspend
the process after it goes into the background; this implementation does not
promise unrestricted background BitTorrent transfers. Metered-network upload
limits use Network.framework's expensive and constrained path flags.

## Validation

The native transfer workflow creates its own deterministic fixture and local
seeder. It exercises magnet metadata, selective file download, byte-for-byte
verification and resume-file restoration without relying on public torrents.

```shell
cmake -S torrent/anitorrent/tests/native -B build/native-transfer
cmake --build build/native-transfer --parallel 3
ctest --test-dir build/native-transfer --output-on-failure

./gradlew :torrent:anitorrent:iosSimulatorArm64Test --tests '*NativeBridgeTest*'
./gradlew :app:shared:app-data:iosSimulatorArm64Test \
  --tests '*TorrentHttpRangeTest*' --tests '*TorrentPlaybackProxyTest*'
```

The iOS bridge tests cover C interop ownership, metadata, priorities and resume
files. The playback tests cover partial reads, byte-range headers, HEAD/error
responses, source identity and cleanup. These checks do not replace a device
test of AVKit playback, seeking, application suspension and relaunch.
