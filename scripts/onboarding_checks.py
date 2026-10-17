#!/usr/bin/env python3
"""Native onboarding regression, including real process restarts with injected permission requests."""
import argparse
import os
from pathlib import Path
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile',choices=['release','development'],default='release')
args=parser.parse_args()
profile=args.profile
scratch=root/'.build/settings-checks'/profile
out=root/'output/onboarding'/profile
out.mkdir(parents=True,exist_ok=True)
empty=out/'empty-sessions';empty.mkdir(exist_ok=True)
env=dict(os.environ,CAPTIONS_BUILD_PROFILE=profile,CLANG_MODULE_CACHE_PATH=str(scratch/'clang-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(scratch/'swift-cache'))
env.pop('CAPTIONS_DISTRIBUTION_BUILD',None)
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
build_args=['swift','build','--disable-sandbox','--scratch-path',str(scratch)]
subprocess.run(build_args+['-j','4','--product','CodexCaptions','-Xcxx','-isystem','-Xcxx',sdk+'/usr/include/c++/v1'],cwd=root,env=env,check=True)
build=Path(subprocess.check_output(build_args+['--show-bin-path'],cwd=root,env=env,text=True).strip())
objects=[p for p in (build/'CodexCaptions.product/Objects.LinkFileList').read_text().splitlines() if not p.endswith('/main.swift.o')]
command=['swiftc',str(root/'Tests/Onboarding/main.swift'),'-o',str(out/'OnboardingChecks'),'-module-cache-path',str(scratch/'clang-cache'),'-I',str(build/'Modules'),'-I',str(root/'Sources/CSQLite'),'-D','VIBECUTE_RELEASE' if profile=='release' else 'VIBECUTE_DEVELOPMENT']
for bridge in ['ZstdBridge','AubioBridge','BTrackBridge','BeatNetBridge']:
    mapping=build/(bridge+'.build/module.modulemap')
    if mapping.exists(): command+=['-Xcc','-fmodule-map-file='+str(mapping)]
command+=['-framework','Accelerate','-lc++','-lsqlite3']+objects
subprocess.run(command,cwd=root,env=env,check=True)
def run(suite,extra=()):
    subprocess.run([str(out/'OnboardingChecks'),'--preferences-suite',suite,
        '--no-position-memory','--no-approval-stream','--no-task-sounds','--no-question-sounds','--no-doubao','--no-workbuddy',
        '--no-audio','--no-avoidance','--sessions-root',str(empty),*extra],cwd=root,env=env,check=True)
run('app.vibecute.onboarding-check.'+uuid.uuid4().hex)
for replay in [False,True]:
    for first in ['screen','audio']:
        suite='app.vibecute.permission-restart.'+uuid.uuid4().hex
        try:
            for stage in ['begin','resume','continue','finished']:
                run(suite,['--restart-stage',stage,'--first-permission',first]+(['--replay-check'] if replay else []))
        finally:
            subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print('PASS onboarding profile='+profile+': native replay + 16 isolated restart phases; no system permissions changed')
