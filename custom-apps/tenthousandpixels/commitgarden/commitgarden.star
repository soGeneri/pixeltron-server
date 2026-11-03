"""
Applet: Commit Garden
Summary: Your GitHub activity as flowers
Description: The last three weeks of your GitHub contributions grown as a garden: one flower per day, taller and bigger the more you shipped, with today's count and your streak.
Author: TenThousandPixels
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

W = 64
H = 32
FRAMES = 32
DELAY = 120
DAYS = 21

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
STEM = (20, 140, 90)
LEAF = (47, 210, 140)
BLOOMS = [(255, 61, 79), (255, 143, 184), (155, 93, 229), (63, 189, 240), (255, 160, 60)]

def fetch(user):
    resp = http.get("https://github-contributions-api.jogruber.de/v4/%s?y=last" % user, ttl_seconds = 1800)
    if resp.status_code != 200:
        return None
    return resp.json().get("contributions")

def put(buf, x, y, c):
    if x >= 0 and x < W and y >= 0 and y < H:
        buf[y][x] = c

def frame(days, t):
    buf = []
    for y in range(H):
        c = mix((120, 200, 250), (255, 236, 190), y / (H - 1.0))
        buf.append([c for _ in range(W)])

    # two soft clouds drifting
    for i in range(2):
        cx = (i * 34 + t / (2 * math.pi) * 64) % 80 - 8
        cy = 10 + i * 4
        for y in range(cy - 2, cy + 1):
            for x in range(int(cx) - 5, int(cx) + 6):
                dx = (x - cx) / 5.0
                dy = (y - cy + 0.5) / 1.6
                if dx * dx + dy * dy < 1.0 and x >= 0 and x < W:
                    buf[y][x] = mix(buf[y][x], CREAM, 0.8)

    # ground: grass then soil
    for x in range(W):
        top = 28 + (1 if (x * 7) % 5 == 0 else 0)
        for y in range(top, H):
            put(buf, x, y, mix(LEAF, (60, 40, 50), (y - 28) / 3.0))

    for i, d in enumerate(days):
        count = int(d["count"])
        x = 1 + i * 3
        if count == 0:
            # a sprout
            put(buf, x, 27, LEAF)
            put(buf, x + 1, 26, LEAF)
            continue
        h = int(4 + min(15.0, 4.2 * math.log(1 + count) / math.log(2)))
        sway = math.sin(t + i * 0.8)
        top = 28 - h
        for y in range(top, 28):
            # top third of the stem leans with the breeze
            dx = int(math.round(sway * 0.8)) if y < top + h // 3 else 0
            put(buf, x + dx, y, STEM)

        # one leaf on alternating sides
        ly = 28 - h // 2
        put(buf, x + (1 if i % 2 else -1), ly, LEAF)
        put(buf, x + (2 if i % 2 else -2), ly - 1, LEAF)

        bx = x + int(math.round(sway * 0.8))
        col = BLOOMS[i % len(BLOOMS)]
        lvl = int(d.get("level", 1))
        if i == len(days) - 1:
            # today's bloom pulses
            col = mix(col, CREAM, 0.3 + 0.3 * math.sin(t * 2))
        petals = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        if lvl >= 3:
            petals += [(-1, -1), (1, -1), (-1, 1), (1, 1), (-2, 0), (2, 0), (0, -2)]
        elif lvl >= 2:
            petals += [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        for p in petals:
            put(buf, bx + p[0], top + p[1], col)
        put(buf, bx, top, CREAM)

    # the bee: the loose sun pixel, buzzing between the blooms
    bx = int(32 + 26 * math.sin(t))
    by = int(14 + 4 * math.sin(t * 3))
    put(buf, bx, by, SUN)
    put(buf, bx - 1, by, MIDNIGHT)
    if int(t * 4) % 2 == 0:
        put(buf, bx, by - 1, CREAM)

    return [[rgb(c) for c in row] for row in buf]

def main(config):
    user = config.get("user", "soGeneri").strip().lstrip("@")
    contribs = fetch(user)
    if contribs == None or len(contribs) == 0:
        return render.Root(child = render.Box(color = "#1d1530", child = render.WrappedText("NO GARDEN FOR " + user.upper(), font = "tom-thumb", color = "#ffd23f", align = "center")))

    today = time.now().in_location(config.get("$tz", "America/New_York")).format("2006-01-02")

    # keep everything up to today, then the last three weeks of it
    upto = [c for c in contribs if c["date"] <= today]
    days = upto[-DAYS:]

    streak = 0
    for c in reversed(upto):
        if c["count"] > 0:
            streak += 1
        elif c["date"] != today:
            break
    left = "TODAY " + str(int(days[-1]["count"]))
    right = "RUN " + str(streak) + "D"

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(days, t)),
            render.Padding(pad = (0, 0, 0, 0), child = outlined(left, "tom-thumb", "#fff8ef", "#1d1530")),
            render.Padding(pad = (W - 2 - len(right) * 4, 0, 0, 0), child = outlined(right, "tom-thumb", "#ffd23f", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "user", name = "GitHub user", desc = "Whose garden to grow.", icon = "github", default = "soGeneri"),
        ],
    )
