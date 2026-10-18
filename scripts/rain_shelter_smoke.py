#!/usr/bin/env python3
"""Measure the signed app with one fixed, test-owned foreground window and isolated preferences."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile',choices=['development','release'],default='development')
parser.add_argument('--arch',choices=['arm64','x86_64'])
args = parser.parse_args()
target_arch = args.arch or platform.machine()
suffix = '/'+target_arch if target_arch != platform.machine() else ''
OUT = ROOT / ('output/release'+suffix+'/weather' if args.profile == 'release' else 'output/rain-shelter')
OUT.mkdir(parents=True, exist_ok=True)
EMPTY = OUT / 'empty-sessions'
EMPTY.mkdir(exist_ok=True)
bundle = 'VibeCute.app' if args.profile == 'release' else 'VibeCute Dev.app'
APP = ROOT / ('dist/'+args.profile+suffix+'/'+bundle+'/Contents/MacOS/CodexCaptions')
actual_arch = subprocess.check_output(['lipo','-archs',str(APP)],text=True).strip()
assert actual_arch == target_arch, 'Smoke architecture must match the tested bundle'

def last_record(path):
    if not path.exists():
        return None
    result = None
    for line in path.read_text().splitlines():
        try:
            result = json.loads(line)
        except json.JSONDecodeError:
            pass
    return result

def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

fixture = process = None
ready = OUT / 'fixture-ready.json'
ready.unlink(missing_ok=True)
reports = []
try:
    with (OUT / 'fixture.log').open('w') as stream:
        fixture = subprocess.Popen([str(ROOT / '.build/rain-shelter-window-fixture'), str(ready)], stdout=stream, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 10
    while not ready.exists() and time.monotonic() < deadline:
        if fixture.poll() is not None:
            raise RuntimeError('Fixture exited before establishing its own window')
        time.sleep(.1)
    assert ready.exists(), 'No fixture window'
    fixtures = [json.loads(ready.read_text())]
    assert fixtures[0]['foregroundWindowVerified'], 'Fixture must prove it is the actual foreground window'
    for label, wet, seconds in [('rain-off', False, 12), ('rain-on-fallback', True, 12), ('rain-on-sheltered', True, 8)]:
        if label == 'rain-on-sheltered':
            stop(fixture)
            ready.unlink(missing_ok=True)
            with (OUT / 'fixture-wide.log').open('w') as stream:
                fixture = subprocess.Popen([str(ROOT / '.build/rain-shelter-window-fixture'), str(ready), '--wide'], stdout=stream, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            assert ready.exists(), 'No wide fixture window'
            fixtures.append(json.loads(ready.read_text()))
            assert fixtures[-1]['foregroundWindowVerified'], 'Wide fixture is not actually in front'
        suite = 'local.vibecute.rain-shelter-smoke.' + uuid.uuid4().hex
        seed = OUT / (label + '-preferences.plist')
        diag = OUT / (label + '-diagnostics.jsonl')
        diag.unlink(missing_ok=True)
        prefs = dict(onboardingVersion=1, onboardingStep='complete', enabled=True, trackedHarnesses=[],
            claudeTrackingMigrated=True, doubaoTrackingMigrated=True, autoAvoidanceEnabled=False,
            autoWindowPeekEnabled=False, companionEnabled=True, companionCharacter='deepseek',
            audioEnabled=False, taskSoundsEnabled=False, questionSoundsEnabled=False,
            desktopRainEnabled=wet, desktopRainAutomatic=False, desktopRainSound=False,
            desktopRainSize=1.0, desktopRainSpeed=1.0, desktopRainWind=0.0, desktopRainQuantity=1.0,
            characterPositions={"companion":{"x":200.0,"y":30.0}})
        seed.write_bytes(plistlib.dumps(prefs))
        subprocess.run(['defaults', 'import', suite, str(seed)], check=True)
        try:
            command = [str(APP), '--preferences-suite', suite, '--no-approval-stream',
                '--no-audio', '--no-speech', '--no-vocal-separation', '--no-task-sounds', '--no-question-sounds',
                '--no-doubao', '--no-workbuddy', '--diagnostics', str(diag)]
            for flag in ['--sessions-root', '--deepseek-root', '--claude-root', '--opencode-root', '--workbuddy-root']:
                command += [flag, str(EMPTY)]
            with (OUT / (label + '-runtime.log')).open('w') as stream:
                process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 10
            while last_record(diag) is None and time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Signed app exited')
                time.sleep(.1)
            assert last_record(diag), 'No app diagnostics'
            time.sleep(4)
            metrics = OUT / (label + '-app-performance.json')
            sampler = subprocess.Popen(['python3', str(ROOT / 'scripts/onboarding_performance.py'), str(process.pid),
                '--seconds', str(seconds), '--output', str(metrics)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            positions = []
            while sampler.poll() is None:
                row = last_record(diag)
                for actor in (row or {}).get('rainShelter', {}).get('actors', []):
                    positions.append(dict(x=actor['x'], y=actor['y'], fallback=actor['fallback'], phase=actor['phase']))
                if process.poll() is not None:
                    raise RuntimeError('Signed app exited during sampling')
                time.sleep(.2)
            output, error = sampler.communicate()
            if sampler.returncode:
                raise RuntimeError(error)
            print(output, end='', flush=True)
            data = last_record(diag)
            assert data['desktopRain']['active'] == wet
            assert not data['rainWeather']['enabled'], 'Manual fixture unexpectedly enabled weather requests'
            if label == 'rain-on-fallback':
                assert positions and all(p['fallback'] for p in positions), 'Test-owned tiny foreground roof must force fallback'
                xs = [p['x'] for p in positions]
                assert 60 < max(xs)-min(xs) <= 112.1, 'Signed app did not run in a bounded local band'
                assert data['rainShelter']['plans'] <= data['desktopRain']['frames']/10 + 4
                assert data['rainShelter']['windowQueries'] == 0
            elif label == 'rain-on-sheltered':
                assert positions and not any(p['fallback'] for p in positions)
                assert data['rainShelter']['actors'][0]['phase'] == 'sheltered', 'Signed app never arrived inside real foreground window'
                assert any(c.get('rainShelterFrame') == -1 and c.get('originalThinkingPoseActive') for c in data['characters']), 'Arrival did not finish stowing basin and resume thinking'
                roof = fixtures[-1]['appKitFrame']
                actor = data['rainShelter']['actors'][0]
                assert actor['x'] >= roof['x']+7.9 and actor['x']+204 <= roof['x']+roof['width']-7.9, 'Full artwork did not fit inside foreground window horizontally'
                assert abs(actor['y']+2-roof['y']-8) < .2 and actor['y']+214 <= roof['y']+roof['height']-7.9, 'Below-window start did not arrive at bottom inside edge'
            else:
                assert data['desktopRain']['frames'] == data['desktopRain']['geometryQueries'] == 0
                assert not data['rainShelter']['actors']
            reports.append(dict(scenario=label, performance=json.loads(metrics.read_text()),
                rain=data['desktopRain'], shelter=data['rainShelter'], observedPositions=positions))
        finally:
            stop(process)
            process = None
            subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            seed.unlink(missing_ok=True)
    (OUT / 'signed-app-performance.json').write_text(json.dumps(dict(
        environment=f'signed {args.profile} app, one current display, fixed test-owned foreground windows; isolated empty sessions; no audio; warmup 4s; sample 12s off/fallback and 8s sheltered',
        app=str(APP),architecture=actual_arch,
        comparison='same desktop fixture, rain off versus rain on with fallback actor; includes rain rendering and actor costs together',
        exclusions=['not a separate WindowServer/GPU measurement', 'not multi-display or long-term acceptance'],
        fixtures=fixtures, scenarios=reports), ensure_ascii=False, indent=2))
    print('Signed app smoke passed: manual rain triggers bounded native fallback and real foreground arrival; off has no rain work', flush=True)
finally:
    stop(process)
    stop(fixture)
