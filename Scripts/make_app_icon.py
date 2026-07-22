"""
TidyGallery app icon.

The product in one image: a messy stack of near-identical shots, and the app
picking the one worth keeping. Three offset frames, the front one upright and
bright with a star badge; the two behind tilted and translucent.

The front frame's interior is a full-bleed landscape rather than a bar on white,
because a white card with a stripe reads as a UI element, not a photograph. At
40px the whole thing needs to say "photo, starred" and nothing else.

Colours are the app's own accent (Theme.Colors.accent, 0x4C5BD4 / 0x8B95F2), so
the icon and the interface agree.

RGB, no alpha: iOS applies the rounded-rect mask itself, and App Store Connect
rejects icons carrying an alpha channel.
"""
from PIL import Image, ImageDraw
import math

S = 1024
ACCENT_DARK  = (0x3A, 0x46, 0xB0)
ACCENT       = (0x4C, 0x5B, 0xD4)
ACCENT_LIGHT = (0x8B, 0x95, 0xF2)
WHITE        = (255, 255, 255)

def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

img = Image.new("RGB", (S, S), ACCENT)
d = ImageDraw.Draw(img)
for i in range(S * 2):
    d.line([(i, 0), (0, i)], fill=lerp(ACCENT_LIGHT, ACCENT_DARK, i / (S * 2 - 1)))

SS = 2   # supersample factor for every rotated/curved element

def rotated_frame(cx, cy, w, h, angle, fill, outline=None, ow=0, radius=46):
    pad = 40 * SS
    layer = Image.new("RGBA", (int(w*SS)+pad*2, int(h*SS)+pad*2), (0,0,0,0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [pad, pad, pad+int(w*SS), pad+int(h*SS)],
        radius=radius*SS, fill=fill, outline=outline, width=ow*SS)
    layer = layer.rotate(angle, resample=Image.BICUBIC, expand=True)
    layer = layer.resize((layer.width//SS, layer.height//SS), Image.LANCZOS)
    img.paste(layer, (int(cx-layer.width/2), int(cy-layer.height/2)), layer)

CX, CY = S//2, int(S*0.485)
W = H = int(S*0.44)

# The rejects: further out and more tilted than before, so the stack is legible
# at small sizes instead of hiding behind the keeper.
rotated_frame(CX-int(S*0.075), CY+int(S*0.020), W, H, 13, (255,255,255,70),
              outline=(255,255,255,105), ow=5)
rotated_frame(CX+int(S*0.072), CY+int(S*0.012), W, H, -10, (255,255,255,100),
              outline=(255,255,255,130), ow=5)

# The keeper. Border drawn as a white rounded rect, photo inset inside it —
# the white margin is the print border, which is what makes it read as a photo.
FX, FY = CX, CY-int(S*0.030)
rotated_frame(FX, FY, W, H, 0, WHITE)

inset = 30
px0, py0 = FX-W//2+inset, FY-H//2+inset
px1, py1 = FX+W//2-inset, FY+H//2-inset
pw, ph = px1-px0, py1-py0

# Full-bleed interior, built on its own layer then rounded-masked, so the
# landscape reaches the photo's edges instead of floating on white.
photo = Image.new("RGB", (pw*SS, ph*SS), ACCENT_LIGHT)
pd = ImageDraw.Draw(photo)
for i in range(ph*SS):                                   # sky
    pd.line([(0,i), (pw*SS,i)],
            fill=lerp(lerp(ACCENT_LIGHT, WHITE, 0.55), ACCENT_LIGHT, i/(ph*SS)))
pd.ellipse([pw*SS*0.62, ph*SS*0.13, pw*SS*0.86, ph*SS*0.37], fill=WHITE)  # sun
pd.polygon([(-10, ph*SS), (pw*SS*0.42, ph*SS*0.44), (pw*SS*0.78, ph*SS)],
           fill=ACCENT)                                   # far peak
pd.polygon([(pw*SS*0.30, ph*SS), (pw*SS*0.68, ph*SS*0.56), (pw*SS+10, ph*SS)],
           fill=ACCENT_DARK)                              # near peak
mask = Image.new("L", (pw*SS, ph*SS), 0)
ImageDraw.Draw(mask).rounded_rectangle([0,0,pw*SS,ph*SS], radius=24*SS, fill=255)
photo = photo.resize((pw, ph), Image.LANCZOS)
mask  = mask.resize((pw, ph), Image.LANCZOS)
img.paste(photo, (px0, py0), mask)

# Star badge — the same "best shot" mark the review UI uses.
def star(cx, cy, r_out, r_in, fill, points=5, rot=-90):
    pts = []
    for i in range(points*2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot + i*180/points)
        pts.append((cx + r*math.cos(a), cy + r*math.sin(a)))
    d.polygon(pts, fill=fill)

BX, BY, BR = int(S*0.755), int(S*0.745), int(S*0.135)
badge = Image.new("RGBA", (BR*2*SS+8*SS, BR*2*SS+8*SS), (0,0,0,0))
bd = ImageDraw.Draw(badge)
bd.ellipse([0,0,BR*2*SS,BR*2*SS], fill=ACCENT_DARK+(255,))
bd.ellipse([14*SS,14*SS,BR*2*SS-14*SS,BR*2*SS-14*SS], fill=WHITE+(255,))
badge = badge.resize((badge.width//SS, badge.height//SS), Image.LANCZOS)
img.paste(badge, (BX-BR, BY-BR), badge)
star(BX, BY, BR*0.60, BR*0.25, ACCENT_DARK)

img.save("icon-1024.png", "PNG")
im = Image.open("icon-1024.png")
im.resize((180,180), Image.LANCZOS).save("preview-180.png")
im.resize((60,60), Image.LANCZOS).resize((240,240), Image.NEAREST).save("preview-60-zoom.png")
print("ok", im.size, im.mode)
