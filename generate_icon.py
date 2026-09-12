"""Viewer DUO icon: an open cream book on a walnut desk, right page mid-curl."""
from PIL import Image, ImageDraw, ImageFilter
import math, random

SIZE = 1024
random.seed(12)

# --- walnut desk -----------------------------------------------------------
img = Image.new('RGB', (SIZE, SIZE), (60, 38, 24))
px = img.load()
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)
        r = int(92 - 50 * t)
        g = int(60 - 32 * t)
        b = int(38 - 20 * t)
        px[x, y] = (r, g, b)
grain = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(grain)
for i in range(0, SIZE, 7):
    amp = random.uniform(2, 9)
    freq = random.uniform(0.004, 0.011)
    ph = random.uniform(0, 6.3)
    pts = [(x, i + math.sin(x * freq + ph) * amp) for x in range(-10, SIZE + 10, 16)]
    gd.line(pts, fill=(30, 16, 8, random.randint(30, 80)), width=random.choice([1, 1, 2]))
grain = grain.filter(ImageFilter.GaussianBlur(0.6))
img = Image.alpha_composite(img.convert('RGBA'), grain)

# vignette
vig = Image.new('L', (SIZE, SIZE), 0)
vd = ImageDraw.Draw(vig)
for k in range(40):
    a = int(255 * (k / 40) ** 2 * 0.55)
    inset = int(k * SIZE / 80)
    vd.rectangle([inset, inset, SIZE - inset, SIZE - inset], outline=a)
vig = vig.filter(ImageFilter.GaussianBlur(40))
dark = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 255))
img = Image.composite(img, dark, vig.point(lambda v: 255 - v))

# --- book ------------------------------------------------------------------
cream = (247, 240, 224)
cream_dark = (222, 212, 190)
ink = (120, 108, 92)

book = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
bd = ImageDraw.Draw(book)

left = 150
right = SIZE - 150
top = 210
bottom = SIZE - 190
mid = SIZE // 2

# drop shadow
sh = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
sd = ImageDraw.Draw(sh)
sd.rectangle([left + 10, top + 26, right - 10, bottom + 30], fill=(0, 0, 0, 150))
sh = sh.filter(ImageFilter.GaussianBlur(28))
book = Image.alpha_composite(book, sh)
bd = ImageDraw.Draw(book)

# page stacks
for i in range(6, 0, -1):
    shade = 232 - i * 6
    bd.rectangle([left - i * 3, top + i * 2, mid - 2, bottom + i * 2], fill=(shade, shade - 8, shade - 26))
    bd.rectangle([mid + 2, top + i * 2, right + i * 3, bottom + i * 2], fill=(shade, shade - 8, shade - 26))

# left page
bd.rectangle([left, top, mid - 2, bottom], fill=cream)
# right page
bd.rectangle([mid + 2, top, right, bottom], fill=cream)

# gutter shading
gut = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
gdw = ImageDraw.Draw(gut)
for k in range(70):
    a = int(90 * (1 - k / 70) ** 2)
    gdw.line([(mid - 2 - k, top), (mid - 2 - k, bottom)], fill=(80, 60, 40, a))
    gdw.line([(mid + 2 + k, top), (mid + 2 + k, bottom)], fill=(80, 60, 40, a))
book = Image.alpha_composite(book, gut)
bd = ImageDraw.Draw(book)

# text lines
def lines(x0, x1, y0, y1, seed):
    random.seed(seed)
    y = y0
    while y < y1:
        w = random.uniform(0.62, 1.0)
        bd.line([(x0, y), (x0 + (x1 - x0) * w, y)], fill=ink, width=6)
        y += 30
lines(left + 60, mid - 60, top + 80, bottom - 90, 1)
lines(mid + 60, right - 60, top + 80, bottom - 300, 2)

# --- curl on the right page ---------------------------------------------
# The bottom-right corner is lifted toward the spine: draw the flipped flap and its cylinder highlight.
cx, cy = right, bottom            # original corner
fx, fy = mid + 150, top + 330     # where the corner now sits
# fold line: perpendicular bisector of (corner -> finger)
mx, my = (cx + fx) / 2, (cy + fy) / 2
dx, dy = fx - cx, fy - cy
L = math.hypot(dx, dy)
nx, ny = dx / L, dy / L           # direction corner -> finger
tx, ty = -ny, nx                  # along the fold

# region of the page beyond the fold (to be replaced by the paper underneath)
big = 2000
fold_poly = [(mx + tx * big, my + ty * big), (mx - tx * big, my - ty * big),
             (mx - tx * big - nx * big * -1, my - ty * big - ny * big * -1)]
# Simpler: mask by half-plane using per-pixel test
flap_mask = Image.new('L', (SIZE, SIZE), 0)
fm = flap_mask.load()
under = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
ud = ImageDraw.Draw(under)
ud.rectangle([mid + 2, top, right, bottom], fill=(236, 228, 208))
lines_u = ImageDraw.Draw(under)
for yy in range(top + 80, bottom - 60, 30):
    lines_u.line([(mid + 60, yy), (mid + 60 + (right - mid - 120) * 0.8, yy)], fill=(160, 150, 134), width=6)

flap = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
fp = flap.load()
up = under.load()
bp = book.load()
for y in range(top, bottom + 1):
    for x in range(mid + 2, right + 1):
        d = (x - mx) * (-nx) + (y - my) * (-ny)   # >0 : beyond fold (toward corner)
        if d > 0:
            # paper underneath becomes visible here, with a soft shadow near the fold
            s = max(0.0, 1 - d / 90.0)
            r, g, b, a = up[x, y]
            k = 1 - 0.45 * s
            bp[x, y] = (int(r * k), int(g * k), int(b * k), 255)
            # mirrored point of the flap lands at reflection across the fold line
            rx = x - 2 * d * (-nx)
            ry = y - 2 * d * (-ny)
            if mid + 2 <= rx <= right and top <= ry <= bottom:
                pass
# draw flap: the flipped part of the page, reflected across the fold line.
# Iterate over destination pixels so the fill has no gaps.
for y in range(top, bottom + 1):
    for x in range(mid + 2, right + 1):
        dq = (x - mx) * (-nx) + (y - my) * (-ny)   # <0 : on the flap side of the fold
        if dq < 0:
            sx = x - 2 * dq * (-nx)
            sy = y - 2 * dq * (-ny)
            if mid + 2 <= sx <= right and top <= sy <= bottom:
                edge = min(1.0, -dq / 70.0)
                shade = 0.70 + 0.30 * edge
                fp[x, y] = (int(250 * shade), int(244 * shade), int(230 * shade), 255)
flap = flap.filter(ImageFilter.GaussianBlur(0.4))
# shadow of the flap onto the page
fs = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
fsp = fs.load()
fl = flap.load()
for y in range(SIZE):
    for x in range(SIZE):
        if fl[x, y][3] > 0:
            xx, yy = min(SIZE - 1, x + 14), min(SIZE - 1, y + 18)
            fsp[xx, yy] = (0, 0, 0, 120)
fs = fs.filter(ImageFilter.GaussianBlur(16))
book = Image.alpha_composite(book, fs)
book = Image.alpha_composite(book, flap)

# highlight line along the fold crest
hl = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
hd.line([(mx + tx * 900, my + ty * 900), (mx - tx * 900, my - ty * 900)], fill=(255, 255, 255, 90), width=10)
hl = hl.filter(ImageFilter.GaussianBlur(6))
book_mask = Image.new('L', (SIZE, SIZE), 0)
ImageDraw.Draw(book_mask).rectangle([mid + 2, top, right, bottom], fill=255)
hl.putalpha(Image.composite(hl.split()[3], Image.new('L', (SIZE, SIZE), 0), book_mask))
book = Image.alpha_composite(book, hl)

img = Image.alpha_composite(img, book)

# brass ornament: small "DUO" bar at the bottom
od = ImageDraw.Draw(img)
brass = (214, 176, 98)
od.rounded_rectangle([SIZE // 2 - 120, SIZE - 120, SIZE // 2 + 120, SIZE - 96], radius=12, fill=brass)

out = img.convert('RGB')
out.save('AppIcon.png')
out.save('ViewerDUO/Assets.xcassets/AppIcon.appiconset/icon_1024.png')
print('icon written')
