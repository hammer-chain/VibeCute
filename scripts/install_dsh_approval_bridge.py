#!/usr/bin/env python3
"""Optional real-profile installation. Run only with explicit user approval."""
import argparse
import datetime
import json
import hashlib
from pathlib import Path
import shutil
parser = argparse.ArgumentParser()
parser.add_argument('--profile', type=Path, default=Path.home() / '.dsh/profiles/desktop')
args = parser.parse_args()
profile = args.profile.expanduser().resolve()
patch = profile / 'cordis.patch.yml'
original = patch.read_text()
source = Path(__file__).resolve().parent.parent / 'Integrations/DSHApprovalBridge/index.mjs'
target = profile / 'node_modules/@local/vibecute-approval-bridge-v8/index.mjs'
begin, end = '# BEGIN VibeCute approval bridge', '# END VibeCute approval bridge'
block = '\n'.join([begin, '- insert:', '    - id: vibecute-approval-bridge-v8', '      name: "@local/vibecute-approval-bridge-v8"', '      config:', '        revision: ' + json.dumps(hashlib.sha256(b''.join((source.parent / n).read_bytes() for n in ['index.mjs', 'client.js', 'package.json'])).hexdigest()[:16]), end])
if begin in original:
    start = original.index(begin)
    stop = original.index(end, start) + len(end)
    updated = original[:start] + block + original[stop:]
else:
    updated = original.rstrip() + '\n\n' + block + '\n'
backup = patch.with_name(patch.name + '.vibecute-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.bak')
shutil.copy2(patch, backup)
target.parent.mkdir(parents=True, exist_ok=True)
for name in ['index.mjs', 'client.js', 'package.json']:
    shutil.copyfile(source.parent / name, target.parent / name)
temporary = patch.with_name('.cordis.patch.vibecute.tmp')
temporary.write_text(updated)
shutil.copymode(patch, temporary)
temporary.replace(patch)
print(json.dumps({'module': str(target), 'backup': str(backup)}, ensure_ascii=False))
