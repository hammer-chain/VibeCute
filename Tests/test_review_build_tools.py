"""Failure-path checks without touching the user's signing keychain."""
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value


class SourceTests(unittest.TestCase):
    def test_audio_resources_reach_both_signed_profiles(self):
        # SwiftPM debug tests can pass while the explicit signed-app assembler
        # silently omits a sound. Check the two independent resource manifests.
        declared = set(re.findall(r'\.copy\("Resources/([^"/]+\.wav)"\)',
                                  (ROOT / 'Package.swift').read_text()))
        self.assertTrue(declared)
        for name in ['development', 'release']:
            profile = json.loads((ROOT / 'config/build-profiles' / (name+'.json')).read_text())
            self.assertFalse(declared - set(profile['resource_files']),
                             f'{name} omits SwiftPM audio: {declared-set(profile["resource_files"])}')

    def test_no_git_and_no_parent_borrow(self):
        provenance = module('source_provenance')
        with tempfile.TemporaryDirectory(dir=ROOT / '.build') as directory:
            root = Path(directory); (root / 'Sources').mkdir(); (root / 'Package.swift').write_text('fixture')
            row = provenance.describe_source(root)
            self.assertIsNone(row['git_commit']); self.assertIsNone(row['source_dirty'])
            self.assertEqual(row['source_origin'], 'archive-without-git-metadata')
            digest = provenance.source_digest(root)
            (root / 'SOURCE-INFO.json').write_text(json.dumps(dict(schema=1, git_commit='fixture-commit', source_dirty=False, source_sha256=digest)))
            self.assertTrue(provenance.describe_source(root)['archive_source_matches'])
            (root / 'Package.swift').write_text('changed')
            self.assertTrue(provenance.describe_source(root)['source_dirty'])
            self.assertFalse(provenance.describe_source(root)['archive_source_matches'])


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.sign = module('setup_signing'); self.sign.SIGNING = Path(self.temp.name) / 'Signing'
        self.sign.CONFIG = self.sign.SIGNING / 'identity.json'; self.calls = []; self.failure = None
        self.sign.run = self.run_command
        self.sign.preflight = lambda: ('fixture-openssl', [])
        self.sign.configure_trust = lambda config: None

    def run_command(self, args):
        self.calls.append(args)
        command = args[1]
        if command == self.failure: raise RuntimeError('injected failure')
        if command == 'req':
            Path(args[args.index('-out') + 1]).write_text('public certificate')
        if command == 'x509': return 'SHA1 Fingerprint=' + 'AB:' * 19 + 'AB\n'
        if command == 'create-keychain': Path(args[-1]).touch()
        if command == 'delete-keychain': Path(args[-1]).unlink()
        if command == 'find-identity': return 'AB' * 20 + ' "CodexCaptions Local Code Signing"'
        return ''

    def execute(self, *args):
        with patch('sys.argv', ['setup_signing.py', *args]): self.sign.main()

    def test_unsupported_tool_leaves_no_state(self):
        self.sign.preflight = lambda: (_ for _ in ()).throw(RuntimeError('unsupported tool'))
        with self.assertRaises(RuntimeError): self.execute()
        self.assertFalse(self.sign.SIGNING.exists())

    def test_pkcs12_failure_before_persistent_state(self):
        self.failure = 'pkcs12'
        with self.assertRaises(RuntimeError): self.execute()
        self.assertFalse(self.sign.SIGNING.exists())

    def test_import_failure_rolls_back_and_retry_succeeds(self):
        self.failure = 'import'
        with self.assertRaises(RuntimeError): self.execute()
        self.assertFalse((self.sign.SIGNING / 'keychain-password').exists())
        self.assertFalse((self.sign.SIGNING / 'captions-signing.keychain-db').exists())
        self.failure = None; self.execute()
        self.assertTrue(self.sign.CONFIG.exists())
        self.assertTrue(all('-legacy' not in call for call in self.calls))
        before = len(self.calls); self.execute(); self.assertEqual(len(self.calls), before)

    def test_recover_existing_identity_without_replacing_key(self):
        self.sign.SIGNING.mkdir()
        for name in ['certificate.pem', 'keychain-password', 'captions-signing.keychain-db']:
            (self.sign.SIGNING / name).write_text('fixture')
        self.execute('--recover')
        self.assertTrue(self.sign.CONFIG.exists())
        self.assertFalse(any(call[1] in ['req','create-keychain','import'] for call in self.calls))

    def test_preflight_with_and_without_legacy(self):
        sign = module('setup_signing')
        for flag in ['', ' -legacy']:
            with patch.object(sign, 'run', return_value='OpenSSL'), patch.object(sign.shutil, 'which', side_effect=lambda s:'/fixture/'+s), patch.object(sign.subprocess,'run',return_value=types.SimpleNamespace(stdout='-export -inkey -passout'+flag,stderr='')):
                _, flags = sign.preflight(); self.assertEqual(flags, ['-legacy'] if flag else [])


if __name__ == '__main__': unittest.main()
