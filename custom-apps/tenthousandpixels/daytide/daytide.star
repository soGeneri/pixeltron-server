"""
Applet: Day Tide
Summary: Your workday as a rising sea
Description: A sea that rises through your workday while a little boat sails across, with the percentage done and the time left.
Author: TenThousandPixels
"""

load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

W = 64
H = 32
FRAMES = 40
DELAY = 100

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
CHERRY = (255, 61, 79)
MIDNIGHT = (29, 21, 48)

# boat sprite, 7 x 6: s = sail, m = mast, h = hull
BOAT = [
    "...m...",
    "..sm...",
    ".ssm...",
    "sssm...",
    "hhhhhhh",
    ".hhhhh.",
]

def surface(x, base, t):
    return base + 1.1 * math.sin(x * 0.23 + t) + 0.6 * math.sin(x * 0.57 - 2.0 * t)

def frame(t, p, night):
    # sky drifts from morning blue/sun to evening grape/cherry as the day goes on
    top = mix((120, 195, 250), (155, 93, 229), p)
    low = mix((255, 225, 150), (255, 120, 140), p)
    if night:
        top = (10, 6, 22)
        low = (60, 36, 110)
    buf = []
    for y in range(H):
        c = mix(top, low, y / (H - 1.0))
        buf.append([c for _ in range(W)])
    if night:
        for i, s in enumerate([(5, 3), (14, 8), (23, 2), (40, 6), (49, 2), (57, 9)]):
            buf[s[1]][s[0]] = add(buf[s[1]][s[0]], CREAM, 0.4 + 0.4 * math.sin(t * 2 + i))

    # the loose sun pixel
    buf[1][61] = SUN

    # water rises from 3px (start of day) to 3px from the top (end)
    base = (H - 3) - p * (H - 6)
    shallow = (63, 189, 240)
    deep = (40, 60, 170)
    if night:
        shallow = (70, 60, 160)
        deep = (20, 14, 50)
    for x in range(W):
        sy = surface(x, base, t)
        for y in range(H):
            if y >= sy:
                depth = (y - sy) / max(4.0, H - sy)
                c = mix(shallow, deep, depth)
                if y - sy < 1.0:
                    # foam crest where the wave is rising
                    crest = 0.5 + 0.5 * math.sin(x * 0.23 + t + 1.2)
                    c = mix(c, CREAM, 0.35 + 0.5 * crest)
                buf[y][x] = c

    # sparkles drifting along under the surface
    for i in range(6):
        sx = int((i * 11 + t / (2 * math.pi) * W * (0.5 + 0.1 * i)) % W)
        sy = int(surface(sx, base, t)) + 2 + (i % 3) * 3
        if sy < H:
            buf[sy][sx] = add(buf[sy][sx], CREAM, 0.6)

    # bubbles rise from the floor
    for i in range(4):
        bx = 6 + i * 15
        span = H - base
        if span > 4:
            by = int(H - 1 - ((t / (2 * math.pi) * span * 2 + i * 7) % span))
            if by > surface(bx, base, t) + 1:
                buf[by][bx] = mix(buf[by][bx], CREAM, 0.8)

    # the boat sails across with the day and bobs on the wave
    boat_x = int(2 + p * (W - 11))
    boat_y = int(surface(boat_x + 3, base, t)) - 5
    for r, line in enumerate(BOAT):
        for c, ch in enumerate(line.elems()):
            x = boat_x + c
            y = boat_y + r
            if x >= 0 and x < W and y >= 0 and y < H:
                if ch == "s":
                    buf[y][x] = CREAM
                elif ch == "m":
                    buf[y][x] = MIDNIGHT
                elif ch == "h":
                    buf[y][x] = CHERRY if r == 4 else (229, 33, 58)

    return [[rgb(c) for c in row] for row in buf]

def hm_left(mins):
    # "4H", "3H 5M" or "45M": hours and minutes always labelled
    if mins < 60:
        return str(mins) + "M"
    if mins % 60 == 0:
        return str(mins // 60) + "H"
    return "%dH %dM" % (mins // 60, mins % 60)

def parse_hm(s, fallback):
    parts = s.strip().split(":")
    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return fallback
    return int(parts[0]) * 60 + int(parts[1])

def fmt_hm(mins, use_24h):
    h = mins // 60
    m = mins % 60
    if use_24h:
        return pad2(h) + ":" + pad2(m)
    h12 = h % 12
    if h12 == 0:
        h12 = 12
    return str(h12) + ":" + pad2(m)

def main(config):
    tz = config.get("$tz", "America/New_York")
    now = time.now().in_location(tz)
    if config.get("now"):
        now = time.parse_time(config.get("now")).in_location(tz)
    use_24h = config.bool("24h", False)
    start = parse_hm(config.get("start", "09:00"), 540)
    end = parse_hm(config.get("end", "17:00"), 1020)
    if end <= start:
        end = start + 8 * 60
    weekdays_only = config.bool("weekdays", True)

    cur = now.hour * 60 + now.minute
    weekend = weekdays_only and now.format("Mon") in ["Sat", "Sun"]

    night = False
    if weekend:
        p = 0.15
        big = "WKND"
        small = "NO TIDE TODAY"
    elif cur < start:
        p = 0.0
        big = fmt_hm(start, use_24h)
        small = "DAY STARTS"
    elif cur >= end:
        p = 1.0
        night = True
        big = "DONE"
        small = "SEE YOU " + fmt_hm(start, use_24h)
    else:
        p = (cur - start) / float(end - start)
        left = end - cur
        big = str(int(p * 100)) + "%"
        small = hm_left(left) + " LEFT"

    # text sits on the side away from the boat: the big number up top,
    # the small line along the bottom
    boat_x = 2 + p * (W - 11)
    bx = 1
    sx = 1
    if boat_x < 30:
        bx = W - 3 - len(big) * 7
        sx = W - 3 - len(small) * 4

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(t, p, night)),
            render.Padding(pad = (bx, 0, 0, 0), child = outlined(big, "6x13", "#fff8ef", "#1d1530", bold = True)),
            render.Padding(pad = (sx, 24, 0, 0), child = outlined(small, "tom-thumb", "#ffd23f", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "start", name = "Day starts", desc = "Start of your day, 24-hour HH:MM.", icon = "sun", default = "09:00"),
            schema.Text(id = "end", name = "Day ends", desc = "End of your day, 24-hour HH:MM.", icon = "moon", default = "17:00"),
            schema.Toggle(id = "weekdays", name = "Weekdays only", desc = "Rest the tide on Saturday and Sunday.", icon = "calendar", default = True),
            schema.Toggle(id = "24h", name = "24-hour time", desc = "Show times in 24-hour format.", icon = "clock", default = False),
        ],
    )
