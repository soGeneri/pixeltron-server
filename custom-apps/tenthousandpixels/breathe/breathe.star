"""
Applet: Breathe
Summary: A guided breath, one per loop
Description: A glowing orb that grows as you breathe in, holds, and shrinks as you breathe out. One full breath plays each time the app comes round: box breathing, 4-7-8 or slow coherent breathing.
Author: TenThousandPixels
"""

load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

W = 64
H = 32
DELAY = 125  # 8 frames a second

HEX = "0123456789abcdef"

def hx(v):
    v = int(max(0, min(255, v)))
    return HEX[v // 16] + HEX[v % 16]

def rgb(c):
    return "#" + hx(c[0]) + hx(c[1]) + hx(c[2])

def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)

def add(a, b, k):
    return (a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k)

def pad2(v):
    return ("0" if v < 10 else "") + str(v)

def buf_to_widget(buf):
    rows = []
    for y in range(H):
        row = buf[y]
        kids = []
        start = 0
        for x in range(1, W + 1):
            if x == W or row[x] != row[start]:
                kids.append(render.Box(width = x - start, height = 1, color = row[start]))
                start = x
        rows.append(render.Row(children = kids))
    return render.Column(children = rows)

def outlined(text, font, color, shadow, bold = False):
    xs = [0, 1] if bold else [0]
    layers = []
    for d in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
        for bx in xs:
            layers.append(render.Padding(pad = (1 + d[0] + bx, 1 + d[1], 0, 0), child = render.Text(content = text, font = font, color = shadow)))
    for bx in xs:
        layers.append(render.Padding(pad = (1 + bx, 1, 0, 0), child = render.Text(content = text, font = font, color = color)))
    return render.Stack(children = layers)

CREAM = (255, 248, 239)
SUN = (255, 210, 63)
MIDNIGHT = (29, 21, 48)

# (label, seconds, orb start size, orb end size)
PATTERNS = {
    "box": [("IN", 3.5, 0.0, 1.0), ("HOLD", 3.5, 1.0, 1.0), ("OUT", 3.5, 1.0, 0.0), ("HOLD", 3.5, 0.0, 0.0)],
    "478": [("IN", 4, 0.0, 1.0), ("HOLD", 7, 1.0, 1.0), ("OUT", 8, 1.0, 0.0)],
    "coherent": [("IN", 5, 0.0, 1.0), ("OUT", 5, 1.0, 0.0)],
}

# ring colours from the core outwards
RINGS = [(255, 248, 239), (255, 143, 184), (255, 61, 79), (155, 93, 229), (63, 189, 240), (47, 210, 140)]

def ease(t):
    return 0.5 - 0.5 * math.cos(t * math.pi)

def ring_color(u):
    u = max(0.0, min(0.999, u)) * (len(RINGS) - 1)
    i = int(u)
    return mix(RINGS[i], RINGS[i + 1], u - i)

# per-pixel distance from the orb centre and a ring colour lookup, computed once
CX = 31.5
CY = 15.5
DIST = [[math.sqrt(((x - CX) * 0.9) * ((x - CX) * 0.9) + (y - CY) * (y - CY)) for x in range(W)] for y in range(H)]
HALO = [[math.exp(-d / 3.0) for d in row] for row in DIST]
STEPS = 48
RING_LUT = [ring_color(i / (STEPS - 1.0)) for i in range(STEPS)]

def frame(size):
    # background breathes too: deep plum, warming as the lungs fill
    top = mix((14, 10, 34), (60, 24, 90), size)
    low = mix((24, 40, 80), (120, 40, 100), size)
    cx = CX
    cy = CY
    radius = 4.0 + size * 12.0
    halo_k = math.exp(radius / 3.0) * (0.35 + 0.4 * size)
    edge = RING_LUT[int(0.9 * (STEPS - 1))]
    buf = []
    for y in range(H):
        row = []
        base = mix(top, low, y / (H - 1.0))
        drow = DIST[y]
        hrow = HALO[y]
        for x in range(W):
            d = drow[x]
            if d < radius:
                # banded orb, the bands slowly drifting outward
                u = d / radius
                band = (u * 3.0) % 1.0
                c = RING_LUT[int(u * (STEPS - 1))]
                c = mix(c, CREAM, 0.25 * (1.0 - band) * (1.0 - u))
                row.append(c)
            else:
                g = min(1.2, hrow[x] * halo_k)
                row.append((base[0] + edge[0] * g, base[1] + edge[1] * g, base[2] + edge[2] * g))
        buf.append(row)

    # dust motes that drift toward the orb on the inhale and away on the exhale
    for i in range(14):
        ang = i * 2.399 + size * 1.2
        r = 26 - size * 10 + (i % 4) * 2.5
        x = int(cx + math.cos(ang) * r * 1.1)
        y = int(cy + math.sin(ang) * r * 0.55)
        if x >= 0 and x < W and y >= 0 and y < H:
            buf[y][x] = mix(buf[y][x], CREAM, 0.7)

    buf[1][62] = SUN
    return [[rgb(c) for c in row] for row in buf]

def main(config):
    pattern = PATTERNS.get(config.get("pattern", "box"), PATTERNS["box"])
    fps = 1000 // DELAY

    # the picture depends only on how full the lungs are, so each size is drawn once
    cache = {}
    frames = []
    for step in pattern:
        label, secs, a, b = step
        n = int(secs * fps)
        for i in range(n):
            t = i / float(n)
            size = a + (b - a) * ease(t)
            left = int(math.ceil(secs - t * secs))
            word = render.Padding(pad = (1, 0, 0, 0), child = outlined(label, "tom-thumb", "#ffd23f", "#1d1530"))
            count = render.Padding(pad = (1, 18, 0, 0), child = outlined(str(left), "6x13", "#fff8ef", "#1d1530", bold = True))
            key = int(size * 40 + 0.5)
            if key not in cache:
                cache[key] = buf_to_widget(frame(key / 40.0))
            frames.append(render.Stack(children = [
                cache[key],
                word,
                count,
            ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "pattern",
                name = "Breath",
                desc = "The breathing pattern to guide.",
                icon = "wind",
                default = "box",
                options = [
                    schema.Option(display = "Box, 3.5 s each side (14 s)", value = "box"),
                    schema.Option(display = "4-7-8 to unwind (set display time to 20 s)", value = "478"),
                    schema.Option(display = "Coherent, 5 in 5 out (10 s)", value = "coherent"),
                ],
            ),
        ],
    )
