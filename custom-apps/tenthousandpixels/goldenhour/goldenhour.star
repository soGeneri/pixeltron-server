"""
Applet: Golden Hour
Summary: Live sky with sunrise and sunset
Description: A landscape whose sky follows the real sun where you are, with the sun or moon on its arc and a countdown to the next sunrise or sunset.
Author: TenThousandPixels
"""

load("encoding/json.star", "json")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("sunrise.star", "sunrise")
load("time.star", "time")

W = 64
H = 32
FRAMES = 40
DELAY = 120

DEFAULT_LOCATION = json.encode({
    "lat": "40.7128",
    "lng": "-74.0060",
    "description": "New York, NY, USA",
    "locality": "New York",
    "timezone": "America/New_York",
})

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

def outlined(text, font, color, shadow):
    layers = []
    for d in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
        layers.append(render.Padding(pad = (1 + d[0], 1 + d[1], 0, 0), child = render.Text(content = text, font = font, color = shadow)))
    layers.append(render.Padding(pad = (1, 1, 0, 0), child = render.Text(content = text, font = font, color = color)))
    return render.Stack(children = layers)

# ---------- sky palette, keyed by sun elevation in degrees ----------
# (elevation, top colour, horizon colour)
SKY_KEYS = [
    (-18.0, (10, 6, 22), (34, 22, 66)),  # night
    (-8.0, (40, 22, 90), (155, 93, 229)),  # blue hour, grape
    (-2.0, (90, 40, 140), (255, 61, 79)),  # dusk, cherry
    (3.0, (110, 90, 200), (255, 150, 80)),  # golden hour
    (10.0, (63, 160, 240), (255, 210, 120)),  # morning
    (25.0, (40, 140, 235), (170, 225, 250)),  # day, sky
]

def sky_for(e):
    if e <= SKY_KEYS[0][0]:
        return SKY_KEYS[0][1], SKY_KEYS[0][2]
    for i in range(len(SKY_KEYS) - 1):
        a = SKY_KEYS[i]
        b = SKY_KEYS[i + 1]
        if e <= b[0]:
            t = (e - a[0]) / (b[0] - a[0])
            return mix(a[1], b[1], t), mix(a[2], b[2], t)
    return SKY_KEYS[-1][1], SKY_KEYS[-1][2]

STARS = [(4, 3), (13, 7), (22, 2), (30, 5), (39, 1), (47, 6), (55, 3), (9, 12), (34, 10), (51, 11)]

def hill(x, base, a1, f1, p1, a2, f2, p2):
    return int(base + a1 * math.sin(x * f1 + p1) + a2 * math.sin(x * f2 + p2))

def frame(t, e, body_x, body_y, is_day, moon_phase):
    top, low = sky_for(e)
    night = max(0.0, min(1.0, (-e - 4.0) / 10.0))
    buf = []
    for y in range(H):
        c = mix(top, low, math.pow(y / (H - 1.0), 1.4))
        buf.append([c for _ in range(W)])

    # stars fade in after dusk; one of them is the brand's loose sun pixel
    if night > 0:
        for i, s in enumerate(STARS):
            tw = 0.5 + 0.5 * math.sin(t * 2.0 + i * 1.9)
            buf[s[1]][s[0]] = add(buf[s[1]][s[0]], (255, 248, 239), night * (0.35 + 0.5 * tw))
        buf[2][60] = mix(buf[2][60], (255, 210, 63), night)

    # sun glow or moon
    for y in range(H):
        for x in range(W):
            dx = x - body_x
            dy = (y - body_y) * 1.15
            d = math.sqrt(dx * dx + dy * dy)
            if is_day:
                if d < 3.2:
                    buf[y][x] = mix((255, 248, 220), (255, 210, 63), d / 3.2)
                else:
                    glow = math.exp(-(d - 3.2) / (5.0 + 0.8 * math.sin(t)))
                    buf[y][x] = add(buf[y][x], (255, 170, 60), glow * 0.55)
            elif d < 3.0:
                # crescent: cut by an offset dark disc
                ox = dx + (moon_phase - 0.5) * 6.0
                if math.sqrt(ox * ox + dy * dy) > 2.6 or moon_phase > 0.45 and moon_phase < 0.55:
                    buf[y][x] = (255, 248, 239)
            elif d < 7:
                buf[y][x] = add(buf[y][x], (155, 93, 229), (7 - d) / 7.0 * 0.25)

    # drifting clouds, lit by the horizon colour
    for i in range(2):
        cx = ((i * 37 + t * 4.0 / (2 * math.pi) * (1 + i)) % (W + 24)) - 12
        cy = 11 + i * 4
        lit = mix((255, 248, 239), low, 0.45)
        if night > 0.5:
            lit = mix((60, 45, 100), low, 0.3)

        # a puff: three overlapping lobes on a flat base
        lobes = [(-4.0, 0.0, 3.0), (0.0, -1.5, 3.6), (4.5, 0.0, 2.8)]
        for y in range(cy - 5, cy + 3):
            for x in range(int(cx) - 8, int(cx) + 9):
                if x >= 0 and x < W and y >= 0 and y <= cy + 1:
                    inside = False
                    for lb in lobes:
                        dx = x - (cx + lb[0])
                        dy = (y - (cy + lb[1])) * 1.3
                        if dx * dx + dy * dy < lb[2] * lb[2]:
                            inside = True
                    if inside:
                        shade = 0.85 if y < cy else 0.7
                        buf[y][x] = mix(buf[y][x], lit, shade)

    # three hill layers, hazier with distance
    far = mix(low, (155, 93, 229), 0.55)
    mid = mix(low, (70, 34, 100), 0.6)
    near = mix(low, (12, 8, 24), 0.85)
    for x in range(W):
        h1 = hill(x, 21, 2.0, 0.11, 0.5, 1.2, 0.29, 1.0)
        h2 = hill(x, 25, 2.2, 0.17, 2.0, 1.0, 0.41, 0.3)
        h3 = hill(x, 28, 1.5, 0.23, 4.0, 0.8, 0.53, 2.2)
        for y in range(H):
            if y >= h3:
                buf[y][x] = near
            elif y >= h2:
                buf[y][x] = mid
            elif y >= h1:
                buf[y][x] = far
    return [[rgb(c) for c in row] for row in buf]

def fmt_time(t, use_24h):
    if use_24h:
        return t.format("15:04")
    return t.format("3:04")

def fmt_left(d):
    mins = int(d.minutes)
    if mins < 60:
        return "IN %dM" % mins
    if mins % 60 == 0:
        return "IN %dH" % (mins // 60)
    return "IN %dH %dM" % (mins // 60, mins % 60)

def main(config):
    loc = json.decode(config.get("location", DEFAULT_LOCATION))
    lat = float(loc["lat"])
    lng = float(loc["lng"])
    tz = loc.get("timezone", config.get("$tz", "America/New_York"))
    use_24h = config.bool("24h", False)

    now = time.now().in_location(tz)
    if config.get("now"):
        # preview hook: render the sky at a given RFC 3339 time
        now = time.parse_time(config.get("now")).in_location(tz)
    today = time.time(year = now.year, month = now.month, day = now.day, hour = 12, location = tz)
    rise = sunrise.sunrise(lat, lng, today)
    sset = sunrise.sunset(lat, lng, today)
    e = sunrise.elevation(lat, lng, now)

    if rise == None or sset == None:
        # polar day or night: no arc to draw
        is_day = e > 0
        frac = 0.5
        label = "MIDNIGHT SUN" if is_day else "POLAR NIGHT"
        when = ""
        left = ""
    else:
        rise = rise.in_location(tz)
        sset = sset.in_location(tz)
        is_day = now >= rise and now < sset
        if is_day:
            frac = (now - rise).seconds / (sset - rise).seconds
            label = "SUNSET"
            target = sset
        else:
            if now < rise:
                prev_set = sunrise.sunset(lat, lng, today - time.parse_duration("24h")).in_location(tz)
                nxt = rise
            else:
                prev_set = sset
                nxt = sunrise.sunrise(lat, lng, today + time.parse_duration("24h")).in_location(tz)
            frac = (now - prev_set).seconds / (nxt - prev_set).seconds
            label = "SUNRISE"
            target = nxt
        when = fmt_time(target, use_24h)
        left = fmt_left(target - now)

    body_x = 5 + frac * (W - 10)
    body_y = 20 - 15 * math.sin(frac * math.pi)

    # moon phase from a known new moon (2000-01-06 18:14 UTC)
    days = (now - time.time(year = 2000, month = 1, day = 6, hour = 18, minute = 14)).hours / 24.0
    phase = (days % 29.530588) / 29.530588

    # text goes on the side away from the sun
    text_x = 29 if body_x < W / 2 else 1

    # keep the sun or moon clear of the text column near the top of its arc
    if text_x > 1:
        body_x = min(body_x, 23)
    else:
        body_x = max(body_x, 41)

    # the countdown line can be wider than the column above it; keep it on screen
    left_x = text_x if text_x == 1 else min(text_x, W - 2 - len(left) * 4)

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(t, e, body_x, body_y, is_day, phase)),
            render.Padding(pad = (text_x, 0, 0, 0), child = render.Column(children = [
                outlined(label, "tom-thumb", "#ffd23f", "#1d1530"),
                outlined(when, "tb-8", "#fff8ef", "#1d1530"),
            ])),
            render.Padding(pad = (left_x, 24, 0, 0), child = outlined(left, "tom-thumb", "#fff8ef", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(id = "location", name = "Location", desc = "Where to follow the sun.", icon = "locationDot"),
            schema.Toggle(id = "24h", name = "24-hour time", desc = "Show times in 24-hour format.", icon = "clock", default = False),
        ],
    )
