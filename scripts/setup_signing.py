#!/usr/bin/env python3
"""Provision one reusable local signing identity, shared by this user's checkouts."""
import json
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
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    os.chmod(CONFIG, 0o600)


def main():
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        if not Path(config['keychain']).exists():
            raise RuntimeError('Signing keychain is missing; restore it instead of generating a new identity.')
        configure_trust(config)
        print('Reusing local signing identity:', config['identity'])
        return
    SIGNING.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(SIGNING, 0o700)
    keychain = SIGNING / 'captions-signing.keychain-db'
    password_file = SIGNING / 'keychain-password'
    if keychain.exists() or password_file.exists():
        raise RuntimeError('Partial signing setup exists. Recover it before retrying; do not replace the identity.')
    password = secrets.token_urlsafe(36)
    descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(password)
    run(['security', 'create-keychain', '-p', password, str(keychain)])
    run(['security', 'unlock-keychain', '-p', password, str(keychain)])
    with tempfile.TemporaryDirectory(prefix='provision-', dir=SIGNING) as directory:
        temp = Path(directory)
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
        run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '3650',
             '-config', str(openssl_config), '-keyout', str(private_key), '-out', str(certificate)])
        run(['openssl', 'pkcs12', '-export', '-legacy', '-inkey', str(private_key), '-in', str(certificate),
             '-name', NAME, '-out', str(archive), '-passout', 'file:' + str(password_file)])
        run(['security', 'import', str(archive), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
        fingerprint = run(['openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1'])
        identity = fingerprint.strip().split('=', 1)[1].replace(':', '')
        # Persist only the public certificate; private export files disappear with the temporary directory.
        (SIGNING / 'certificate.pem').write_bytes(certificate.read_bytes())
    CONFIG.write_text(json.dumps(dict(name=NAME, identity=identity, keychain=str(keychain)), indent=2) + '\n')
    os.chmod(CONFIG, 0o600)
    configure_trust(json.loads(CONFIG.read_text()))
    print('Created reusable local signing identity:', identity)


if __name__ == '__main__':
    main()
