#!/usr/bin/env python3
"""Run the final signed app with isolated, hostile legacy settings and sample idle UI cost."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--arch', choices=['arm64','x86_64'])
parser.add_argument('--seconds', type=int, default=20)
args = parser.parse_args()
suffix = '/x86_64' if args.arch == 'x86_64' and __import__('platform').machine() != 'x86_64' else ''
out = root / ('output/release' + suffix)
out.mkdir(parents=True,exist_ok=True)
empty = out / 'empty-sessions'; empty.mkdir(exist_ok=True)
suite = 'app.vibecute.release-smoke.' + uuid.uuid4().hex
prefs = dict(onboardingVersion=1,onboardingStep='complete',trackedHarnesses=[],claudeTrackingMigrated=True,doubaoTrackingMigrated=True,
             autoAvoidanceEnabled=False,autoWindowPeekEnabled=False,companionEnabled=False,audioEnabled=False,
             taskSoundsEnabled=False,taskSoundOutcomes=[],questionSoundsEnabled=False,
             audioTempoEngine='btrack',audioLipEngine='acoustic',developerModeEnabled=True,
             speechKeywordEnabled=True,songRecognitionEnabled=True,vocalSeparationEnabled=True,
             characterBindings={'codex':'deepseek-cutout'},companionCharacter='deepseek-cutout')
seed=out/'smoke-preferences.plist';seed.write_bytes(plistlib.dumps(prefs))
subprocess.run(['defaults','import',suite,str(seed)],check=True)
app = root / ('dist/release' + suffix) / 'VibeCute.app'
log = out/'runtime-smoke.log'
diagnostics = out/'runtime-diagnostics.json'
diagnostics.unlink(missing_ok=True)
command = [str(app/'Contents/MacOS/CodexCaptions'),'--preferences-suite',suite,'--sessions-root',str(empty),
           '--no-position-memory','--no-approval-stream','--no-audio','--no-avoidance','--settings-window',
           '--developer-mode','--cutout-studio','--cutout-compare','--kira-demo','--speech-demo',
           '--speech-live','--vocal-separation','--tempo-engine','aubio','--lip-engine','acoustic',
           '--preview-character','deepseek-cutout','--diagnostics',str(diagnostics)]
process=None
try:
    with log.open('w') as stream:
        process=subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT)
        (out/'smoke-pid.json').write_text(json.dumps({'pid':process.pid,'bundle':str(app),'suite':suite}))
        deadline=time.monotonic()+10
        while not diagnostics.exists() and time.monotonic()<deadline:
            if process.poll() is not None: raise RuntimeError('Signed app exited at startup')
            time.sleep(0.2)
        data=None
        for line in diagnostics.read_text().splitlines():
            try: data=json.loads(line)
            except json.JSONDecodeError: pass
        assert data is not None, 'No complete diagnostics record'
        assert data['audioTempoEngine']=='beatnet',data.get('audioTempoEngine')
        assert not data['speechEnabled'] and not data['kiraActive'] and not data['vocalSeparationEnabled']
        assert data['developerPreviewCharacter']=='deepseek'
        assert not data['trackedHarnesses']
        subprocess.run(['python3',str(root/'scripts/onboarding_performance.py'),str(process.pid),
                        '--seconds',str(args.seconds),'--output',str(out/'settings-open-performance.json')],check=True)
        if process.poll() is not None: raise RuntimeError('Signed app exited during observation')
        children=subprocess.run(['pgrep','-P',str(process.pid)],capture_output=True,text=True).stdout
        assert not children.strip(), 'Disabled features must not spawn helper processes'
        report={'signed_app_alive':True,'isolated_preferences':True,'legacy_arguments_cannot_enable_removed_features':True,
                'settings_open_seconds':args.seconds,'tracked_harnesses':0,'audio_enabled':False,
                'child_processes':0,'live_audio_performance':'not tested','long_term_performance':'not tested'}
        (out/'runtime-smoke.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()
    subprocess.run(['defaults','delete',suite],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    seed.unlink(missing_ok=True)
