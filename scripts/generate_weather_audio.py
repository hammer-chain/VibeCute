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
