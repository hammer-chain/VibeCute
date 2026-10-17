#!/usr/bin/env python3
"""Provision one reusable local signing identity, shared by this user's checkouts."""
import argparse
import json
import re
import shutil
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

SIGNING = Path.home() / 'Library/Application Support/CodexCaptions/Signing'
CONFIG = SIGNING / 'identity.json'
NAME = 'CodexCaptions Local Code Signing'


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Commands may contain the temporary import password; never print their arguments on failure.
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout


def configure_trust(config):
    keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user']))
    if config['keychain'] not in keychains:
        run(['security', 'list-keychains', '-d', 'user', '-s', *keychains, config['keychain']])
    if config.get('trustPolicy') == 'user-code-signing':
        return
    run(['security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
         '-k', config['keychain'], str(SIGNING / 'certificate.pem')])
    config['trustPolicy'] = 'user-code-signing'
    config.pop('trustConfigured', None)
    write_config(config)


def write_config(config):
    with tempfile.NamedTemporaryFile(mode='w', dir=SIGNING, delete=False) as file:
        path = Path(file.name)
        json.dump(config, file, indent=2); file.write('\n')
    os.chmod(path, 0o600); path.replace(CONFIG)


def preflight():
    openssl = os.environ.get('CAPTIONS_OPENSSL') or shutil.which('openssl')
    if not openssl or not shutil.which('security'):
        raise RuntimeError('OpenSSL and macOS security are required; no signing state was created.')
    run([openssl, 'version'])
    help_result = subprocess.run([openssl, 'pkcs12', '-help'], capture_output=True, text=True)
    help_text = help_result.stdout + help_result.stderr
    if not all(flag in help_text for flag in ['-export', '-inkey', '-passout']):
        raise RuntimeError('OpenSSL pkcs12 export is unavailable; no signing state was created.')
    return openssl, (['-legacy'] if '-legacy' in help_text else [])


def recover_identity(openssl):
    keychain = SIGNING / 'captions-signing.keychain-db'
    certificate = SIGNING / 'certificate.pem'
    password_file = SIGNING / 'keychain-password'
    if not all(p.is_file() for p in [keychain, certificate, password_file]):
        raise RuntimeError('Incomplete setup has no recoverable certificate/identity. Back up the Signing directory before removing incomplete files; no files were changed.')
    fingerprint = run([openssl, 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1'])
    identity = fingerprint.strip().split('=', 1)[1].replace(':', '')
    run(['security', 'unlock-keychain', '-p', password_file.read_text(), str(keychain)])
    identities = run(['security', 'find-identity', '-p', 'codesigning', str(keychain)])
    if identity not in identities:
        raise RuntimeError('The original identity is not present; restore its keychain backup. No identity was replaced.')
    config = dict(name=NAME, identity=identity, keychain=str(keychain))
    write_config(config); configure_trust(config)
    print('Recovered original local signing identity:', identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recover', action='store_true', help='Recover an already imported identity without replacing its key')
    args = parser.parse_args()
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        if not Path(config['keychain']).exists():
            raise RuntimeError('Signing keychain is missing; restore it instead of generating a new identity.')
        configure_trust(config)
        print('Reusing local signing identity:', config['identity'])
        return
    openssl, legacy_flags = preflight()
    keychain = SIGNING / 'captions-signing.keychain-db'
    password_file = SIGNING / 'keychain-password'
    if keychain.exists() or password_file.exists():
        if args.recover:
            recover_identity(openssl); return
        raise RuntimeError('Partial signing setup exists. Run with --recover to recover an imported identity; never overwrite an existing keychain.')
    password = secrets.token_urlsafe(36)
    # Complete cryptographic tool work before touching the persistent directory.
    with tempfile.TemporaryDirectory(prefix='captions-provision-') as directory:
        temp = Path(directory)
        temporary_password = temp / 'password'; temporary_password.write_text(password); os.chmod(temporary_password, 0o600)
        openssl_config = temp / 'certificate.cnf'
        openssl_config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = CodexCaptions Local Code Signing
O = Local Development
[codesign]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
''')
        private_key, certificate, archive = (temp / name for name in ('private.pem', 'certificate.pem', 'identity.p12'))
        run([openssl, 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '3650',
             '-config', str(openssl_config), '-keyout', str(private_key), '-out', str(certificate)])
        run([openssl, 'pkcs12', '-export', *legacy_flags, '-inkey', str(private_key), '-in', str(certificate),
             '-name', NAME, '-out', str(archive), '-passout', 'file:' + str(temporary_password)])
        fingerprint = run([openssl, 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1'])
        identity = fingerprint.strip().split('=', 1)[1].replace(':', '')
        SIGNING.mkdir(parents=True, exist_ok=True, mode=0o700); os.chmod(SIGNING, 0o700)
        descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as file: file.write(password)
        try:
            (SIGNING / 'certificate.pem').write_bytes(certificate.read_bytes())
            run(['security', 'create-keychain', '-p', password, str(keychain)])
            run(['security', 'unlock-keychain', '-p', password, str(keychain)])
            run(['security', 'import', str(archive), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
            write_config(dict(name=NAME, identity=identity, keychain=str(keychain)))
        except Exception:
            # Only this invocation's new files may be rolled back. Preserve all state
            # if cleanup fails, so --recover can still recover an imported identity.
            if keychain.exists():
                run(['security', 'delete-keychain', str(keychain)])
            password_file.unlink(missing_ok=True)
            (SIGNING / 'certificate.pem').unlink(missing_ok=True)
            raise
    configure_trust(json.loads(CONFIG.read_text()))
    print('Created reusable local signing identity:', identity)


if __name__ == '__main__':
    main()
