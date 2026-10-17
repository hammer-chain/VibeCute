"""Describe source origins without requiring Git or borrowing a parent repository."""
import hashlib
import json
from pathlib import Path
import subprocess


def source_digest(root):
    digest = hashlib.sha256()
    for source in sorted([root / 'Package.swift', *[p for p in (root / 'Sources').rglob('*') if p.is_file()]]):
        digest.update(str(source.relative_to(root)).encode() + b'\0')
        digest.update(hashlib.sha256(source.read_bytes()).digest())
    return digest.hexdigest()


def describe_source(root, digest=None):
    root = Path(root).resolve()
    digest = digest or source_digest(root)
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=root, capture_output=True, text=True)
        if top.returncode == 0 and Path(top.stdout.strip()).resolve() == root:
            commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, stderr=subprocess.DEVNULL))
            return dict(git_commit=commit, source_dirty=dirty, source_origin='git')
    except (OSError, subprocess.CalledProcessError):
        pass
    metadata = root / 'SOURCE-INFO.json'
    if metadata.exists():
        row = json.loads(metadata.read_text())
        if row.get('schema') != 1:
            raise ValueError('Unsupported source archive metadata')
        matches = row.get('source_sha256') == digest
        return dict(git_commit=row.get('git_commit'), source_dirty=bool(row.get('source_dirty')) or not matches,
                    source_origin='archive', archive_source_matches=matches)
    # GitHub Download ZIP has no commit identity. Report it as unknown, never fabricate HEAD.
    return dict(git_commit=None, source_dirty=None, source_origin='archive-without-git-metadata')
