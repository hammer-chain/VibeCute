#!/usr/bin/env python3
"""Assemble an explicit profile into a fresh directory; never copy a previous app."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from source_provenance import describe_source, source_digest

root = Path(__file__).resolve().parent.parent
profile, binary, staging = sys.argv[1:]
config_path = root / 'config/build-profiles' / f'{profile}.json'
config = json.loads(config_path.read_text())
assert config['schema'] == 1 and config['profile'] == profile
app = Path(staging) / f"{config['app_name']}.app"
contents = app / 'Contents'
resources = contents / 'Resources'
frameworks = contents / 'Frameworks'
for directory in (contents / 'MacOS', resources, frameworks):
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy(binary, contents / 'MacOS/CodexCaptions')
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier=config['bundle_id'], CFBundleName=config['app_name'],
            CFBundleDisplayName=config['app_name'], LSMinimumSystemVersion=config['minimum_macos'],
            VibeCuteBuildProfile=profile,
            CFBundleVersion=os.environ.get('CAPTIONS_BUILD_NUMBER', __import__('datetime').datetime.now().strftime('%Y%m%d%H%M%S')))
if profile == 'release':
    info.pop('NSSpeechRecognitionUsageDescription', None)
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
for name in config['resource_directories']:
    shutil.copytree(root / 'Sources/CodexCaptions/Resources' / name, resources / name, copy_function=shutil.copy)
for name in config['resource_files']:
    shutil.copy(root / 'Sources/CodexCaptions/Resources' / name, resources / name)
for name in config['excluded_resources']:
    path = resources / name
    if path.is_dir(): shutil.rmtree(path)
    elif path.exists(): path.unlink()
for pattern in config.get('excluded_resource_globs', []):
    for path in resources.glob(pattern):
        if path.is_file(): path.unlink()
zstd = Path(os.environ.get('CAPTIONS_ZSTD_LIBRARY', '/opt/homebrew/opt/zstd/lib/libzstd.dylib'))
if not zstd.exists(): zstd = Path('/usr/local/opt/zstd/lib/libzstd.dylib')
shutil.copy(zstd.resolve(), frameworks / 'libzstd.dylib')
# Homebrew's dylib is read-only; metadata cleaning and re-signing require owner write.
(frameworks / 'libzstd.dylib').chmod((frameworks / 'libzstd.dylib').stat().st_mode | 0o200)
shutil.copy(root / 'Resources/Zstandard-LICENSE.txt', resources)
beatnet = Path(os.environ.get('CAPTIONS_BEATNET_RUNTIME', str(root / '.build/beatnet/runtime')))
beatnet_files = ['libcaption_beatnet.dylib', 'generic-f32.gguf', 'BeatNetPlus-LICENSE.txt', 'PocketFFT-NOTICE.txt', 'Weights-NOTICE.txt', 'ggml-LICENSE.txt']
if profile == 'release':
    model_hash = hashlib.sha256((beatnet / 'generic-f32.gguf').read_bytes()).hexdigest()
    assert model_hash == config['beatnet_model_sha256'], 'BeatNet model mismatch'
    assert all((beatnet / name).is_file() for name in beatnet_files), 'Incomplete BeatNet runtime'
if (beatnet / 'libcaption_beatnet.dylib').exists():
    (resources / 'BeatNet').mkdir()
    for name in beatnet_files:
        shutil.copy(beatnet / name, resources / 'BeatNet' / name)
if profile == 'development':
    for source, name in [('Resources/Aubio-LICENSE.txt','Aubio-LICENSE.txt'), ('Sources/BTrackBridge/COPYING','BTrack-LICENSE.txt'), ('Sources/BTrackBridge/vendor/COPYING','KissFFT-LICENSE.txt'), ('Sources/SamplerateBridge/COPYING','Libsamplerate-LICENSE.txt')]:
        shutil.copy(root / source, resources / name)
    for runtime, name, required in [('whisper','Whisper',['captions-whisper','ggml-small-q5_1.bin']), ('vocal-separation','Vocal',['captions-vocal','model.onnx'])]:
        source = root / '.build' / runtime / 'runtime'
        if all((source / file).is_file() for file in required):
            shutil.copytree(source, resources / name, copy_function=shutil.copy)
# Ship legal texts in the app; the DMG exposes the same folder next to the app.
licenses = resources / 'Licenses'
licenses.mkdir()
for name, source in config['legal_documents'].items():
    shutil.copy(root / source, licenses / name)
shutil.copy(resources / 'Zstandard-LICENSE.txt', licenses)
if (resources / 'BeatNet').exists():
    for name in beatnet_files[2:]:
        shutil.copy(resources / 'BeatNet' / name, licenses)
if profile == 'development':
    for name in ['Aubio-LICENSE.txt','BTrack-LICENSE.txt','KissFFT-LICENSE.txt','Libsamplerate-LICENSE.txt']:
        shutil.copy(resources / name, licenses)
digest = source_digest(root)
manifest = dict(target_arch=os.environ.get('CAPTIONS_TARGET_ARCH'), source_sha256=digest,
                config=config, config_sha256=hashlib.sha256(config_path.read_bytes()).hexdigest(),
                **describe_source(root, digest), notarized=False)
(resources / 'BuildManifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
