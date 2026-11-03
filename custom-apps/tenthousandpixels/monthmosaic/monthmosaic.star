"""
Applet: Month Mosaic
Summary: The month as a wall of tiles
Description: Today's date beside the whole month drawn as glowing tiles: days gone by in candy colours, today pulsing, the rest of the month waiting in the dark.
Author: TenThousandPixels
"""

load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

W = 64
H = 32
FRAMES = 32
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

# brand candy ramp the past days walk through
RAMP = [(255, 61, 79), (255, 143, 184), (255, 210, 63), (47, 210, 140), (63, 189, 240), (155, 93, 229)]

def ramp(u):
    u = max(0.0, min(0.999, u)) * (len(RAMP) - 1)
    i = int(u)
    return mix(RAMP[i], RAMP[i + 1], u - i)

TW = 5  # tile width
TH = 3  # tile height
GX = 1
GY = 1

def days_in_month(y, m):
    if m == 12:
        nxt = time.time(year = y + 1, month = 1, day = 1)
    else:
        nxt = time.time(year = y, month = m + 1, day = 1)
    return int((nxt - time.time(year = y, month = m, day = 1)).hours / 24 + 0.5)

WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

def frame(t, today, ndays, first_col, weeks, monday_first):
    buf = []
    for y in range(H):
        row = []
        for x in range(W):
            # deep diagonal wash: midnight into grape
            u = (x + y * 1.5) / (W + H * 1.5)
            row.append(mix((22, 14, 44), (70, 30, 110), u))
        buf.append(row)

    # left panel tinted cherry
    for y in range(H):
        for x in range(21):
            buf[y][x] = mix((255, 61, 79), (200, 20, 50), y / (H - 1.0))
    buf[1][61] = SUN

    gw = 7 * (TW + GX) - GX
    gh = weeks * (TH + GY) - GY
    ox = W - gw - 1
    oy = (H - gh) // 2
    shimmer = (t / (2 * math.pi)) * 1.6 - 0.3

    for d in range(1, ndays + 1):
        idx = first_col + d - 1
        col = idx % 7
        wk = idx // 7
        x0 = ox + col * (TW + GX)
        y0 = oy + wk * (TH + GY)
        weekend = (col >= 5) if monday_first else (col == 0 or col == 6)
        if d < today:
            c = ramp((d - 1) / (ndays - 1.0))

            # a highlight sweeps diagonally across the days gone by
            pos = (col / 7.0 + wk / float(weeks)) / 2.0
            k = max(0.0, 1.0 - abs(pos - shimmer) * 6.0)
            c = mix(c, CREAM, k * 0.6)
        elif d == today:
            c = mix(SUN, CREAM, 0.5 + 0.5 * math.sin(t * 2))
        else:
            c = mix(ramp((d - 1) / (ndays - 1.0)), (22, 14, 44), 0.72 if not weekend else 0.62)
        for y in range(y0, y0 + TH):
            for x in range(x0, x0 + TW):
                if x >= 0 and x < W and y >= 0 and y < H:
                    cc = c
                    if d < today and y == y0:
                        cc = mix(c, CREAM, 0.3)
                    buf[y][x] = cc

        # today gets a cherry frame that blinks
        if d == today and math.sin(t * 2) > -0.3:
            for x in range(x0 - 1, x0 + TW + 1):
                for y in [y0 - 1, y0 + TH]:
                    if x >= 0 and x < W and y >= 0 and y < H:
                        buf[y][x] = (255, 61, 79)
            for y in range(y0, y0 + TH):
                for x in [x0 - 1, x0 + TW]:
                    if x >= 0 and x < W:
                        buf[y][x] = (255, 61, 79)

    return [[rgb(c) for c in row] for row in buf]

def main(config):
    tz = config.get("$tz", "America/New_York")
    now = time.now().in_location(tz)
    if config.get("now"):
        now = time.parse_time(config.get("now")).in_location(tz)
    monday_first = config.bool("monday", False)

    ndays = days_in_month(now.year, now.month)
    first = time.time(year = now.year, month = now.month, day = 1, location = tz)
    wd = WEEKDAYS.index(first.format("Mon"))  # 0 = Monday
    first_col = wd if monday_first else (wd + 1) % 7
    weeks = (first_col + ndays + 6) // 7

    day = str(now.day)
    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(t, now.day, ndays, first_col, weeks, monday_first)),
            render.Padding(pad = (1, 0, 0, 0), child = outlined(now.format("Mon").upper(), "tom-thumb", "#ffd23f", "#1d1530")),
            render.Padding(pad = (0, 7, 0, 0), child = render.Box(width = 21, height = 15, child = outlined(day, "6x13", "#fff8ef", "#1d1530", bold = True))),
            render.Padding(pad = (1, 24, 0, 0), child = outlined(now.format("Jan").upper(), "tom-thumb", "#fff8ef", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Toggle(id = "monday", name = "Weeks start Monday", desc = "Start each row of tiles on Monday.", icon = "calendar", default = False),
        ],
    )
