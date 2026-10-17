"""Verify source-pixel conservation and actual-renderer reassembly goldens."""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
out = (ROOT / sys.argv[1]).resolve()
record = json.loads((out / 'side-lock-split.json').read_text())
source = Image.open(ROOT / record['sourceTexture']).convert('RGBA')
expected_alpha = source.getchannel('A').tobytes()
reassembled_alpha = bytearray(len(expected_alpha))
source_rgba = source.tobytes()
for module in record['modules']:
    image = Image.open(out / module['file']).convert('RGBA')
    x0, y0, x1, y1 = module['crop']
    assert image.size == (x1 - x0, y1 - y0)
    pixels = image.tobytes()
    for y in range(image.height):
        for x in range(image.width):
            i = y * image.width + x
            if not pixels[i * 4 + 3]:
                continue
            target = (y + y0) * source.width + x + x0
            assert not reassembled_alpha[target], 'Module painted pixels overlap'
            assert pixels[i * 4:i * 4 + 4] == source_rgba[target * 4:target * 4 + 4], 'Source RGBA changed'
            reassembled_alpha[target] = pixels[i * 4 + 3]
assert bytes(reassembled_alpha) == expected_alpha, 'Original painted pixels lost or added'

rear_cases = []
for rear in record.get('rearShapes', []):
    original = Image.open(out / rear['source']).convert('RGBA')
    kept = Image.open(out / rear['file']).convert('RGBA')
    removed = Image.open(out / rear['removedFile']).convert('RGBA')
    assert original.size == kept.size == removed.size, 'Rear texture was resampled'
    op, kp, rp = original.tobytes(), kept.tobytes(), removed.tobytes()
    changed = 0
    x, y, w, h = rear['rect']
    scale = w / original.width
    top = 1024 - y - h
    x0, y0, x1, y1 = rear['mutableRegion']
    root_masks = []
    for polygon in rear.get('restoredRootPolygons') or []:
        mask = Image.new('L', (1024, 1024))
        ImageDraw.Draw(mask).polygon([tuple(p) for p in polygon], fill=255)
        root_masks.append(mask.tobytes())
    root_pixels = [0] * len(root_masks)
    for i in range(original.width * original.height):
        a, ka, ra = op[i * 4 + 3], kp[i * 4 + 3], rp[i * 4 + 3]
        gx = int(x + (i % original.width + .5) * scale)
        gy = int(top + (i // original.width + .5) * scale)
        if a and x0 <= gx < x1 and y0 <= gy < y1:
            for n, mask in enumerate(root_masks):
                if mask[gy * 1024 + gx]:
                    assert ka == a, 'Gathered root connection was removed'
                    root_pixels[n] += 1
        assert ka + ra == a and not (ka and ra), 'Rear source alpha lost, added or duplicated'
        if ka:
            assert kp[i * 4:i * 4 + 4] == op[i * 4:i * 4 + 4], 'Retained rear RGBA changed'
        if ra:
            assert rp[i * 4:i * 4 + 4] == op[i * 4:i * 4 + 4], 'Extracted rear RGBA changed'
            gx = int(x + (i % original.width + .5) * scale)
            gy = int(top + (i // original.width + .5) * scale)
            assert x0 <= gx < x1 and y0 <= gy < y1, 'Rear edit escaped its declared local region'
            changed += 1
    assert all(n > 300 for n in root_pixels), 'Restored root region does not contain enough source pixels'
    rear_cases.append({'variant': rear['variant'], 'retainedRGBAExact': True,
                       'partitionRestoresAlphaExactly': True, 'changedPixels': changed,
                       'restoredRootPixels': root_pixels,
                       'localRegionChecked': True})

baseline = ROOT / record['baselineRig']
base_renders = baseline.parent / 'renders'
suffixes = ['100', '200', '50', '100-mirror', '200-mirror', '50-mirror',
            'thinking-classic-0', 'thinking-classic-36', 'thinking-classic-49', 'thinking-classic-85',
            'thinking-0', 'thinking-36', 'thinking-49', 'thinking-85']
cases = []
for style in ['hair-style-high-twin', 'hair-style-low-twin-tied-v6']:
    for suffix in suffixes:
        name = style + '-' + suffix + '.png'
        before = Image.open(base_renders / name).convert('RGBA')
        after = Image.open(out / 'renders' / name).convert('RGBA')
        assert before.size == after.size
        difference = ImageChops.difference(before, after)
        changed = sum(any(pixel) for pixel in difference.get_flattened_data())
        cases.append({'file': name, 'differentPixels': changed})
        assert changed == 0, f'Reassembly changed {changed} pixels: {name}'
report = {'actualRenderer': 'CutoutArtwork', 'sourcePixelConservation': True,
          'paintedPixelCount': sum(v > 0 for v in expected_alpha),
          'sourceRGBAUnchangedForEveryPaintedPixel': True,
          'sourceAlphaRestoredExactly': True, 'rearCases': rear_cases, 'cases': cases, 'passed': True,
          'boundary': '28 complete RGBA render comparisons; continuous poses covered by hairstyle functional checks separately'}
(out / 'reassembly-render-check.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'PASS side-lock pixels: exact painted RGBA conservation and {len(cases)} unchanged actual-renderer comparisons')
