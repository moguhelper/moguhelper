"""python3 tools/glyphs/build.py Sources/TranslatorCore/Glyphs.json（要 Pillow；字体用系统的 Arial）
游戏里的字是 Arial 不抗锯齿画的，按字号生成每个字符的点阵：{字号: {字符: [前进, 左边距, 基线以上几行, [每行的位]]}}"""
import sys, json
from PIL import Image, ImageDraw, ImageFont
out = {}
for size in (11, 12, 13, 14, 15, 16):
    f = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', size, layout_engine=ImageFont.Layout.BASIC)
    t = {}
    for o in range(32, 127):
        c = chr(o); im = Image.new('1', (64, 64)); d = ImageDraw.Draw(im); d.fontmode = '1'
        d.text((20, 40), c, font=f, fill=1, anchor='ls')
        p = [(x, y) for y in range(64) for x in range(64) if im.getpixel((x, y))]
        adv = round(f.getlength(c))
        if not p: t[c] = [adv, 0, 0, []]; continue
        x0, x1 = min(x for x, _ in p), max(x for x, _ in p); y0, y1 = min(y for _, y in p), max(y for _, y in p)
        # v、y 这类斜边字 FreeType 会多往左一列，游戏里不会（量过）
        left = x0 - 20
        if left < 0 and c in 'vyVWYAXTw': left = 0
        t[c] = [adv, left, 40 - y0, [sum(1 << (x - x0) for x, y in p if y == r) for r in range(y0, y1 + 1)]]
    # 12 号的 t、f 游戏里画得不一样（从 41、4 处实拍量的）
    if size == 12:
        B = lambda *r: [sum(1 << i for i, k in enumerate(x) if k == '#') for x in r]
        t['t'] = [t['t'][0], 0, 9, B('.#', '.#', '###', '.#', '.#', '.#', '.#', '.#', '.##')]
        t['f'] = [t['f'][0], 0, 9, B('..#', '.#', '###', '.#', '.#', '.#', '.#', '.#', '.#')]
    out[size] = t
json.dump(out, open(sys.argv[1], 'w'), ensure_ascii=False, separators=(',', ':'))
