"""
Applet: Aurora Clock
Summary: Clock under the northern lights
Description: The time and date over animated northern lights, a starry sky and a pine ridge.
Author: TenThousandPixels
"""

load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

W = 64
H = 32
FRAMES = 48
DELAY = 90

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
    # Text with a 1px dark outline so it reads over any background.
    # Bold draws the glyphs twice, one pixel apart.
    xs = [0, 1] if bold else [0]
    layers = []
    for d in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
        for bx in xs:
            layers.append(render.Padding(pad = (1 + d[0] + bx, 1 + d[1], 0, 0), child = render.Text(content = text, font = font, color = shadow)))
    for bx in xs:
        layers.append(render.Padding(pad = (1 + bx, 1, 0, 0), child = render.Text(content = text, font = font, color = color)))
    return render.Stack(children = layers)

# ---------- scene ----------

SKY_TOP = (10, 6, 22)
SKY_LOW = (34, 22, 66)
GREEN = (47, 210, 140)  # mint
TEAL = (63, 189, 240)  # sky
PINK = (255, 143, 184)  # bubble
VIOLET = (155, 93, 229)  # grape

STARS = [(3, 2), (11, 6), (19, 1), (27, 4), (36, 2), (44, 7), (52, 3), (60, 5), (7, 11), (57, 10), (31, 9), (48, 1), (15, 13), (40, 12)]

def ridge(x):
    return int(25 + 2.2 * math.sin(x * 0.19 + 1.0) + 1.6 * math.sin(x * 0.47 + 2.0))

def tree_mask():
    # Small pines along the ridge: (x, height)
    trees = {}
    for i, x in enumerate([2, 6, 9, 15, 21, 24, 30, 37, 41, 46, 50, 55, 59, 62]):
        trees[x] = 4 + (i * 7) % 4
    mask = {}
    for x in trees:
        top = ridge(x) - trees[x]
        for y in range(top, ridge(x) + 1):
            half = (y - top) // 2
            for dx in range(-half, half + 1):
                mask[(x + dx, y)] = True
    return mask

def frame(t, tmask, palette_shift):
    buf = []
    for y in range(H):
        sky = mix(SKY_TOP, SKY_LOW, y / (H - 1.0))
        buf.append([sky for _ in range(W)])

    # stars twinkle
    for i, s in enumerate(STARS):
        b = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 2.3 + i * 1.7))
        buf[s[1]][s[0]] = add(buf[s[1]][s[0]], (255, 240, 220), b * 0.85)

    # the loose sun pixel: one star in brand yellow, top right
    buf[1][61] = (255, 210, 63)

    # two aurora curtains
    for x in range(W):
        rays = 0.55 + 0.45 * math.sin(x * 0.85 + t * 1.6 + 2.0 * math.sin(x * 0.21 + t * 0.5))
        c1 = 13.0 + 3.5 * math.sin(x * 0.12 + t * 0.7) + 2.0 * math.sin(x * 0.31 - t * 0.45)
        c2 = 9.0 + 3.0 * math.sin(x * 0.09 - t * 0.55 + 2.4) + 1.5 * math.sin(x * 0.27 + t * 0.8)
        for y in range(H):
            col = buf[y][x]

            # curtain 1: green base, teal-violet top
            d = c1 - y
            if d > -1.5 and d < 14:
                if d < 0:
                    k = (1.5 + d) / 1.5
                else:
                    k = math.exp(-d / 4.5)
                c = mix(GREEN, TEAL, d / 5.0) if d < 5 else mix(TEAL, VIOLET, (d - 5) / 5.0)
                col = add(col, c, k * rays * 0.9)

            # curtain 2: magenta, fainter
            d = c2 - y
            if d > -1.0 and d < 10:
                if d < 0:
                    k = 1.0 + d
                else:
                    k = math.exp(-d / 3.5)
                col = add(col, mix(PINK, VIOLET, d / 9.0), k * (0.15 + 0.2 * rays) * palette_shift)
            buf[y][x] = col

    # mountain ridge + pines, with a thin aurora rim light
    for x in range(W):
        top = ridge(x)
        for y in range(H):
            if y >= top or tmask.get((x, y)):
                depth = (y - top) / 8.0
                base = mix((12, 8, 24), (5, 3, 12), depth)
                buf[y][x] = base

    # lake shimmer at the bottom: reflection of the aurora green
    for x in range(W):
        y = H - 2
        k = 0.5 + 0.5 * math.sin(x * 0.7 - t * 3.0)
        if k > 0.75:
            buf[y][x] = add(buf[y][x], GREEN, (k - 0.75) * 1.6)

    return [[rgb(c) for c in row] for row in buf]

def main(config):
    tz = config.get("$tz", "America/New_York")
    now = time.now().in_location(tz)
    use_24h = config.bool("24h", False)

    if use_24h:
        hh = now.format("15")
    else:
        hh = now.format("3")
    mm = now.format("04")
    date = now.format("Mon Jan 2").upper()

    tmask = tree_mask()
    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        bg = buf_to_widget(frame(t, tmask, 1.0))
        colon = ":" if f < FRAMES // 2 else " "
        clock = outlined(hh + colon + mm, "6x13", "#fff8ef", "#1d1530", bold = True)
        frames.append(render.Stack(children = [
            bg,
            render.Box(width = W, height = 22, child = render.Padding(pad = (0, 3, 0, 0), child = clock)),
            render.Padding(pad = (0, 25, 0, 0), child = render.Box(width = W, height = 7, child = render.Text(content = date, font = "tom-thumb", color = "#ffd23f"))),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Toggle(id = "24h", name = "24-hour time", desc = "Show the time in 24-hour format.", icon = "clock", default = False),
        ],
    )
