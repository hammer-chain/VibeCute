#!/usr/bin/env python3
"""Register the existing calibrated steel dome; requires author-only Pillow.

No PNG is modified. Rerun after recalibrating/replacing the rain paintings.
The app loads the small JSON once; it never samples artwork pixels per frame.
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
assets = ROOT/'Sources/CodexCaptions/Resources/DeepSeekThinking/RainShelter'
output = ROOT/'output/basin-rain'
output.mkdir(parents=True,exist_ok=True)
sheet = Image.new('RGB',(2560,1020),'#253647')
profiles = {}
for cell, index in enumerate(range(5,20)):
    image = Image.open(assets/f'frame-{index:02}.png').convert('RGBA')
    assert image.size == (512,640), 'Re-register changed canvas coordinates first'
    pixels = image.load()
    contour = []
    for x in range(65,475):
        for y in range(50,320):
            r,g,b,a = pixels[x,y]
            if a > 220 and min(r,g,b) > 65 and max(r,g,b)-min(r,g,b) < 32:
                contour.append((x,y)); break
    top = min(y for x,y in contour)
    upper = [(x,y) for x,y in contour if y < top+65]
    left, right = min(x for x,y in upper)+3, max(x for x,y in upper)-3
    profile = []
    for k in range(9):
        x = round(left+(right-left)*k/8)
        y = min(y for xx,y in contour if abs(xx-x) <= 2)
        profile.append([x,y])
    profiles[str(index-1)] = profile
    preview = Image.new('RGB',image.size,'#253647')
    preview.paste(image,mask=image.getchannel('A'))
    draw = ImageDraw.Draw(preview)
    draw.line([tuple(point) for point in profile],fill='#70ffb0',width=3)
    draw.text((20,20),str(index),fill='white')
    sheet.paste(preview.crop((0,0,512,340)),(cell%5*512,cell//5*340))
(assets/'basin-roofs.json').write_text(json.dumps(profiles,indent=2)+'\n')
sheet.save(output/'roof-registration.jpg')
print('Registered 15 existing overhead-basin poses, nine points each; PNGs unchanged')
