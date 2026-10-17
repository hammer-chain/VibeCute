#!/usr/bin/env python3
"""Check the distributable, not the build cache or developer machine dependencies."""
import json
import pathlib
import plistlib
import subprocess
import re
import argparse
from release_privacy import check_release

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, default=root / 'dist/VibeCute.app')
parser.add_argument('--strict-metadata', action='store_true')
args = parser.parse_args()
app = args.app
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info.get('CaptionsMinimalRelease') is True
assert info['CFBundleIdentifier'] == 'app.vibecute.desktop'
privacy = check_release(app, allow_host_provenance=not args.strict_metadata)
assert privacy['privacy_verified'], privacy['failures']
resources = app / 'Contents/Resources'
for excluded in ('PinkBearThinking', 'Whisper', 'Vocal'):
    assert not list(app.rglob(excluded)), f'Unexpected resource: {excluded}'
for included in ('CodexThinking', 'DeepSeekThinking', 'DeepSeekCutout', 'CutoutCharacters', 'LipVowels.json'):
    assert (resources / included).exists(), included
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
binary = app / 'Contents/MacOS/CodexCaptions'
zstd = app / 'Contents/Frameworks/libzstd.dylib'
architectures = {}
for path in (binary, zstd):
    architectures[path.name] = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
    load_commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    minimum = re.search(r"\bminos ([0-9.]+)", load_commands)
    if minimum:
        version = lambda value: tuple((list(map(int, value.split("."))) + [0, 0])[:3])
        assert version(minimum.group(1)) <= version(info["LSMinimumSystemVersion"]), minimum.group(1)
    dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[2 if path == zstd else 1:]
    for row in dependencies:
        dependency = row.strip().split(' (')[0]
        assert dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/', '@loader_path/', '@executable_path/')), dependency
assert set(architectures[binary.name].split()) <= set(architectures[zstd.name].split())
assert not any(p.is_symlink() for p in app.rglob('*')), 'Unexpected external symlink'
report = dict(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
              architectures=architectures, bytes=sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
              minimum_macos=info['LSMinimumSystemVersion'], signature_verified=True,
              notarized=False, excluded=['PinkBearThinking', 'Whisper', 'Vocal'], privacy=privacy)
output = root / 'output/minimal-release/bundle-check.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
