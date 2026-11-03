"""
Applet: Weather Canvas
Summary: Today's weather, painted
Description: The current weather painted as a living scene (sun, clouds, rain, snow, storm or fog), with the temperature and today's high and low. Uses Open-Meteo, no key needed.
Author: TenThousandPixels
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

W = 64
H = 32
FRAMES = 40
DELAY = 90

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
SKY = (63, 189, 240)
MINT = (47, 210, 140)
GRAPE = (155, 93, 229)
BUBBLE = (255, 143, 184)
MIDNIGHT = (29, 21, 48)

# ---------- weather kinds ----------

def kind_for(code):
    if code <= 1:
        return "clear"
    if code <= 3:
        return "cloudy"
    if code == 45 or code == 48:
        return "fog"
    if (code >= 71 and code <= 77) or code == 85 or code == 86:
        return "snow"
    if code >= 95:
        return "storm"
    return "rain"

LABELS = {"clear": "CLEAR", "cloudy": "CLOUDY", "fog": "FOG", "snow": "SNOW", "storm": "STORM", "rain": "RAIN"}

# (sky top, sky bottom, ground) per kind, day and night
PALETTES = {
    ("clear", True): ((40, 150, 240), (255, 220, 150), MINT),
    ("clear", False): ((10, 6, 22), (50, 30, 100), (20, 50, 60)),
    ("cloudy", True): ((120, 140, 210), (220, 200, 230), (40, 150, 110)),
    ("cloudy", False): ((20, 16, 40), (60, 50, 90), (20, 40, 50)),
    ("fog", True): ((170, 160, 200), (230, 220, 235), (120, 150, 150)),
    ("fog", False): ((40, 34, 64), (90, 80, 120), (40, 50, 60)),
    ("rain", True): ((60, 70, 140), (130, 150, 200), (30, 90, 100)),
    ("rain", False): ((12, 10, 34), (40, 40, 90), (15, 30, 50)),
    ("snow", True): ((150, 170, 230), (230, 225, 250), CREAM),
    ("snow", False): ((20, 20, 50), (70, 70, 130), (200, 200, 230)),
    ("storm", True): ((40, 24, 80), (100, 60, 140), (25, 40, 50)),
    ("storm", False): ((14, 8, 30), (50, 26, 80), (15, 20, 35)),
}

def ground(x):
    return int(28 + 1.3 * math.sin(x * 0.15 + 0.7) + 0.8 * math.sin(x * 0.41))

def draw_cloud(buf, cx, cy, size, color, alpha):
    lobes = [(-1.1, 0.0, 0.8), (0.0, -0.45, 1.0), (1.2, 0.0, 0.75)]
    r = int(size * 2.5)
    for y in range(int(cy - size * 1.6), int(cy + size * 0.6) + 1):
        for x in range(int(cx - r), int(cx + r) + 1):
            if x < 0 or x >= W or y < 0 or y >= H or y > cy + size * 0.5:
                continue
            for lb in lobes:
                dx = x - (cx + lb[0] * size)
                dy = (y - (cy + lb[1] * size)) * 1.3
                if dx * dx + dy * dy < (lb[2] * size) * (lb[2] * size):
                    shade = alpha if y < cy else alpha * 0.8
                    buf[y][x] = mix(buf[y][x], color, shade)
                    break

def scene(kind, is_day, t, f):
    top, low, gnd = PALETTES[(kind, is_day)]
    flash = kind == "storm" and (f % 20 == 3 or f % 20 == 5)
    buf = []
    for y in range(H):
        c = mix(top, low, y / (H - 1.0))
        if flash:
            c = mix(c, CREAM, 0.45)
        buf.append([c for _ in range(W)])
    cyc = t / (2 * math.pi)

    # sun or moon behind everything, upper right
    bx, by = 50, 9
    show_body = kind in ["clear", "cloudy"]
    if show_body:
        for y in range(H):
            for x in range(W):
                dx = x - bx
                dy = y - by
                d = math.sqrt(dx * dx + dy * dy)
                if is_day:
                    ang = math.atan2(dy, dx)
                    rays = 0.5 + 0.5 * math.sin(ang * 8 + t)
                    if d < 5:
                        buf[y][x] = mix((255, 250, 220), SUN, d / 5.0)
                    elif d < 13:
                        buf[y][x] = add(buf[y][x], (255, 180, 60), (1 - (d - 5) / 8.0) * (0.25 + 0.45 * rays))
                elif d < 4.5:
                    if math.sqrt((dx + 2.2) * (dx + 2.2) + (dy + 1) * (dy + 1)) > 3.8:
                        buf[y][x] = CREAM
                elif d < 10:
                    buf[y][x] = add(buf[y][x], GRAPE, (1 - (d - 4.5) / 5.5) * 0.3)

    # stars on clear nights; the loose sun pixel stays put either way
    if not is_day and kind in ["clear", "cloudy", "snow"]:
        for i, s in enumerate([(30, 3), (38, 12), (24, 9), (60, 20), (44, 2), (57, 1)]):
            buf[s[1]][s[0]] = add(buf[s[1]][s[0]], CREAM, 0.35 + 0.35 * math.sin(t * 2 + i))
    buf[1][62] = SUN

    # clouds
    if kind == "clear" and is_day:
        draw_cloud(buf, (cyc * 64 + 20) % 90 - 13, 20, 2.6, CREAM, 0.9)
    elif kind == "cloudy":
        ccol = CREAM if is_day else (90, 80, 130)
        draw_cloud(buf, 46 + 5 * math.sin(t), 14, 4.2, ccol, 0.95)
        draw_cloud(buf, 34 + 6 * math.sin(t + 2.0), 22, 3.0, mix(ccol, low, 0.25), 0.9)
        draw_cloud(buf, 60 + 3 * math.sin(t + 4.0), 23, 2.4, mix(ccol, low, 0.15), 0.9)
    elif kind in ["rain", "storm", "snow"]:
        # a heavy ceiling with a lobed, slowly rolling underside
        ccol = (70, 60, 110)
        if kind == "snow":
            ccol = (205, 205, 240) if is_day else (80, 80, 130)
        elif kind == "storm":
            ccol = (45, 26, 75)
        if not is_day and kind != "snow":
            ccol = mix(ccol, MIDNIGHT, 0.5)
        for x in range(W):
            edge = 5.5 + 1.6 * abs(math.sin(x * 0.26 + t * 0.5)) + 0.8 * math.sin(x * 0.7 - t)
            for y in range(H):
                if y < edge:
                    buf[y][x] = mix(mix(ccol, CREAM, 0.12), ccol, y / edge)
                elif y < edge + 1:
                    buf[y][x] = mix(buf[y][x], ccol, 0.5)

    # ground
    for x in range(W):
        g = ground(x)
        for y in range(g, H):
            buf[y][x] = mix(gnd, MIDNIGHT, (y - g) / 6.0)

    # precipitation
    if kind in ["rain", "storm"]:
        drop = mix(SKY, CREAM, 0.3)
        for i in range(34):
            x0 = (i * 37) % W
            speed = 2 if i % 2 else 3
            y0 = int((i * 13 + f * speed * 1.6) % (H + 6)) - 4
            for k in range(3):
                x = (x0 - (y0 + k) // 3) % W
                y = y0 + k
                if y >= 7 and y < ground(x):
                    buf[y][x] = mix(buf[y][x], drop, 0.5 + 0.2 * k)

            # splash
            gx = (x0 - (ground(x0)) // 3) % W
            if (f + i) % 8 == 0:
                gy = ground(gx) - 1
                buf[gy][gx] = mix(buf[gy][gx], CREAM, 0.7)
    elif kind == "snow":
        for i in range(30):
            sx = (i * 23 + int(2.5 * math.sin(t + i))) % W
            sy = int((i * 11 + f * (0.6 + (i % 3) * 0.3)) % H)
            if sy >= 7 and sy < ground(sx):
                buf[sy][sx] = CREAM
    elif kind == "fog":
        for band in range(4):
            yb = 9 + band * 5
            for x in range(W):
                k = 0.5 + 0.5 * math.sin(x * 0.12 + cyc * 2 * math.pi * (1 if band % 2 else -1) + band)
                for y in [yb, yb + 1]:
                    buf[y][x] = mix(buf[y][x], CREAM, 0.25 + 0.4 * k)

    # lightning bolt
    if flash:
        pts = [(46, 6), (43, 12), (47, 12), (42, 20), (45, 20), (40, 27)]
        for j in range(len(pts) - 1):
            a = pts[j]
            b = pts[j + 1]
            steps = max(abs(b[0] - a[0]), abs(b[1] - a[1]))
            for s in range(steps + 1):
                x = int(a[0] + (b[0] - a[0]) * s / steps)
                y = int(a[1] + (b[1] - a[1]) * s / steps)
                buf[y][x] = SUN

    return [[rgb(c) for c in row] for row in buf]

def fetch(lat, lng, celsius):
    url = "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1" % (lat, lng)
    if not celsius:
        url += "&temperature_unit=fahrenheit"
    resp = http.get(url, ttl_seconds = 900)
    if resp.status_code != 200:
        return None
    return resp.json()

def main(config):
    loc = json.decode(config.get("location", DEFAULT_LOCATION))
    celsius = config.bool("celsius", False)

    if config.get("code"):
        # preview hook: paint a given WMO code without fetching
        code = int(config.get("code"))
        is_day = config.get("day", "1") == "1"
        temp, hi, lo = 68, 71, 52
    else:
        data = fetch(loc["lat"], loc["lng"], celsius)
        if data == None:
            return render.Root(child = render.Box(color = "#1d1530", child = render.Text("NO WEATHER", font = "tom-thumb", color = "#ffd23f")))
        cur = data["current"]
        code = int(cur["weather_code"])
        is_day = cur["is_day"] == 1
        temp = int(math.round(cur["temperature_2m"]))
        hi = int(math.round(data["daily"]["temperature_2m_max"][0]))
        lo = int(math.round(data["daily"]["temperature_2m_min"][0]))

    kind = kind_for(code)
    big = str(temp) + "°"
    small = "H" + str(hi) + " L" + str(lo)

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(scene(kind, is_day, t, f)),
            render.Padding(pad = (1, 0, 0, 0), child = outlined(big, "6x13", "#fff8ef", "#1d1530", bold = True)),
            render.Padding(pad = (1, 13, 0, 0), child = outlined(LABELS[kind], "tom-thumb", "#ffd23f", "#1d1530")),
            render.Padding(pad = (1, 24, 0, 0), child = outlined(small, "tom-thumb", "#fff8ef", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(id = "location", name = "Location", desc = "Where to paint the weather.", icon = "locationDot"),
            schema.Toggle(id = "celsius", name = "Celsius", desc = "Show temperatures in Celsius.", icon = "temperatureHalf", default = False),
        ],
    )
