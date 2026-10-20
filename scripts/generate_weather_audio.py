#!/usr/bin/env python3
"""Author an original, deterministic distant-thunder effect (Python stdlib).

Offline only. No recording, downloaded samples, microphone or model service.
The app plays the bounded PCM file once per storm event, not once per display.
"""
from array import array
import math
from pathlib import Path
import random
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]
RATE, DURATION = 24000, 5.5
rng = random.Random(20261018)
samples = []
low, rumble, stereo = 0.0, 0.0, 0.0
for i in range(round(RATE*DURATION)):
    t = i/RATE
    noise = rng.uniform(-1,1)
    low += .085*(noise-low)
    rumble += .012*(noise-rumble)
    stereo += .03*(rng.uniform(-1,1)-stereo)
    def roll(delay, decay):
        u = max(0,t-delay)
        return (1-math.exp(-u/.025))*math.exp(-u/decay)
    envelope = roll(0,1.2)+.55*roll(.5,1.0)+.28*roll(1.4,.85)
    fade = min(1,max(0,(DURATION-t)/.6))
    body = (low*.55+rumble*2.8+math.sin(t*2*math.pi*43)*rumble*.5)*envelope*fade
    width = stereo*.18*envelope*fade
    samples.extend((body+width,body-width))
peak = max(map(abs,samples))
pcm = array('h',(round(x/peak*.68*32767) for x in samples))
if sys.byteorder != 'little':
    pcm.byteswap()
path = ROOT/'Sources/CodexCaptions/Resources/thunder.wav'
with wave.open(str(path),'wb') as output:
    output.setparams((2,2,RATE,0,'NONE','not compressed'))
    output.writeframes(pcm.tobytes())
print(f'Original thunder: {DURATION}s, {RATE}Hz stereo PCM, {path.stat().st_size} bytes')

# Three additional authored rumbles. Gentle attacks and bounded peaks preserve
# the quiet rain ambience; generation happens offline, never in the frame loop.
VARIANTS = [
    ("thunder-soft", 6.0, .032, .007, .22, [(0,1.9,1),(.95,1.3,.30)], 2026102001),
    ("thunder-roll", 6.2, .065, .012, .10, [(0,.9,.55),(.55,1.3,.85),(1.35,1.2,.65),(2.2,.9,.28)], 2026102002),
    ("thunder-double", 5.8, .105, .018, .075, [(0,.65,.8),(1.15,1.25,1)], 2026102003),
]
for name, duration, low_alpha, bass_alpha, attack_time, pulses, seed in VARIANTS:
    rng = random.Random(seed)
    low = bass = side = 0.0
    values = []
    for i in range(round(RATE*duration)):
        t = i/RATE
        low += low_alpha*(rng.uniform(-1,1)-low)
        bass += bass_alpha*(low-bass)
        side += .025*(rng.uniform(-1,1)-side)
        envelope = 0.0
        for delay, decay, weight in pulses:
            u = t-delay
            if u >= 0:
                envelope += weight*(1-math.exp(-u/attack_time))*math.exp(-u/decay)
        fade = min(1,max(0,(duration-t)/.8))
        body = (low*.35+bass*2.3)*envelope*fade
        width = side*.10*envelope*fade
        values.extend((body+width,body-width))
    peak = max(map(abs,values))
    rms = math.sqrt(sum(v*v for v in values)/len(values))
    gain = min(.58/peak,.080/rms)
    pcm = array('h',(round(v*gain*32767) for v in values))
    if sys.byteorder != 'little': pcm.byteswap()
    path = ROOT/'Sources/CodexCaptions/Resources'/f'{name}.wav'
    with wave.open(str(path),'wb') as output:
        output.setparams((2,2,RATE,0,'NONE','not compressed'))
        output.writeframes(pcm.tobytes())
    print(f'Original {name}: {duration}s, peak={peak*gain:.3f}, RMS={rms*gain:.3f}, {path.stat().st_size} bytes')

# Small damped, inharmonic steel modes and a soft initial water transient.
# One authored hit; the app reuses two voices with a tiny rate variation.
rng = random.Random(2026101802)
hits = []
for i in range(round(RATE*.24)):
    t = i/RATE
    attack = 1-math.exp(-t/.0007)
    metal = sum(weight*math.sin(2*math.pi*hz*t)*math.exp(-t/decay)
                for hz,weight,decay in [(1320,.55,.055),(2135,.4,.035),(3571,.3,.022),(5823,.16,.014)])
    transient = rng.uniform(-1,1)*.16*math.exp(-t/.004)
    hits.append((metal+transient)*attack*min(1,(.24-t)/.025))
peak = max(map(abs,hits))
pcm = array('h',(round(x/peak*.58*32767) for x in hits))
if sys.byteorder != 'little': pcm.byteswap()
path = ROOT/'Sources/CodexCaptions/Resources/basin-hit.wav'
with wave.open(str(path),'wb') as output:
    output.setparams((1,2,RATE,0,'NONE','not compressed')); output.writeframes(pcm.tobytes())
print(f'Original steel basin hit: .24s, {RATE}Hz mono PCM, {path.stat().st_size} bytes')
