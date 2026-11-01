"""Assemble an unsigned IPA from a verified app and a pinned device VLC artifact."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import zipfile


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def safe(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name:
        raise ValueError(f'Unsafe archive path: {name}')


def device_dylib(data):
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from('<8I', data)
    assert (magic, cpu, kind) == (0xfeedfacf, 0x100000c, 6), 'Expected arm64 dynamic framework'
    assert size + 32 <= len(data)
    offset, platform, identity = 32, None, None
    for _ in range(count):
        command, length = struct.unpack_from('<2I', data, offset)
        assert length >= 8 and offset + length <= 32 + size
        if command == 0x32:
            platform = struct.unpack_from('<I', data, offset + 8)[0]
        if command == 0x25:
            platform = 2
        if command == 0xD:
            start = struct.unpack_from('<I', data, offset + 8)[0]
            identity = data[offset + start:offset + length].split(b'\0', 1)[0]
        offset += length
    assert platform == 2, 'Simulator framework cannot be installed on iPad'
    assert identity == b'@rpath/MobileVLCKit.framework/MobileVLCKit', identity
    for marker in (b'ANIMEKO_BOUNDARY', b'ANIMEKO_VIDEO_RETIME', b'ANIMEKO_PCM'):
        assert marker in data, f'Missing synchronization code marker: {marker!r}'


def assemble(base, base_hash, artifact, application_commit, expected_commit, output):
    for commit in (application_commit, expected_commit):
        assert len(commit) == 40 and all(c in '0123456789abcdef' for c in commit)
    assert sha(base) == base_hash, 'Base IPA hash mismatch'
    assert not output.exists(), 'Refusing to overwrite an existing IPA'
    if artifact.is_dir():
        manifest = json.loads((artifact / 'vlc-device-manifest.json').read_text())
        payload = (artifact / 'MobileVLCKit-device.zip').read_bytes()
    else:
        with zipfile.ZipFile(artifact) as bundle:
            assert bundle.testzip() is None
            manifest_names = [n for n in bundle.namelist() if n.endswith('/vlc-device-manifest.json') or n == 'vlc-device-manifest.json']
            archive_names = [n for n in bundle.namelist() if n.endswith('/MobileVLCKit-device.zip') or n == 'MobileVLCKit-device.zip']
            assert len(manifest_names) == len(archive_names) == 1
            manifest = json.loads(bundle.read(manifest_names[0]))
            payload = bundle.read(archive_names[0])
    assert manifest['commit'] == expected_commit
    assert manifest['platform'] == 'iOS' and manifest['architecture'] == 'arm64'
    assert hashlib.sha256(payload).hexdigest() == manifest['sha256']
    provenance = {'base_ipa_sha256': base_hash, 'application_commit': application_commit,
                  'vlc': manifest, 'packaging': 'Unsigned framework replacement; application and BT binaries preserved'}
    preserved = {}
    with zipfile.ZipFile(io.BytesIO(payload)) as framework, zipfile.ZipFile(base) as app:
        assert framework.testzip() is None and app.testzip() is None
        app_infos = [n for n in app.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        assert len(app_infos) == 1
        root = app_infos[0][:-len('Info.plist')]
        prefix = root + 'Frameworks/MobileVLCKit.framework/'
        framework_root = 'MobileVLCKit.framework/'
        binary = framework.read(framework_root + 'MobileVLCKit')
        device_dylib(binary)
        provenance['vlc_binary_sha256'] = hashlib.sha256(binary).hexdigest()
        info = plistlib.loads(framework.read(framework_root + 'Info.plist'))
        assert info['CFBundleExecutable'] == 'MobileVLCKit'
        assert info.get('CFBundleSupportedPlatforms') == ['iPhoneOS']
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as result:
            for entry in app.infolist():
                safe(entry.filename)
                if entry.filename.startswith(prefix) or entry.filename.startswith(root + '_CodeSignature/'):
                    continue
                if not entry.is_dir():
                    with app.open(entry) as source:
                        preserved[entry.filename] = hashlib.file_digest(source, 'sha256').hexdigest()
                with app.open(entry) as source, result.open(entry, 'w') as destination:
                    shutil.copyfileobj(source, destination, 1024 * 1024)
            for entry in framework.infolist():
                safe(entry.filename)
                if not entry.filename.startswith(framework_root):
                    continue
                suffix = entry.filename[len(framework_root):]
                if suffix.startswith('_CodeSignature/'):
                    continue
                assert not stat.S_ISLNK(entry.external_attr >> 16), 'Unexpected framework symlink'
                target = zipfile.ZipInfo(prefix + suffix, entry.date_time)
                target.create_system = entry.create_system
                target.external_attr = entry.external_attr
                target.internal_attr = entry.internal_attr
                target.compress_type = zipfile.ZIP_DEFLATED
                with framework.open(entry) as source, result.open(target, 'w') as destination:
                    shutil.copyfileobj(source, destination, 1024 * 1024)
            result.writestr(root + 'AnimekoVlcBuild.json', json.dumps(provenance, indent=2) + '\n')
    with zipfile.ZipFile(output) as check:
        assert check.testzip() is None
        assert len(check.namelist()) == len(set(check.namelist())), 'Duplicate IPA entries'
        for name, digest in preserved.items():
            with check.open(name) as f:
                assert hashlib.file_digest(f, 'sha256').hexdigest() == digest, name
        assert hashlib.sha256(check.read(prefix + 'MobileVLCKit')).hexdigest() == provenance['vlc_binary_sha256']
    provenance.update({'ipa_sha256': sha(output), 'bytes': output.stat().st_size,
                       'preserved_files': len(preserved), 'all_preserved_files_verified': True,
                       'device_platform_verified': True, 'zip_crc_verified': True})
    output.with_suffix('.assembly.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(provenance, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--base-sha256', required=True)
    parser.add_argument('--framework-artifact', type=Path, required=True)
    parser.add_argument('--application-commit', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assemble(args.base, args.base_sha256, args.framework_artifact, args.application_commit, args.commit, args.output)
