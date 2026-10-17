#!/usr/bin/env python3
"""Audit publishable source bytes without printing candidate secret values."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = {
    'private-key': rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
    'provider-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|sk-[A-Za-z0-9_-]{20,})\b',
    'service-token': rb'\b(?:AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})\b',
    'jwt': rb'\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
    'personal-path': rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|/private/var/folders/[A-Za-z0-9]+/',
    'windows-personal-path': rb'[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\',
    'credential-literal': rb'''(?im)(?:api[_-]?key|access[_-]?token|client[_-]?secret|aws_secret_access_key|password)\s*[=:]\s*["']([A-Za-z0-9_+/=-]{24,})["']''',
}
RULES = {name: re.compile(pattern) for name, pattern in PATTERNS.items()}
LOCAL_DIRS = {'.git', '.build', 'dist', 'output', 'backups', '.codex', '.claude', '.deepseek', '.opencode', '.workbuddy', '.agents', '.idea', '.vscode', '__pycache__', 'xcuserdata'}
LOCAL_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.p8', '.keychain', '.keychain-db', '.log', '.jsonl', '.sqlite', '.sqlite3', '.db', '.dmg', '.zip', '.pyc', '.mobileprovision', '.cer', '.crt', '.der'}
LOCAL_NAMES = {'auth.json', 'credentials.json', 'credentials.yaml', 'credentials.yml', 'keychain-password', 'identity.json', '.DS_Store', '.netrc'}
PNG_METADATA = {b'eXIf', b'caBX', b'tEXt', b'zTXt', b'iTXt'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def local_file(name):
    path = PurePosixPath(name)
    return (any(part in LOCAL_DIRS or part.endswith('.app') for part in path.parts)
            or path.suffix.lower() in LOCAL_SUFFIXES or path.name in LOCAL_NAMES
            or path.name.startswith(('.env', '._')) or path.name.endswith('prompt.txt'))


def inspect(data, name, metadata=True):
    findings = []
    for rule, pattern in RULES.items():
        match = pattern.search(data)
        if match:
            findings.append(dict(path=name, rule=rule, line=data[:match.start()].count(b'\n') + 1))
    if metadata and data.startswith(b'\x89PNG\r\n\x1a\n'):
        offset = 8
        while offset + 12 <= len(data):
            size = int.from_bytes(data[offset:offset + 4], 'big')
            kind = data[offset + 4:offset + 8]
            if offset + size + 12 > len(data):
                findings.append(dict(path=name, rule='malformed-png'))
                break
            if kind in PNG_METADATA:
                findings.append(dict(path=name, rule='png-metadata', chunk=kind.decode()))
            offset += size + 12
    return findings


def audit_history():
    # One batch process and one read per unique reachable object; no per-commit rescans.
    objects = {}
    for row in git('rev-list', '--objects', '--all').decode().splitlines():
        oid, _, name = row.partition(' ')
        objects[oid] = name or '(commit-or-tree)'
    proc = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=ROOT,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    findings = []
    blobs = total = metadata_blobs = 0
    historical_local_files = set()
    try:
        for oid, name in objects.items():
            proc.stdin.write((oid + '\n').encode()); proc.stdin.flush()
            header = proc.stdout.readline().split()
            size = int(header[2]); data = proc.stdout.read(size); proc.stdout.read(1)
            if header[1] not in (b'blob', b'commit', b'tag'):
                continue
            if header[1] == b'blob':
                blobs += 1; total += size
            if header[1] == b'blob' and local_file(name):
                historical_local_files.add(name)
            rows = inspect(data, name, metadata=False)
            findings.extend(dict(row, object=oid) for row in rows)
            if data.startswith(b'\x89PNG') and any(row['rule'] == 'png-metadata' for row in inspect(data, name)):
                metadata_blobs += 1
    finally:
        proc.stdin.close(); proc.wait()
    return dict(unique_blobs=blobs, bytes=total, findings=findings,
                png_blobs_with_historical_metadata=metadata_blobs,
                history_rewritten=False,
                historical_local_only_paths=sorted(historical_local_files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--export', action='store_true', help='Create a source-only ZIP after a successful current-tree audit')
    args = parser.parse_args()
    started = time.monotonic()
    paths = sorted(set(filter(None, git('ls-files', '-co', '--exclude-standard', '-z').decode().split('\0'))))
    entries = []; findings = []; total = 0
    for name in paths:
        path = ROOT / name
        if not path.exists() and not path.is_symlink():
            continue  # Tracked deletion, not part of the current export.
        parts = PurePosixPath(name).parts
        if path.is_symlink():
            findings.append(dict(path=name, rule='symlink')); continue
        if not path.is_file():
            findings.append(dict(path=name, rule='non-regular-file')); continue
        if local_file(name):
            findings.append(dict(path=name, rule='local-only-file'))
        size = path.stat().st_size
        if size >= 100 * 1024 * 1024:
            findings.append(dict(path=name, rule='github-size-limit')); continue
        data = path.read_bytes(); total += len(data)
        findings.extend(inspect(data, name))
        entries.append(dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    report = dict(files=len(entries), bytes=total, findings=findings,
                  scope='Existing tracked files plus nonignored untracked files; deleted files excluded',
                  secret_values_printed=False)
    if args.history:
        report['history'] = audit_history()
    out = ROOT / 'output/open-source-audit'; out.mkdir(parents=True, exist_ok=True)
    if args.export and not findings:
        archive = out / 'VibeCute-source.zip'
        import plistlib
        # Generated archive provenance is independent of .git and travels with every export.
        digest = hashlib.sha256()
        for path in sorted([ROOT / 'Package.swift', *[p for p in (ROOT / 'Sources').rglob('*') if p.is_file()]]):
            digest.update(str(path.relative_to(ROOT)).encode() + b'\0')
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        info = dict(schema=1, version=plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString'],
                    git_commit=git('rev-parse', 'HEAD').decode().strip(),
                    source_dirty=bool(git('status', '--porcelain')), source_sha256=digest.hexdigest())
        generated = (json.dumps(info, indent=2) + '\n').encode()
        entries = [entry for entry in entries if entry['path'] != 'SOURCE-INFO.json']
        entries.append(dict(path='SOURCE-INFO.json', bytes=len(generated), sha256=hashlib.sha256(generated).hexdigest(), generated=True))
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for entry in entries:
                path = ROOT / entry['path']; data = generated if entry.get('generated') else path.read_bytes()
                assert hashlib.sha256(data).hexdigest() == entry['sha256'], 'Source changed during export'
                info = zipfile.ZipInfo('VibeCute/' + entry['path'], (2026, 1, 1, 0, 0, 0))
                mode = 0o755 if not entry.get('generated') and path.stat().st_mode & 0o111 else 0o644
                info.external_attr = (0o100000 | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data)
        with zipfile.ZipFile(archive) as z:
            assert z.testzip() is None
            assert len(z.infolist()) == len(entries)
            for entry in entries:
                assert hashlib.sha256(z.read('VibeCute/' + entry['path'])).hexdigest() == entry['sha256']
        report['export'] = dict(path=str(archive.relative_to(ROOT)), files=len(entries), bytes=archive.stat().st_size,
                                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                                git_history_included=False, extended_attributes_included=False,
                                every_file_readback_verified=True)
        (out / 'export-manifest.json').write_text(json.dumps(entries, indent=2) + '\n')
    report['seconds'] = round(time.monotonic() - started, 3)
    (out / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 1 if findings or report.get('history', {}).get('findings') else 0


if __name__ == '__main__':
    raise SystemExit(main())
