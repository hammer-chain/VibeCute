#!/usr/bin/env python3
"""Clean assembled release metadata and audit the actual bytes before delivery."""
import argparse
import json
import mmap
import os
from pathlib import Path
import time
import ctypes

libc = ctypes.CDLL(None, use_errno=True)
libc.listxattr.argtypes = (ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int)
libc.listxattr.restype = ctypes.c_ssize_t
libc.removexattr.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
libc.removexattr.restype = ctypes.c_int
libc.getxattr.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                          ctypes.c_uint32, ctypes.c_int)
libc.getxattr.restype = ctypes.c_ssize_t
libc.setxattr.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                          ctypes.c_uint32, ctypes.c_int)
libc.setxattr.restype = ctypes.c_int


def default_finder_info(path):
    # HFS exposes native Finder records; (-1, -1) means no assigned icon location.
    buffer = ctypes.create_string_buffer(32)
    size = libc.getxattr(os.fsencode(path), b'com.apple.FinderInfo', buffer, 32, 0, 0)
    unset_location = bytes(10) + b'\xff' * 4 + bytes(18)
    return size == 32 and buffer.raw in (bytes(32), unset_location)


def attributes(path):
    encoded = os.fsencode(path)
    size = libc.listxattr(encoded, None, 0, 0)
    if size < 0:
        raise OSError(ctypes.get_errno(), f'Cannot read attributes: {path}')
    if not size:
        return []
    buffer = ctypes.create_string_buffer(size)
    actual = libc.listxattr(encoded, buffer, size, 0)
    if actual < 0:
        raise OSError(ctypes.get_errno(), f'Cannot read attributes: {path}')
    return [os.fsdecode(name) for name in buffer.raw[:actual].split(b'\0') if name]


def remove_attributes(path):
    for name in attributes(path):
        if name == 'com.apple.FinderInfo':
            # HFS native Finder fields are reset by writing zero; deletion may return EPERM.
            if libc.setxattr(os.fsencode(path), os.fsencode(name), bytes(32), 32, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), f'Cannot reset Finder fields: {path}')
            continue
        if libc.removexattr(os.fsencode(path), os.fsencode(name), 0) != 0:
            raise OSError(ctypes.get_errno(), f'Cannot remove attribute {name}: {path}')


def check_release(root, clean=False, allow_host_provenance=False):
    started = time.monotonic()
    paths = [root, *root.rglob('*')]
    removed = 0
    for path in paths:
        if path.is_symlink():
            continue
        if clean and (path.name == '.DS_Store' or path.name.startswith('._')):
            path.unlink()
            removed += 1
            continue
        if clean:
            # The volume root may expose immutable default native Finder fields.
            if path == root and attributes(path) == ['com.apple.FinderInfo'] and default_finder_info(path):
                continue
            remove_attributes(path)
    if clean:
        return dict(removed_finder_files=removed, seconds=round(time.monotonic() - started, 3))

    failures = []
    files = total_bytes = host_provenance = default_finder_records = 0
    needles = (b'/Users/', b'/home/', b'/private/var/folders/', os.fsencode(Path(__file__).resolve().parent.parent))
    for path in paths:
        if path.is_symlink():
            continue
        relative = str(path.relative_to(root))
        if path.name == '.DS_Store' or path.name.startswith('._'):
            failures.append(f'{relative}: Finder/AppleDouble metadata')
        names = attributes(path)
        if 'com.apple.FinderInfo' in names and default_finder_info(path):
            names.remove('com.apple.FinderInfo')
            default_finder_records += 1
        if allow_host_provenance and 'com.apple.provenance' in names:
            names.remove('com.apple.provenance')
            host_provenance += 1
        if names:
            failures.append(f'{relative}: extended attributes {names}')
        if not path.is_file():
            continue
        files += 1
        size = path.stat().st_size
        total_bytes += size
        if not size:
            continue
        with path.open('rb') as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
            for needle in needles:
                if data.find(needle) != -1:
                    failures.append(f'{relative}: local identity/build path ({os.fsdecode(needle)})')
    report = dict(files=files, bytes=total_bytes, seconds=round(time.monotonic() - started, 3),
                  privacy_verified=not failures, host_provenance_entries=host_provenance,
                  default_finder_records=default_finder_records, failures=failures)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('clean', 'audit'))
    parser.add_argument('path', type=Path)
    parser.add_argument('--allow-host-provenance', action='store_true',
                        help='Allow macOS-managed provenance on the host; mounted delivery must be checked separately')
    args = parser.parse_args()
    if not args.path.is_dir():
        parser.error('Release directory does not exist')
    result = check_release(args.path, clean=args.mode == 'clean', allow_host_provenance=args.allow_host_provenance)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(1 if result.get('failures') else 0)
