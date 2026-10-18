#!/usr/bin/env python3
"""Offline, repeatable calibration of the approved full-body rain paintings.

Requires Pillow (only for this authoring script, never the app). Always reads the
unmodified approved commit, so running twice cannot accumulate color/size drift.
No image generation, separated limbs, or runtime pixel processing.
"""
import argparse
import colorsys
import hashlib
import io
import json
import math
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
FOLDER = Path('Sources/CodexCaptions/Resources/DeepSeekThinking')
APPROVED = '6023e7cb164625498ee1c08736f43de1c242790d'
SIZE = (512, 640)
FOOT = 608
# Pixel registration: compensate for the smaller seated drawings, keeping the
# accepted running poses at one fixed scale (no frame-to-frame leg stretching).
SCALES = [1.18]*20 + [1.23, 1.27, 1.29, 1.29]


def approved(index, source):
    name = f'frame-{index:02}.png'
    data = ((source/name).read_bytes() if source else subprocess.check_output(
        ['git', 'show', f'{APPROVED}:{FOLDER}/RainShelter/{name}'], cwd=ROOT))
    return Image.open(io.BytesIO(data)).convert('RGBA')


def tone(image, index):
    out = image.copy()
    pixels = out.load()
    # Exclude face/eyes and the dark navy clothes; soften only bright blue hair.
    eyes = [(176,284),(200,283),(208,296),(208,266),(198,280),(219,299),
            (207,247),(235,219),*[(267,240)]*8,(247,234),(210,247),
            (194,254),(182,248),(229,301),(190,302),(176,300),(170,302)]
    eyeX, eyeY = eyes[index-1]
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a < 10:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            h, s, v = colorsys.rgb_to_hsv(r/255, g/255, b/255)
            if 190/360 < h < 248/360 and s > .35 and v > .38 and y < 420:
                weight = min(1, (v-.38)/.2)
                # Smooth eye protection; hard rectangular masks leave visible
                # horizontal color seams across the bangs in an animation.
                distance = math.hypot((x-eyeX)/60, (y-eyeY)/22)
                weight *= min(1, max(0, (distance-1)/.6))
                rgb = colorsys.hsv_to_rgb(h, s*(1-.18*weight), v*(1-.04*weight))
                pixels[x, y] = (*[round(c*255) for c in rgb], a)
    return out


def register(image, factor):
    # Same seat/foot anchor, larger padded canvas prevents basin/hair clipping.
    scaled = image.resize((round(384*factor), round(512*factor)), Image.Resampling.LANCZOS)
    result = Image.new('RGBA', SIZE)
    result.alpha_composite(scaled, (round(256-192*factor), round(FOOT-480*factor)))
    return result


def canonical():
    atlas = Image.open(ROOT/FOLDER/'thinking-atlas.png').convert('RGBA')
    source = atlas.crop((0, 0, atlas.width//4, atlas.height//2))
    # Match the native 168pt rectangle at y=8 inside the 255pt rain canvas.
    # Preserve the normal atlas's 10px below the shoes: ending on the rain
    # foot line instead would cause a 3.3pt jump on release to native thinking.
    r = source.resize((316, 422), Image.Resampling.LANCZOS)
    result = Image.new('RGBA', SIZE)
    result.alpha_composite(r, (98, 186))
    return result


def settle(image, sourceY, targetY, xScale, xOffset):
    mesh = []
    for sy0,sy1,ty0,ty1 in zip(sourceY,sourceY[1:],targetY,targetY[1:]):
        mesh.append(((0,round(ty0),512,round(ty1)),
                     (-xOffset/xScale,sy0,-xOffset/xScale,sy1,
                      (512-xOffset)/xScale,sy1,(512-xOffset)/xScale,sy0)))
    return image.transform(SIZE,Image.Transform.MESH,mesh,Image.Resampling.BICUBIC)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/FOLDER/'RainShelter')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    frames = [register(tone(approved(i, args.source_dir), i), SCALES[i-1]) for i in range(1,25)]
    # Reuse the original reaching pose and its complete body. The separate prop
    # slides behind the skirt/tail; no limbs are cut up or reassembled.
    reach = tone(approved(24, args.source_dir), 24)
    mask = Image.new('L', (384,512))
    ImageDraw.Draw(mask).polygon([(250,402),(278,391),(323,393),(359,404),
                                 (353,440),(342,463),(294,475),(259,464)], fill=255)
    prop = Image.new('RGBA', reach.size)
    prop.paste(reach, (0,0), mask)
    prop = prop.crop((250,390,360,476))
    bare = tone(approved(1, args.source_dir), 1)
    # Reach for the basin, draw it behind the body in four progressively tucked
    # positions, then settle from hands-in-lap to the real thinking artwork.
    frames.append(register(tone(approved(2,args.source_dir),2), 1.23))
    for t in [0, 1/3, 2/3, 1.0]:
        layer = Image.new('RGBA', reach.size)
        p = prop.resize((round(110*(1-.3*t)),round(86*(1-.3*t))),Image.Resampling.LANCZOS)
        layer.alpha_composite(p,(round(250-80*t),round(390-30*t)))
        layer.alpha_composite(bare)
        frames.append(register(layer,1.18))
    start, end = frames[-1], canonical()
    ys = [0,212,377,410,500,552,608,640]
    ye = [0,204,351,394,474,544,600,640]
    for t in [1/3,2/3,1]:
        intermediate = [a+(b-a)*t for a,b in zip(ys,ye)]
        rain = settle(start,ys,intermediate,1-.1*t,30.6*t)
        normal = settle(end,ye,intermediate,(1-.1*t)/.9,(30.6*t-30.6)/.9)
        frames.append(Image.blend(rain,normal,t) if t < 1 else end)
    assert len(frames) == 32
    hashes = {}
    for i, image in enumerate(frames, 1):
        path = args.output/f'frame-{i:02}.png'
        image.save(path, optimize=True)  # no EXIF/text/user metadata
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report = dict(sourceCommit=APPROVED, size=SIZE, footLine=FOOT,
                  scales=SCALES, hairSaturationFactor=.82, hairValueFactor=.96,
                  stowFrames=8, decodedPixelBytes=len(frames)*512*640*4, files=hashes)
    (args.output/'calibration.json').write_text(json.dumps(report,indent=2)+'\n')
    preview = ROOT/'output/rain-shelter/calibration'
    preview.mkdir(parents=True,exist_ok=True)
    sheet = Image.new('RGB',(512*6,680*2),'#253647')
    draw = ImageDraw.Draw(sheet)
    for cell, i in enumerate([0,23,24,25,26,27,28,29,30,31]):
        x,y=cell%6*512,cell//6*680
        sheet.paste(frames[i],(x,y),frames[i]);draw.text((x+20,y+646),str(i+1),fill='white')
    sheet.save(preview/'stow-contact.jpg')
    comp=Image.new('RGB',(512*3,680),'#253647')
    for i,im in enumerate([canonical(),frames[0],frames[23]]): comp.paste(im,(512*i,0),im)
    comp.save(preview/'size-after.jpg')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__ == '__main__':
    main()
