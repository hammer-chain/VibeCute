#!/usr/bin/env python3
"""Verify the actual standalone app against the frozen production contract."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
from release_privacy import check_release

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--report', type=Path)
args = parser.parse_args()
app = args.app
config_path = root / 'config/build-profiles/release.json'
config = json.loads(config_path.read_text())
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
r = app / 'Contents/Resources'
manifest = json.loads((r / 'BuildManifest.json').read_text())
assert manifest['config'] == config
assert manifest['config_sha256'] == hashlib.sha256(config_path.read_bytes()).hexdigest()
assert info['VibeCuteBuildProfile'] == 'release'
assert info['CFBundleIdentifier'] == config['bundle_id']
assert info['LSMinimumSystemVersion'] == config['minimum_macos']
assert 'NSSpeechRecognitionUsageDescription' not in info
for name in ('Kira','Whisper','Vocal','DeepSeekCutout','CutoutCharacters','PinkBearThinking'):
    assert not list(app.rglob(name)), f'Forbidden resource: {name}'
for pattern in config.get('excluded_resource_globs', []):
    assert not list(r.glob(pattern)), pattern
expected_top = set(config['resource_directories'] + config['resource_files'] + ['BeatNet','BuildManifest.json','AppIcon.icns','Zstandard-LICENSE.txt','Licenses'])
assert {p.name for p in r.iterdir()} == expected_top, 'Unexpected top-level resources'
licenses = r / 'Licenses'
expected_licenses = set(config['legal_documents']) | {'Zstandard-LICENSE.txt','BeatNetPlus-LICENSE.txt','PocketFFT-NOTICE.txt','Weights-NOTICE.txt','ggml-LICENSE.txt'}
assert {p.name for p in licenses.iterdir()} == expected_licenses, 'Incomplete legal documents'
for name, source in config['legal_documents'].items():
    assert (licenses / name).read_bytes() == (root / source).read_bytes(), f'Legal document mismatch: {name}'
for name in expected_licenses - set(config['legal_documents']):
    source = r / name if name == 'Zstandard-LICENSE.txt' else r / 'BeatNet' / name
    assert (licenses / name).read_bytes() == source.read_bytes(), f'Third-party notice mismatch: {name}'
assert hashlib.sha256((r / 'BeatNet/generic-f32.gguf').read_bytes()).hexdigest() == config['beatnet_model_sha256']
from collections import Counter
profile = json.loads((r / 'LipVowels.json').read_text())
assert profile['version'] == 1 and len(profile['scale']) == 12
assert all(math.isfinite(v) and v > 0 for v in profile['scale']) and 0 < len(profile['templates']) <= 256
assert all(len(t['features']) == 12 and all(math.isfinite(v) for v in t['features']) for t in profile['templates'])
assert len(Counter(t['shape'] for t in profile['templates'])) == 5
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
architectures = {}
for path in [app / 'Contents/MacOS/CodexCaptions', *list(app.rglob('*.dylib'))]:
    architectures[path.name] = subprocess.check_output(['lipo','-archs',str(path)],text=True).strip()
    commands = subprocess.check_output(['otool','-l',str(path)],text=True)
    for value in re.findall(r'\bminos ([0-9.]+)',commands):
        version=lambda s: tuple((list(map(int,s.split('.'))) + [0,0])[:3])
        assert version(value) <= version(info['LSMinimumSystemVersion']), (path.name,value)
    dependencies = subprocess.check_output(['otool','-L',str(path)],text=True)
    assert 'Speech.framework' not in dependencies
    for row in dependencies.splitlines()[1:]:
        dependency = row.strip().split(' (')[0]
        assert dependency.startswith(('/System/Library/','/usr/lib/','@rpath/','@loader_path/','@executable_path/')), dependency
if manifest.get('target_arch'):
    assert architectures['CodexCaptions'] == manifest['target_arch'], 'Unexpected target architecture'
for name, value in architectures.items():
    assert set(architectures['CodexCaptions'].split()) <= set(value.split()), f'Architecture mismatch: {name}'
symbols = subprocess.check_output(['nm','-j',str(app / 'Contents/MacOS/CodexCaptions')],text=True)
for symbol in ('caption_aubio_', 'caption_btrack_', 'CutoutStudioController', 'CutoutComparisonController', 'CutoutArtwork', 'CutoutOverlayRenderer', 'VocalWorkerTransport', 'SFSpeechRecognizer', 'JapaneseKeywordSpeech'):
    assert symbol not in symbols, f'Stripped implementation leaked: {symbol}'
assert not any(p.is_symlink() for p in app.rglob('*'))
privacy = check_release(app,allow_host_provenance=True)
assert privacy['privacy_verified'],privacy
report = dict(profile='release',version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
              config_sha256=manifest['config_sha256'],architectures=architectures,
              files=sum(p.is_file() for p in app.rglob('*')),
              bytes=sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
              binary_sha256=hashlib.sha256((app / 'Contents/MacOS/CodexCaptions').read_bytes()).hexdigest(),
              signature_verified=True,notarized=False,privacy=privacy,legal_documents_verified=True,license_files=sorted(expected_licenses))
if args.report:
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
