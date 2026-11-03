"""
Applet: Launch Pad
Summary: Next rocket launch countdown
Description: The next orbital launch anywhere on Earth: a rocket venting on a lit tower under a dawn sky, with the mission name, a T-minus countdown and whether it is go. Data from Launch Library 2, no key needed.
Author: TenThousandPixels
"""

load("http.star", "http")
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
SKY = (63, 189, 240)
MIDNIGHT = (29, 21, 48)

URL = "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=6&mode=list&hide_recent_previous=true"

STARS = [(3, 2), (9, 7), (16, 3), (24, 9), (30, 1), (36, 6), (55, 2), (61, 8), (21, 13), (6, 15)]

TX = 44  # tower left edge
RX = 50  # rocket left edge

def put(buf, x, y, c):
    if x >= 0 and x < W and y >= 0 and y < H:
        buf[y][x] = c

def frame(t, f, imminent):
    buf = []
    for y in range(H):
        u = y / (H - 1.0)
        if u < 0.6:
            c = mix((12, 8, 30), (80, 40, 130), u / 0.6)
        else:
            c = mix((80, 40, 130), (255, 110, 100), (u - 0.6) / 0.4)
        buf.append([c for _ in range(W)])

    for i, s in enumerate(STARS):
        buf[s[1]][s[0]] = add(buf[s[1]][s[0]], CREAM, 0.3 + 0.35 * math.sin(t * 2 + i * 1.3))

    # two searchlights sweeping up from the pad
    for k in range(2):
        ang = -math.pi / 2 + (0.35 + 0.15 * math.sin(t + k * 3)) * (1 if k else -1)
        ox = RX + 2
        for r in range(4, 40):
            for w in [-1, 0, 1]:
                x = int(ox + math.cos(ang) * r + w * math.sin(ang) * (r / 14.0))
                y = int(29 + math.sin(ang) * r)
                if x >= 0 and x < W and y >= 0 and y < H:
                    buf[y][x] = mix(buf[y][x], (255, 230, 170), 0.32 * (1 - r / 40.0))

    # distant hills against the dawn glow
    for x in range(W):
        top = int(25 + 1.5 * math.sin(x * 0.17 + 0.8) + math.sin(x * 0.43))
        for y in range(top, 29):
            buf[y][x] = mix((70, 30, 90), (40, 20, 60), (y - top) / 4.0)

    # ground and pad
    for x in range(W):
        for y in range(29, H):
            buf[y][x] = mix((40, 26, 60), MIDNIGHT, (y - 29) / 2.0)

    # tower: lattice with crossbars and a blinking light
    for y in range(5, 29):
        put(buf, TX, y, MIDNIGHT)
        put(buf, TX + 3, y, MIDNIGHT)
        if (y - 5) % 3 == 0:
            for x in range(TX, TX + 4):
                put(buf, x, y, MIDNIGHT)
        else:
            put(buf, TX + 1 + (y % 2), y, (60, 40, 80))
    for y in [9, 17, 24]:
        for x in range(TX + 4, RX):
            put(buf, x, y, MIDNIGHT)
    if f % 10 < 5:
        put(buf, TX + 1, 4, CHERRY)
        put(buf, TX + 2, 4, CHERRY)

    # rocket: cherry nose, cream body with a sky band, fins
    for y in range(7, 28):
        for x in range(RX, RX + 4):
            c = CREAM if x < RX + 3 else (215, 205, 220)
            if y < 10:
                w = y - 7
                if x - RX < 2 - w // 2 or x - RX > 1 + (w + 1) // 2:
                    continue
                c = CHERRY
            elif y in [15, 16]:
                c = SKY
            put(buf, x, y, c)
    for y in [25, 26, 27]:
        put(buf, RX - 1, y, CHERRY)
        put(buf, RX + 4, y, CHERRY)
    put(buf, RX + 1, 12, (40, 60, 120))

    # engine glow when launch is close
    if imminent:
        for x in range(RX, RX + 4):
            put(buf, x, 28, mix(SUN, CHERRY, 0.5 + 0.5 * math.sin(t * 6 + x)))

    # vapour venting from the base, billowing out and fading
    for i in range(6):
        age = ((f + i * 7) % 40) / 40.0
        side = 1 if i % 2 else -1
        cx = RX + 2 + side * (3 + age * 14)
        cy = 27 - age * 4
        r = 1.2 + age * 2.6
        a = 0.85 * (1 - age)
        for y in range(int(cy - r), int(cy + r) + 1):
            for x in range(int(cx - r - 1), int(cx + r + 2)):
                dx = (x - cx) / 1.3
                dy = y - cy
                if dx * dx + dy * dy < r * r and x >= 0 and x < W and y >= 0 and y < H:
                    buf[y][x] = mix(buf[y][x], CREAM, a)

    buf[1][62] = SUN
    return [[rgb(c) for c in row] for row in buf]

def countdown(d):
    mins = int(d.minutes)
    if mins < 0:
        return "LIFTOFF"
    days = mins // 1440
    hrs = (mins % 1440) // 60
    m = mins % 60
    if days > 0:
        return "T-%dD %dH" % (days, hrs)
    if hrs > 0:
        return "T-%dH %dM" % (hrs, m)
    return "T-%dM" % m

def main(config):
    go_only = config.bool("go_only", False)
    resp = http.get(URL, ttl_seconds = 3600)
    if resp.status_code != 200:
        return render.Root(child = render.Box(color = "#1d1530", child = render.Text("NO LAUNCHES", font = "tom-thumb", color = "#ffd23f")))

    now = time.now()
    launch = None
    for r in resp.json().get("results", []):
        net = time.parse_time(r["net"])
        if go_only and r.get("status", {}).get("abbrev") != "Go":
            continue
        if net > now - time.parse_duration("30m"):
            launch = r
            break
    if launch == None:
        return render.Root(child = render.Box(color = "#1d1530", child = render.Text("NO LAUNCHES", font = "tom-thumb", color = "#ffd23f")))

    net = time.parse_time(launch["net"])
    left = net - now
    imminent = left.minutes < 60
    status = launch.get("status", {}).get("abbrev", "TBD").upper()
    where = launch.get("location", "").split(",")[-1].strip().upper()
    if where.startswith("PEOPLE"):
        where = "CHINA"
    name = launch["name"].upper().replace(" | ", " / ")

    bg = render.Animation(children = [buf_to_widget(frame(f * 2.0 * math.pi / FRAMES, f, imminent)) for f in range(FRAMES)])
    status_col = "#2fd28c" if status == "GO" else "#ffd23f"
    return render.Root(
        delay = DELAY,
        show_full_animation = True,
        child = render.Stack(children = [
            bg,
            render.Padding(pad = (0, 1, 0, 0), child = render.Marquee(
                width = 42,
                offset_start = 8,
                child = render.Text(name, font = "tom-thumb", color = "#ffd23f"),
            )),
            render.Padding(pad = (0, 8, 0, 0), child = outlined(countdown(left), "tb-8", "#fff8ef", "#1d1530")),
            render.Padding(pad = (0, 24, 0, 0), child = outlined(status + " " + where, "tom-thumb", status_col, "#1d1530")),
        ]),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Toggle(id = "go_only", name = "Only confirmed launches", desc = "Skip launches whose date is not confirmed yet.", icon = "rocket", default = False),
        ],
    )
