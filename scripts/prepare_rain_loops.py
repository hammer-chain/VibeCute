#!/usr/bin/env python3
"""Author two separate seamless PCM loops from the licensed original MP3s.

Offline only; ffmpeg is an authoring dependency, never an app dependency.
Keep the original sources intact. Remove their outer fades, overlap each
recording's own tail/head with a 2s equal-power transition, and emit PCM so
there is no MP3 encoder delay/padding at the loop boundary.
"""
from array import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Sources/CodexCaptions/Resources'
OUT = ROOT / 'output/seamless-rain'
CROSSFADE = 2.0
# End trims remove the authored fade-out/quiet ending, not the sparse rain
# within the recording. The two tracks are never mixed together.
TRACKS = [('rain-bed', 2.0, 3.0), ('rain-drops', 2.0, 8.0)]

def rms(samples):
    return math.sqrt(sum(x*x for x in samples)/len(samples)) / 32768

def author(name, start_trim, end_trim):
    source = RESOURCES / f'{name}.mp3'
    probe = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(source)]))
    duration = float(probe['format']['duration'])
    with tempfile.TemporaryDirectory() as temporary:
        decoded = Path(temporary)/'decoded.wav'
        subprocess.run(['ffmpeg','-v','error','-i',str(source),'-af',
            f'atrim=start={start_trim}:end={duration-end_trim},asetpts=PTS-STARTPTS',
            '-c:a','pcm_s16le','-map_metadata','-1',str(decoded)],check=True)
        with wave.open(str(decoded),'rb') as audio:
            channels,rate = audio.getnchannels(),audio.getframerate()
            assert audio.getsampwidth() == 2 and channels == 2
            original = audio.readframes(audio.getnframes())
    overlap = round(CROSSFADE*rate)
    width = channels*2
    edge_bytes = overlap*width
    head,tail = array('h'),array('h')
    head.frombytes(original[:edge_bytes]);tail.frombytes(original[-edge_bytes:])
    if sys.byteorder != 'little': head.byteswap();tail.byteswap()
    blended = array('h')
    for frame in range(overlap):
        theta = frame/(overlap-1)*math.pi/2
        a,b = math.cos(theta),math.sin(theta)
        for channel in range(channels):
            i=frame*channels+channel
            value = round(tail[i]*a+head[i]*b)
            assert -32768 <= value <= 32767, 'Crossfade would clip'
            blended.append(value)
    if sys.byteorder != 'little': blended.byteswap()
    # The last blend sample is source[L-1], then wrapping continues at source[L].
    # Both joins therefore follow real adjacent samples, without a fade-to-zero.
    content = original[edge_bytes:-edge_bytes]+blended.tobytes()
    path = RESOURCES / f'{name}-loop.wav'
    with wave.open(str(path),'wb') as audio:
        audio.setparams((channels,2,rate,0,'NONE','not compressed'))
        audio.writeframes(content)
    samples = array('h'); samples.frombytes(content)
    if sys.byteorder != 'little': samples.byteswap()
    edge = round(rate*.1)*channels
    boundary = samples[-edge:]+samples[:edge]
    before,after = rms(samples[-edge:]),rms(samples[:edge])
    seam = rms(boundary)
    assert before > 0.0001 and after > 0.0001, 'Boundary still silent'
    assert 0.25 < before/after < 4.0, f'Boundary level mismatch: {before}/{after}'
    # No artificial seam jump: exact original source adjacency at wrap.
    continuation = array('h');continuation.frombytes(original[edge_bytes-width:edge_bytes+width])
    if sys.byteorder != 'little': continuation.byteswap()
    assert list(samples[-channels:]+samples[:channels]) == list(continuation)
    return dict(file=path.name,source=source.name,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        sha256=hashlib.sha256(content).hexdigest(),sample_rate=rate,channels=channels,
        frames=len(content)//width,duration=len(content)/width/rate,bytes=path.stat().st_size,
        start_trim=start_trim,end_trim=end_trim,crossfade_seconds=CROSSFADE,
        seam_before_rms=before,seam_after_rms=after,seam_rms=seam,exact_source_adjacency=True)

if __name__ == '__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    report=[author(*track) for track in TRACKS]
    (OUT/'loop-validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
