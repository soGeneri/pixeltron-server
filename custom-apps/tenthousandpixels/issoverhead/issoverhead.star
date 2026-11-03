"""
Applet: ISS Overhead
Summary: Where the space station is now
Description: The International Space Station crossing a pixel world map, with day and night drawn where they really are, its last 40 minutes and next 50 minutes of orbit, what it is flying over and how far it is from you. Data from wheretheiss.at, no key needed.
Author: TenThousandPixels
"""

load("encoding/json.star", "json")
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

DEFAULT_LOCATION = json.encode({
    "lat": "40.7128",
    "lng": "-74.0060",
    "description": "New York, NY, USA",
    "locality": "New York",
    "timezone": "America/New_York",
})

# Natural Earth 1:110m land, rasterised to 64 x 32, equirectangular
LAND = [
    "................................................................",
    "...............##############...................................",
    "..........###.####.##########.............#....#####............",
    "...####.############..######.......###...#######################",
    "#..###############.##..##...#....###############################",
    "...###.#########..###............##.#########################...",
    ".........#############........###########################...#...",
    "..........###########..........##########################.......",
    "..........##########..........##########################........",
    "..........#########...........####...##################.#.......",
    "...........#######............########################..........",
    "............###..............#########################..........",
    ".............####............#############...#######............",
    "...............##............############....##..###............",
    ".................#####.......############.......................",
    "..................#####..........#######.........##.#...........",
    ".................########.........#####...........#.##.###......",
    "..................########........#####..................#......",
    "..................#######.........#####.#.............##.#......",
    "...................######.........#####.#............#####......",
    "...................#####..........####..............#######.....",
    "...................####............###..............#######.....",
    "...................###...................................##.....",
    "...................##.........................................#.",
    "..................##............................................",
    "...................#............................................",
    "................................................................",
    "................................................................",
    "...................##.........#.##############################..",
    ".....################......###################################..",
    ".....########################################################...",
    "################################################################",
]

# minutes either side of now for the orbit track (the API takes ten at a time)
TRACK = [-40, -30, -20, -10, 0, 10, 20, 30, 40, 50]
NOW_I = 4

def to_xy(lat, lon):
    return ((lon + 180.0) / 360.0 * W, (90.0 - lat) / 180.0 * H)

def is_land(x, y):
    x = int(x) % W
    y = int(y)
    if y < 0 or y >= H:
        return False
    return LAND[y][x] == "#"

def region(lat, lon):
    x, y = to_xy(lat, lon)
    if is_land(x, y):
        if lat < -60:
            return "ANTARCTICA"
        if lat > 60 and lon > -75 and lon < -10:
            return "GREENLAND"
        if lon >= -170 and lon < -50 and lat > 12:
            return "N AMERICA"
        if lon >= -92 and lon < -30 and lat <= 12:
            return "S AMERICA"
        if lon >= -25 and lon < 45 and lat >= 36:
            return "EUROPE"
        if lon >= -20 and lon < 52 and lat < 36:
            return "AFRICA"
        if lon >= 110 and lat < -10:
            return "AUSTRALIA"
        return "ASIA"
    if lat < -55:
        return "SOUTHERN OCEAN"
    if lat > 66:
        return "ARCTIC OCEAN"
    if lon >= -80 and lon < 20 and lat > 8:
        return "ATLANTIC"
    if lon >= -65 and lon < 20:
        return "ATLANTIC"
    if lon >= 20 and lon < 120 and lat < 25:
        return "INDIAN OCEAN"
    if lon >= 30 and lon < 60 and lat >= 25:
        return "ASIA"
    return "PACIFIC"

def km_between(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2)
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def commas(n):
    s = str(n)
    out = ""
    for i in range(len(s)):
        if i > 0 and (len(s) - i) % 3 == 0:
            out += ","
        out += s[i]
    return out

def base_map(slat, slon):
    # day and night from the subsolar point; a soft band of twilight between
    dl = math.radians(slat)
    buf = []
    for y in range(H):
        lat = 90.0 - (y + 0.5) * 180.0 / H
        pl = math.radians(lat)
        row = []
        for x in range(W):
            lon = -180.0 + (x + 0.5) * 360.0 / W
            cz = math.sin(pl) * math.sin(dl) + math.cos(pl) * math.cos(dl) * math.cos(math.radians(lon - slon))
            day = max(0.0, min(1.0, (cz + 0.12) / 0.24))
            land = LAND[y][x] == "#"
            ice = abs(lat) > 62
            if land:
                if ice:
                    d = mix((236, 244, 250), (210, 235, 248), (y % 2) * 0.5)
                    n = (70, 70, 120)
                else:
                    # a little relief: coasts lighter, interiors richer
                    coast = not (is_land(x - 1, y) and is_land(x + 1, y) and is_land(x, y - 1) and is_land(x, y + 1))
                    d = (120, 225, 160) if coast else mix((47, 210, 140), (20, 150, 100), ((x * 7 + y * 3) % 5) / 8.0)
                    n = (54, 40, 92) if not coast else (70, 52, 112)
            else:
                d = mix((63, 189, 240), (30, 110, 200), abs(lat) / 90.0 + 0.15)
                n = mix((22, 22, 70), (12, 10, 40), abs(lat) / 90.0)
            c = mix(n, d, day)

            # city lights on the night side
            if land and not ice and day < 0.3 and int(abs(math.sin(x * 12.9898 + y * 78.233) * 43758.5453)) % 16 == 0:
                c = mix(c, (255, 176, 90), 0.6)
            row.append(c)
        buf.append(row)
    return buf

ISS = [
    "bb.bb",
    "bbcbb",
    "bb.bb",
]

def frame(base, track, me, sun_xy, f):
    buf = [row[:] for row in base]
    t = f / float(FRAMES)

    # orbit track: past fading cream, future sun-yellow dots, a pulse running ahead
    pts = []
    for i in range(len(track) - 1):
        a = track[i]
        b = track[i + 1]
        dlon = b[1] - a[1]
        if dlon > 180:
            dlon -= 360
        elif dlon < -180:
            dlon += 360
        for s in range(10):
            u = s / 10.0
            lat = a[0] + (b[0] - a[0]) * u
            lon = a[1] + dlon * u
            if lon > 180:
                lon -= 360
            elif lon < -180:
                lon += 360
            pts.append((lat, lon, i + u))
    pulse = NOW_I + t * (len(track) - 1 - NOW_I)
    for p in pts:
        x, y = to_xy(p[0], p[1])
        xi = int(x) % W
        yi = int(y)
        if yi < 0 or yi >= H:
            continue
        if p[2] < NOW_I:
            k = 0.25 + 0.5 * (p[2] / NOW_I)
            if int(p[2] * 10) % 2 == 0:
                buf[yi][xi] = mix(buf[yi][xi], CREAM, k)
        elif int(p[2] * 10) % 3 == 0:
            near = abs(p[2] - pulse) < 0.35
            buf[yi][xi] = SUN if near else mix(buf[yi][xi], CREAM, 0.75)

    # the subsolar point: the brand's loose sun pixel, exactly where the sun is overhead
    sx, sy = sun_xy
    buf[int(sy) % H][int(sx) % W] = SUN

    # you
    mx, my = me
    if f % 10 < 7:
        buf[int(my)][int(mx) % W] = CHERRY
    for d in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        yy = int(my) + d[1]
        if yy >= 0 and yy < H:
            buf[yy][(int(mx) + d[0]) % W] = mix(buf[yy][(int(mx) + d[0]) % W], CHERRY, 0.35)

    # the station, panels out, beacon blinking
    now = track[NOW_I]
    ix, iy = to_xy(now[0], now[1])
    for r, line in enumerate(ISS):
        for c, ch in enumerate(line.elems()):
            if ch == ".":
                continue
            yy = int(iy) - 1 + r
            if yy < 0 or yy >= H:
                continue
            xx = (int(ix) - 2 + c) % W
            buf[yy][xx] = CREAM if ch == "c" else ((255, 196, 90) if (c + r) % 2 else (230, 140, 50))
    if f % 8 < 4:
        yy = int(iy) - 2
        if yy >= 0:
            buf[yy][int(ix) % W] = CHERRY

    return buf

def main(config):
    loc = json.decode(config.get("location", DEFAULT_LOCATION))
    mylat = float(loc["lat"])
    mylon = float(loc["lng"])
    miles = config.bool("miles", False)

    now = time.now().unix
    stamps = ",".join([str(now + m * 60) for m in TRACK])
    resp = http.get("https://api.wheretheiss.at/v1/satellites/25544/positions?timestamps=%s&units=kilometers" % stamps, ttl_seconds = 60)
    if resp.status_code != 200:
        return render.Root(child = render.Box(color = "#1d1530", child = render.Text("ISS LOST", font = "tom-thumb", color = "#ffd23f")))
    data = resp.json()
    track = [(float(p["latitude"]), float(p["longitude"])) for p in data]
    cur = data[NOW_I]
    slat = float(cur["solar_lat"])
    slon = float(cur["solar_lon"])
    if slon > 180:
        slon -= 360

    base = base_map(slat, slon)
    me = to_xy(mylat, mylon)
    sun_xy = to_xy(slat, slon)

    km = km_between(mylat, mylon, track[NOW_I][0], track[NOW_I][1])
    dist = km * 0.621371 if miles else km
    unit = " MI" if miles else " KM"
    if km < 2200:
        far = "OVERHEAD!"
    else:
        far = commas(int(math.round(dist / 10.0) * 10)) + unit + " AWAY"
    over = "OVER " + region(track[NOW_I][0], track[NOW_I][1])

    # both lines of text go in the half of the map the station is not in
    iy = to_xy(track[NOW_I][0], track[NOW_I][1])[1]
    ty = 0 if iy > 16 else 26

    frames = []
    for f in range(FRAMES):
        frames.append(render.Stack(children = [
            buf_to_widget([[rgb(c) for c in row] for row in frame(base, track, me, sun_xy, f)]),
            # one light line at a time: where it is, then how far from you
            render.Padding(pad = (1, ty, 0, 0), child = shadowed(over, "#ffd23f") if f < FRAMES // 2 else shadowed(far, "#fff8ef" if km >= 2200 else "#ff3d4f")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def shadowed(text, color):
    return render.Stack(children = [
        render.Padding(pad = (1, 1, 0, 0), child = render.Text(content = text, font = "tom-thumb", color = "#1d1530")),
        render.Text(content = text, font = "tom-thumb", color = color),
    ])

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(id = "location", name = "Location", desc = "Where you are, for the pin and the distance.", icon = "locationDot"),
            schema.Toggle(id = "miles", name = "Miles", desc = "Show the distance in miles.", icon = "ruler", default = False),
        ],
    )
