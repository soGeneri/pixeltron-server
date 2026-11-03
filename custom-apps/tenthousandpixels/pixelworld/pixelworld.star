"""
Applet: Pixel World
Summary: The 10K Pixels world, live
Description: The little world from the tenthousandpixels.com homepage, on your desk: mountains, a windmill, the cottage, the tree, a pond and a little Pixeltron. It follows the same rules as the site: dawn, day and dusk by your clock, the season by the date, the real moon, pumpkins at Halloween and lights at Christmas. Give it your location and it rains, snows or fogs over when it really does where you are.
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
FRAMES = 120  # 15 s at 8 fps, the site's tick rate and the device's default dwell
DELAY = 125

# ---------- palettes, from the site's WORLD_PAL / WORLD_TOD / WORLD_SEASON ----------

DAY = {
    "sky": ["#7fd0f2", "#9fdcf6", "#bde8f9", "#d9f3fd", "#fff1dc"],
    "sun": "#ffd23f",
    "ray": "#ffb800",
    "cloud": "#ffffff",
    "cloudShade": "#d3ecf8",
    "far": "#9fe3c4",
    "near": "#5fd39c",
    "nearTop": "#7ee0b0",
    "ground": "#2fd28c",
    "groundDark": "#24bd7b",
    "tuft": "#139a62",
    "trunk": "#a0673f",
    "leaves": "#139a62",
    "leavesLight": "#2fd28c",
    "leavesDark": "#0f7a4c",
    "fruit": "#ff3d4f",
    "flowers": ["#ff3d4f", "#ff8fb8", "#ffd23f", "#9b5de5", "#ffffff"],
    "stem": "#139a62",
    "bird": "#1d1530",
    "mtn": "#b9e3f2",
    "mtnShade": "#a3d6ea",
    "snow": "#ffffff",
    "snowShade": "#e4f3fa",
    "pine": "#6cc99f",
    "pineDark": "#58bd8f",
    "wall": "#fff8ef",
    "wallShade": "#e8dccb",
    "roof": "#ff3d4f",
    "roofDark": "#c41a2e",
    "wood": "#a0673f",
    "glass": "#9fe0f9",
    "lit": "#ffd23f",
    "smoke": "#ffffff",
    "mill": "#fff8ef",
    "millShade": "#e8dccb",
    "blade": "#a0673f",
    "sail": "#fff8ef",
    "water": "#3fbdf0",
    "glint": "#d9f3fd",
    "bank": "#24bd7b",
    "duck": "#fff8ef",
    "duckHead": "#139a62",
    "bill": "#ffb800",
    "bun": "#fff8ef",
    "bunShade": "#e8dccb",
    "ear": "#ff8fb8",
    "eye": "#1d1530",
    "balloon": ["#ff3d4f", "#fff8ef"],
    "rope": "#1d1530",
    "iron": "#1d1530",
    "pxtBody": "#b5a184",
    "pxtEdge": "#8f7d63",
    "pxtScreen": "#1d1530",
    "pxtGold": "#c9a05a",
    "led": ["#3fbdf0", "#ffd23f", "#2fd28c", "#ff3d4f"],
    "snowfall": "#ffffff",
    "fallLeaves": ["#e8742a", "#ffb800", "#c41a2e"],
}

NIGHT = {
    "sky": ["#07070d", "#0c0c18", "#121226", "#191834", "#231f42"],
    "moon": "#f2f1ec",
    "crater": "#d9d6cc",
    "cloud": "#2b2944",
    "cloudShade": "#211f36",
    "far": "#162826",
    "near": "#1c372d",
    "nearTop": "#24453a",
    "ground": "#1d4a33",
    "groundDark": "#173d2a",
    "tuft": "#2e7050",
    "trunk": "#4a3326",
    "leaves": "#1b4a34",
    "leavesLight": "#27644a",
    "leavesDark": "#123a28",
    "fruit": "#c41a2e",
    "flowers": ["#c41a2e", "#a65a7a", "#b39424", "#6e4aa8", "#9a97a3"],
    "stem": "#2e7050",
    "star": "#f2f1ec",
    "fly": "#ffe066",
    "bird": "#07070d",
    "mtn": "#1b2338",
    "mtnShade": "#151c2e",
    "snow": "#3b4560",
    "snowShade": "#2e3650",
    "pine": "#11231f",
    "pineDark": "#0d1c19",
    "wall": "#2e2b45",
    "wallShade": "#25233a",
    "roof": "#7a1622",
    "roofDark": "#5c1019",
    "wood": "#4a3326",
    "glass": "#2b2944",
    "lit": "#ffd23f",
    "smoke": "#3a3852",
    "mill": "#2e2b45",
    "millShade": "#25233a",
    "blade": "#4a3326",
    "sail": "#3a3850",
    "water": "#13294a",
    "glint": "#f2f1ec",
    "bank": "#173d2a",
    "duck": "#9a97a3",
    "duckHead": "#1b4a34",
    "bill": "#b38a2e",
    "bun": "#9a97a3",
    "bunShade": "#7d7a88",
    "ear": "#a65a7a",
    "eye": "#07070d",
    "balloon": ["#8a1f2c", "#9a97a3"],
    "rope": "#07070d",
    "iron": "#07070d",
    "pxtBody": "#7a6d59",
    "pxtEdge": "#5e5242",
    "pxtScreen": "#07070d",
    "pxtGold": "#8a6f3e",
    "led": ["#3fbdf0", "#ffd23f", "#2fd28c", "#ff3d4f"],
    "snowfall": "#c8c6d0",
    "fallLeaves": ["#5c3418", "#7a4a1c", "#5c1019"],
    "aurora": ["#123a31", "#164a3c", "#14394a"],
    "auroraEdge": "#1f6b52",
}

TOD = {
    "dawn": {
        "sky": ["#8ccbee", "#b9dcf2", "#f7e2cf", "#ffdcbd", "#fff1dc"],
        "cloud": "#fff6ee",
        "cloudShade": "#f7d3c6",
        "ray": "#ffb070",
        "mtn": "#c6dbee",
        "mtnShade": "#b0c9e2",
        "snow": "#fff4ee",
        "snowShade": "#f1dcd8",
    },
    "dusk": {
        "sky": ["#79acd9", "#a9c4e2", "#f4c5a8", "#ffbb8c", "#ffdcae"],
        "cloud": "#ffe6d4",
        "cloudShade": "#f4b9a0",
        "sun": "#ff9f40",
        "ray": "#ff7a3d",
        "mtn": "#b9c4dc",
        "mtnShade": "#a1aecb",
        "snow": "#ffe9dc",
        "snowShade": "#efc9bc",
    },
}

SEASON = {
    "spring": {
        "day": {"leaves": "#ffb3c6", "leavesLight": "#ffd8e1", "leavesDark": "#f08aa5", "trunk": "#5b3a3a", "blossom": "#ffffff", "petals": ["#ff8fb8", "#f774a8", "#ffb0cc"]},
        "night": {"leaves": "#8a5062", "leavesLight": "#a86878", "leavesDark": "#6a3848", "trunk": "#33222a", "blossom": "#c99aa4", "petals": ["#a65a7a", "#c9a3b8", "#8a4c6a"]},
    },
    "autumn": {
        "day": {"leaves": "#e8742a", "leavesLight": "#ffb800", "leavesDark": "#c4361e", "farTrees": [["#f0a060", "#e08a48"], ["#f5c860", "#e8b448"], ["#e07a5a", "#cc6448"]], "pumpkin": "#f28a1e", "pumpkinRib": "#c9661a"},
        "night": {"leaves": "#5c3418", "leavesLight": "#7a4a1c", "leavesDark": "#4a1c14", "farTrees": [["#3a2a1a", "#30220f"], ["#3d3418", "#332b12"], ["#3a1d18", "#2f1712"]], "pumpkin": "#7a3e12", "pumpkinRib": "#5c2e0e", "harvestMoon": "#ffb35c", "harvestCrater": "#e0924a"},
    },
    "winter": {
        "day": {"leaves": "#6fb79a", "leavesLight": "#e4f3fa", "far": "#e4f1f8", "near": "#f2f8fb", "nearTop": "#ffffff", "ground": "#ffffff", "groundDark": "#d6e7f1", "tuft": "#b9cfd6", "bank": "#cfe1eb", "bun": "#c8b49c", "bunShade": "#a8957a", "trunkDark": "#7a4a2a", "icicle": "#8fd0ee"},
        "night": {"leaves": "#24423a", "leavesLight": "#8e8ca0", "far": "#2a3448", "near": "#323d54", "nearTop": "#4a5675", "ground": "#3a4660", "groundDark": "#2e3850", "tuft": "#4a5675", "bank": "#2a3448", "bun": "#7d7062", "bunShade": "#62574b", "trunkDark": "#33231c", "icicle": "#5a7aa0"},
    },
}

# ---------- sprites, from the site's CLOUDS / WORLD_SPR ----------

CLOUDS = [
    ["..aa.aa..", ".aaaaaaa.", "aaaaaaaaa", ".sssssss."],
    ["....aaa.......", "..aaaaaaa.aa..", ".aaaaaaaaaaaaa", "aaaaaaaaaaaaaa", ".ssssssssssss."],
]
BALLOON = ["..abbba..", ".aabbbaa.", "aaabbbaaa", "aaabbbaaa", ".aabbbaa.", "..aabaa..", "...r.r...", "...kkk..."]
BUN = ["....e.", "....w.", ".wwwwk", "wwwwww", ".s..s."]
BUN_HOP = ["....e.", "....w.", ".wwwwk", "wwwwww", "s....s"]
DUCK = ["....g.", "wwwwgo", ".wwww."]
PUMPKIN = [".g.", "oro", "ooo"]

# the tree, shrunk to fit 64 x 32: l light, p mid, d dark leaves, t trunk, f fruit, w blossom
TREE = {
    "summer": [
        "...lll...",
        ".lllplll.",
        "llpplpfll",
        "lpfpppppl",
        "pppdpppdp",
        ".dpdddpd.",
        "..d.t.d..",
        "....t....",
        "....t....",
        "...ttt...",
    ],
    "spring": [
        "..wll.l..",
        ".lllwlll.",
        "llpplpwll",
        "lpwppppwl",
        "pppdpwpdp",
        ".dpdddpd.",
        "..d.t.d..",
        "....t....",
        "....t....",
        "...ttt...",
    ],
    "autumn": [
        "...lpl...",
        ".dpllppd.",
        "dpplllppd",
        "dplppdpdd",
        "ddppplpdd",
        ".ddpdppd.",
        "..d.t.d..",
        "....t....",
        "....t....",
        "...ttt...",
    ],
    "winter": [
        "..l...l..",
        "..d.l.d..",
        "l.dd.dd.l",
        ".d..t..d.",
        "..d.t.d..",
        "...dtd...",
        "....t....",
        "....t....",
        "....t....",
        "...ttt...",
    ],
}

# ---------- layout ----------

FB = 21  # foot of the mountains
GY = 28  # top of the meadow
HX = 14  # cottage left wall
HY = 24  # top of the cottage wall
TX = 1  # tree left edge
PX0 = 36  # pond left
MX = 47  # windmill
PXT = 53  # little Pixeltron left

BACK_PEAKS = [(2, 10), (15, 8), (28, 11), (41, 7), (55, 9), (66, 10)]
FRONT_PEAKS = [(8, 13), (22, 12), (35, 14), (49, 12), (62, 13)]
PINES = [(3, 3), (8, 4), (19, 3), (25, 4), (31, 3), (36, 4), (57, 3), (62, 4)]
TUFTS = [2, 7, 12, 19, 25, 31, 34, 49, 52, 61]
FLOWERS = [(5, 0), (10, 2), (22, 1), (29, 3), (33, 4), (50, 0), (62, 2)]

HEX = "0123456789abcdef"

def parse(c):
    c = c.lower()
    return (HEX.index(c[1]) * 16 + HEX.index(c[2]), HEX.index(c[3]) * 16 + HEX.index(c[4]), HEX.index(c[5]) * 16 + HEX.index(c[6]))

def hx(v):
    v = int(max(0, min(255, v)))
    return HEX[v // 16] + HEX[v % 16]

def mixhex(a, b, t):
    pa = parse(a)
    pb = parse(b)
    return "#" + hx(pa[0] + (pb[0] - pa[0]) * t + 0.5) + hx(pa[1] + (pb[1] - pa[1]) * t + 0.5) + hx(pa[2] + (pb[2] - pa[2]) * t + 0.5)

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

def px(buf, x, y, c):
    x = int(x)
    y = int(y)
    if x >= 0 and x < W and y >= 0 and y < H and c != None:
        buf[y][x] = c

def box(buf, x, y, w, h, c):
    for yy in range(int(y), int(y + h)):
        for xx in range(int(x), int(x + w)):
            px(buf, xx, yy, c)

def disc(buf, cx, cy, r, c):
    for y in range(int(cy - r), int(cy + r) + 1):
        for x in range(int(cx - r), int(cx + r) + 1):
            if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r + 0.5:
                px(buf, x, y, c)

def spr(buf, rows, x, y, cmap):
    for r, line in enumerate(rows):
        for c, ch in enumerate(line.elems()):
            if ch != "." and ch in cmap:
                px(buf, x + c, y + r, cmap[ch])

def bird(buf, bx, by, up, c):
    px(buf, bx, by, c)
    px(buf, bx - 1, by - 1 if up else by, c)
    px(buf, bx + 1, by - 1 if up else by, c)
    px(buf, bx - 2, by - 1 if up else by + 1, c)
    px(buf, bx + 2, by - 1 if up else by + 1, c)

def hashf(n):
    v = math.sin(n * 12.9898) * 43758.5453
    return v - math.floor(v)

# ---------- the world's terrain ----------

def far_y(x):
    return int(math.round(19.5 + math.sin(x * 0.11 + 1.0) * 1.5 + math.sin(x * 0.29) * 0.8))

def near_y(x):
    return int(math.round(24.5 + math.sin(x * 0.15 + 3.0) * 1.2 + math.sin(x * 0.4) * 0.5))

def range_tops(peaks, slope, jag):
    tops = []
    owner = []
    for x in range(W):
        best = FB + 2
        own = None
        for pk in peaks:
            dx = abs(x - pk[0])
            y = pk[1] + dx * slope + (hashf(x * 3 + pk[0]) - 0.5) * jag * min(1.0, dx / 3.0)
            if y < best:
                best = y
                own = pk
        tops.append(int(math.round(best)))
        owner.append(own)
    return tops, owner

def paint_range(buf, tops, owner, lit, shade, snow, snow_shade, bottom, sun_left, snow_line, cap):
    for x in range(W):
        my = tops[x]
        if my >= bottom:
            continue
        pk = owner[x]
        if pk == None:
            split = my
        else:
            dx = x - pk[0]
            toward = dx <= 0 if sun_left else dx >= 0
            split = my if toward else int(math.round(pk[1] + abs(dx) / 0.4)) + (int(hashf(x) * 3) - 1)
        split = max(my, min(bottom, split))
        for y in range(my, split):
            px(buf, x, y, shade)
        for y in range(split, bottom):
            px(buf, x, y, lit)
        tall = FB - my
        if tall > snow_line:
            end = my + min(cap, int(math.round((tall - snow_line) * 0.6)) + 1) + int(hashf(x * 7) * 2)
            for y in range(my, end):
                px(buf, x, y, snow_shade if y < split else snow)

# ---------- the environment, as the site works it out ----------

def world_env(now, test, night_after_dark):
    mo = now.month
    hr = now.hour + now.minute / 60.0
    season = "winter" if mo == 12 or mo <= 2 else ("spring" if mo <= 5 else ("summer" if mo <= 8 else "autumn"))
    tod = "dawn" if hr >= 5 and hr < 8 else ("day" if hr >= 8 and hr < 17.5 else "dusk")
    night = night_after_dark and (hr >= 20 or hr < 5)
    for k in ["spring", "summer", "autumn", "winter"]:
        if k in test:
            season = k
    for k in ["dawn", "day", "dusk"]:
        if k in test:
            tod = k
            night = False
    if "night" in test:
        night = True
    days = (now - time.time(year = 2000, month = 1, day = 6, hour = 18, minute = 14)).hours / 24.0
    phase = (days % 29.530588) / 29.530588
    forced = len([k for k in ["spring", "summer", "autumn", "winter"] if k in test]) > 0
    return {
        "season": season,
        "tod": tod,
        "night": night,
        "phase": phase,
        "fullMoon": abs(phase - 0.5) < 0.034 or "fullmoon" in test,
        "halloween": "halloween" in test or (not forced and mo == 10 and now.day >= 24),
        "christmas": "christmas" in test or (not forced and mo == 12 and now.day <= 26),
    }

def palette(env):
    p = dict(NIGHT if env["night"] else DAY)
    if not env["night"] and env["tod"] in TOD:
        p.update(TOD[env["tod"]])
    sea = SEASON.get(env["season"])
    if sea:
        p.update(sea["night" if env["night"] else "day"])
    return p

# ---------- real weather ----------

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

def fetch_weather(loc):
    url = "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current=weather_code" % (loc["lat"], loc["lng"])
    resp = http.get(url, ttl_seconds = 900)
    if resp.status_code != 200:
        return "clear"
    return kind_for(int(resp.json()["current"]["weather_code"]))

# how far each kind of weather pulls the sky towards grey
SKY_DIM = {"cloudy": 0.22, "rain": 0.55, "storm": 0.6, "fog": 0.45, "snow": 0.25}

# ---------- static layers, drawn once ----------

def sky_layer(P):
    buf = [[P["sky"][-1] for _ in range(W)] for _ in range(H)]
    band = 4
    for i in range(len(P["sky"])):
        box(buf, 0, i * band, W, band, P["sky"][i])

    # the site's dithered seams between bands
    for i in range(1, len(P["sky"])):
        for x in range(0, W, 2):
            px(buf, x, i * band - 1, P["sky"][i])
            px(buf, x + 1, i * band, P["sky"][i - 1])
    return buf

def dimmed(P, weather, night):
    # overcast skies: the bands keep their steps but pull towards grey (plum for a storm)
    k = SKY_DIM.get(weather, 0)
    if k == 0:
        return P
    grey = "#1a1a28" if night else ("#5a4a78" if weather == "storm" else ("#e8eef2" if weather in ["fog", "snow"] else "#7d8aa0"))
    P = dict(P)
    P["sky"] = [mixhex(c, grey, k) for c in P["sky"]]
    if weather != "cloudy":
        heavy = 0.6 if weather in ["rain", "storm"] else 0.3
        P["cloud"] = mixhex(P["cloudShade"], grey, heavy)
        P["cloudShade"] = mixhex(P["cloudShade"], grey, heavy + 0.2)
    return P

def land_layer(P, env):
    buf = [[None for _ in range(W)] for _ in range(H)]
    winter = env["season"] == "winter"
    night = env["night"]
    evening = night or env["tod"] == "dusk"
    sun_left = not night and env["tod"] == "dawn"

    # mountains: the back range washed towards the horizon sky
    haze = P["sky"][-1]
    bt, bo = range_tops(BACK_PEAKS, 0.75, 2.0)
    ft, fo = range_tops(FRONT_PEAKS, 0.85, 1.5)
    paint_range(buf, bt, bo, mixhex(P["mtn"], haze, 0.35), mixhex(P["mtnShade"], haze, 0.35), mixhex(P["snow"], haze, 0.25), mixhex(P["snowShade"], haze, 0.25), FB + 2, sun_left, 7 if not winter else 4, 5 if winter else 3)
    paint_range(buf, ft, fo, P["mtn"], P["mtnShade"], P["snow"], P["snowShade"], H, sun_left, 7 if not winter else 4, 4 if winter else 2)

    # far hills with pines (autumn turns most of them)
    for x in range(W):
        for y in range(far_y(x), H):
            px(buf, x, y, P["far"])
    for pn in PINES:
        x0, ph = pn
        base = far_y(x0) + 1
        tc = [P["pine"], P["pineDark"]]
        if "farTrees" in P and x0 % 4:
            tc = P["farTrees"][x0 % 3]
        for k in range(ph):
            half = (k + 1) // 2
            box(buf, x0 - half, base - ph + k, half * 2 + 1, 1, tc[0])
            px(buf, x0 + half, base - ph + k, tc[1])
        if winter:
            px(buf, x0, base - ph, P["snow"])

    # windmill tower
    mb = far_y(MX) + 2
    mt = mb - 8
    for k in range(8):
        hw = 1 + k // 5
        box(buf, MX - hw, mt + k, hw * 2 + 1, 1, P["mill"])
        px(buf, MX + hw, mt + k, P["millShade"])
    box(buf, MX - 2, mt - 1, 5, 1, P["snow"] if winter else P["roof"])
    box(buf, MX - 1, mt - 2, 3, 1, P["snow"] if winter else P["roof"])
    box(buf, MX, mb - 2, 1, 2, P["wood"])
    px(buf, MX, mt + 3, P["lit"] if evening else P["glass"])

    # near hills
    for x in range(W):
        ny = near_y(x)
        for y in range(ny, H):
            px(buf, x, y, P["near"])
        px(buf, x, ny, P["nearTop"])

    # the cottage: a red roof in steps, a chimney, two windows (lit after dusk) and the door
    b = GY - 1
    box(buf, HX, HY, 11, b - HY + 1, P["wall"])
    box(buf, HX, HY, 1, b - HY + 1, P["wallShade"])
    for k in range(5):
        c = P["snow"] if winter and k < 2 else (P["roofDark"] if k % 2 else P["roof"])
        box(buf, HX + 4 - k, HY - 5 + k, 2 * k + 3, 1, c)
    box(buf, HX + 8, HY - 6, 2, 3, P["wood"])
    if winter:
        box(buf, HX + 8, HY - 7, 2, 1, P["snow"])
        for ic in [(0, 1), (3, 2), (6, 1), (9, 2)]:
            for k in range(ic[1]):
                px(buf, HX + ic[0], HY + k, P.get("icicle", P["snow"]))
    win = P["lit"] if evening else P["glass"]
    box(buf, HX + 6, HY + 1, 2, 1, win)
    box(buf, HX + 8, HY + 1, 2, 1, win)
    box(buf, HX + 2, HY + 1, 2, b - HY, P["wood"])
    px(buf, HX + 3, HY + 2, P["lit"])

    # pond in the meadow, with a bank
    for x in range(PX0, PX0 + 11):
        px(buf, x, GY, P["bank"])
    box(buf, PX0 + 1, GY + 1, 9, 2, P["water"])
    box(buf, PX0 + 2, GY + 3, 7, 1, P["water"])

    # the little Pixeltron in the meadow: body, edge, screen, gold dial and legs
    box(buf, PXT + 1, 23, 8, 1, P["pxtEdge"])
    box(buf, PXT, 24, 10, 4, P["pxtEdge"])
    box(buf, PXT + 1, 24, 8, 4, P["pxtBody"])
    box(buf, PXT + 2, 25, 6, 2, P["pxtScreen"])
    box(buf, PXT + 7, 22, 2, 1, P["pxtGold"])
    px(buf, PXT + 1, 28, P["pxtGold"])
    px(buf, PXT + 8, 28, P["pxtGold"])

    # meadow
    for x in range(W):
        for y in range(GY, H):
            if x >= PX0 and x < PX0 + 11 and y > GY:
                continue
            if x >= PXT + 1 and x <= PXT + 8 and y == GY:
                continue
            c = P["ground"]
            if y >= GY + 2 and (x + y) % 2 == 0:
                c = P["groundDark"]
            px(buf, x, y, c)

    # fog lies in two soft bands across the hills
    if env["weather"] == "fog":
        mist = "#3a3852" if night else "#ffffff"
        for x in range(W):
            for band in [(far_y(x) - 2, 0.65), (near_y(x) - 1, 0.5)]:
                y0 = band[0] + int(math.round(math.sin(x * 0.2) * 0.8))
                for y in range(y0, y0 + 2):
                    if y >= 0 and y < H and buf[y][x] != None:
                        buf[y][x] = mixhex(buf[y][x], mist, band[1])
    return buf

# ---------- each frame ----------

def frame(f, sky, land, P, env):
    t = f / 8.0
    night = env["night"]
    evening = night or env["tod"] == "dusk"
    season = env["season"]
    weather = env["weather"]
    wet = weather in ["rain", "storm", "snow"]
    overcast = weather in ["rain", "storm", "snow", "fog"]
    buf = [row[:] for row in sky]

    # northern lights on clear nights, like the site
    if night and not overcast and weather != "cloudy":
        for k in range(2):
            ab = 3 + k * 3
            for x in range(k, W, 2):
                glow = math.sin(x * 0.09 + k * 1.7 + t * 0.35)
                if glow < 0.15:
                    continue
                ay = ab + int(math.round(math.sin(x * 0.2 + t * 0.5 + k) * 1.5))
                ln = 2 + int((glow - 0.15) * 4)
                px(buf, x, ay, P["auroraEdge"])
                for y in range(ay - ln + 1, ay):
                    if (y + f // 2) % 2 == 0 or y > ay - ln // 2:
                        px(buf, x, y, P["aurora"][k])

    # sun, or moon and stars; an overcast sky hides them
    if overcast:
        pass
    elif night:
        for i in range(22):
            sx = int(hashf(i + 1) * W)
            sy = int(hashf(i + 50) * 14)
            if (f + i * 7) % 40 < 37:
                px(buf, sx, sy, P["star"])
        mx, my = 55, 6
        if season == "autumn" and env["fullMoon"]:
            disc(buf, mx, my + 2, 5, P["harvestMoon"])
            for c in [(-2, -1), (2, 2), (-1, 3), (1, 0)]:
                px(buf, mx + c[0], my + 2 + c[1], P["harvestCrater"])
        else:
            disc(buf, mx, my, 4, P["moon"])
            if env["fullMoon"]:
                for c in [(-1, -1), (2, 1), (0, 2)]:
                    px(buf, mx + c[0], my + c[1], P["crater"])
            else:
                # the shadow slides across with the real phase
                off = (env["phase"] - 0.5) * 16
                if abs(off) < 8:
                    disc(buf, mx + off, my - 1, 4, P["sky"][0])

        # a shooting star once a loop
        if f >= 70 and f < 76:
            k = f - 70
            for j in range(3):
                px(buf, 20 + k * 3 - j * 2, 2 + k - j, P["star"] if j == 0 else P["cloud"])
    else:
        tod = env["tod"]
        sx = 9 if tod == "dawn" else (50 if tod == "dusk" else 55)
        sy = 9 if tod != "day" else 5
        disc(buf, sx, sy, 3, P["sun"])
        for i in range(8):
            a = i / 8.0 * 2 * math.pi + (math.pi / 8 if f % 2 else 0)
            px(buf, sx + math.round(math.cos(a) * 5), sy + math.round(math.sin(a) * 5), P["ray"])
            px(buf, sx + math.round(math.cos(a) * 6), sy + math.round(math.sin(a) * 6), P["ray"])

    # clouds drift right; the loop is long enough that they cross a good way
    clouds = [(4.0, 3, 1), (40.0, 8, 0), (70.0, 2, 0)]
    if weather != "clear":
        clouds = clouds + [(22.0, 0, 1), (55.0, 5, 1), (88.0, 1, 0)]
    for i, c in enumerate(clouds):
        tpl = CLOUDS[c[2]]
        cw = len(tpl[0])
        cx = int((c[0] + f * (0.12 + (i % 3) * 0.05) * (2.0 if weather == "storm" else 1.0)) % (W + cw + 4)) - cw - 2
        spr(buf, tpl, cx, c[1], {"a": P["cloud"], "s": P["cloudShade"]})

    # the hot-air balloon and the birds stay down in bad weather
    by = 4 + int(math.round(math.sin(t * 0.8) * 1.2))
    bx = 24 + int(f * 0.05)
    if not overcast:
        spr(buf, BALLOON, bx, by, {"a": P["balloon"][0], "b": P["balloon"][1], "r": P["rope"], "k": P["wood"]})

    # birds by day
    if not night and not overcast:
        for i in range(2):
            x = int((10 + i * 31 + t * (3 + i)) % (W + 10)) - 5
            bird(buf, x, 11 + i * 3 + int(math.round(math.sin(t * 1.5 + i) * 1.5)), (f + i * 2) % 4 < 2, P["bird"])

    # the land goes over the sky
    for y in range(H):
        lrow = land[y]
        brow = buf[y]
        for x in range(W):
            if lrow[x] != None:
                brow[x] = lrow[x]

    # windmill sails turn
    mt = far_y(MX) + 2 - 8
    ang0 = f / float(FRAMES) * math.pi
    for k in range(4):
        a = ang0 + k * math.pi / 2
        ca = math.cos(a)
        sa = math.sin(a)
        for rr in range(1, 6):
            px(buf, MX + math.round(ca * rr), mt + math.round(sa * rr), P["blade"])
            if rr >= 3:
                px(buf, MX + math.round(ca * rr - sa), mt + math.round(sa * rr + ca), P["sail"])
    px(buf, MX, mt, P["iron"])

    # chimney smoke by day, and on any wet day
    if not evening or wet:
        for i in range(3):
            age = ((f * 0.25 + i * 3) % 9) / 9.0
            px(buf, HX + 9 + math.round(age * 3 + math.sin(age * 6) * 0.6), HY - 7 - age * 6, P["smoke"])

    # Christmas: lights along the eaves, twinkling from dusk
    if env["christmas"]:
        bulbs = ["#ff3d4f", "#ffd23f", "#3fbdf0", "#2fd28c"]
        for n, k in enumerate(range(0, 12, 2)):
            on = (not evening) or (f + n * 3) % 10 < 7
            px(buf, HX - 1 + k, HY - 1, bulbs[n % 4] if on else P["iron"])

    # the tree, its crown leaning with the breeze
    shape = TREE.get(season, TREE["summer"])
    cmap = {"l": P["leavesLight"], "p": P["leaves"], "d": P.get("trunkDark", P["leavesDark"]) if season == "winter" else P["leavesDark"], "t": P["trunk"], "f": P["fruit"], "w": P.get("blossom", P["leavesLight"])}
    if season == "winter":
        cmap["l"] = P["snow"] if not night else P["leavesLight"]
    sway = 1 if math.sin(t * 0.9) > 0.6 else 0
    top = GY - len(shape)
    for r, line in enumerate(shape):
        dx = sway if r < 3 else 0
        for c, ch in enumerate(line.elems()):
            if ch != ".":
                px(buf, TX + c + dx, top + r, cmap[ch])

    # autumn: pumpkins by the cottage, carved and glowing at Halloween after dark
    if season == "autumn":
        for i, x in enumerate([26, 29]):
            face = P["pumpkin"]
            if env["halloween"]:
                face = (P["lit"] if f % 6 < 5 else "#ff9f40") if evening else P["iron"]
            spr(buf, PUMPKIN, x, GY - 3 + (1 if i else 0), {"g": P["stem"], "o": P["pumpkin"], "r": P["pumpkinRib"] if not env["halloween"] else face})

    # the pond: a moving glint and a duck paddling back and forth
    gx = PX0 + 2 + int((f // 4) % 7)
    px(buf, gx, GY + 1, P["glint"])
    if not night:
        dxp = PX0 + 1 + int(2.5 + 2.5 * math.sin(t * 0.4))
        spr(buf, DUCK, dxp, GY - 1, {"w": P["duck"], "g": P["duckHead"], "o": P["bill"]})

    # the little Pixeltron's screen plays a tiny rainbow
    for i in range(6):
        for j in range(2):
            col = P["led"][(i + j + f // 2) % 4]
            if (i + j + f) % 5 != 0:
                px(buf, PXT + 2 + i, 25 + j, col)

    # tufts and flowers sway
    for i, x in enumerate(TUFTS):
        lean = 1 if (f // 4 + i) % 4 == 0 else 0
        px(buf, x, GY - 1, P["tuft"])
        px(buf, x + lean, GY - 2, P["tuft"])
    for x, ci in FLOWERS:
        px(buf, x, GY - 1, P["stem"])
        px(buf, x, GY - 2, P["stem"])
        px(buf, x, GY - 3, P["flowers"][ci])
        if not night:
            px(buf, x - 1, GY - 3, P["flowers"][ci])
            px(buf, x + 1, GY - 3, P["flowers"][ci])

    # Nibbit's friend the bunny: sits, twitches, hops a little
    hop = (f % 40) >= 30
    bx = 27 if season != "autumn" else 31
    bunny = BUN_HOP if hop else BUN
    if not wet:
        spr(buf, bunny, bx + (1 if hop and f % 2 else 0), GY - 3 - (1 if hop else 0), {"e": P["ear"], "w": P["bun"], "k": P["eye"], "s": P["bunShade"]})

    # fireflies on summer evenings
    if season == "summer" and evening:
        for i in range(6):
            if (f + i * 5) % 12 < 8:
                px(buf, hashf(i + 9) * W, GY - 2 - hashf(i + 3) * 6 + math.sin(t + i), P.get("fly", "#ffe066"))

    # the weather: the site's two-pixel rain streaks, heavier snow, lightning
    if weather in ["rain", "storm"]:
        wind = 0.6 if weather == "storm" else 0.3
        for i in range(40 if weather == "storm" else 30):
            x = (hashf(i) * (W + 16) + f * wind) % (W + 16) - 8
            y = (hashf(i + 31) * (H + 6) + f * 3) % (H + 6) - 3
            px(buf, x, y, P["rain"])
            px(buf, x - (1 if weather == "storm" else 0), y + 1, P["rain"])
        if f % 3 == 0:
            px(buf, PX0 + 2 + int(hashf(f) * 7), GY + 1 + int(hashf(f + 1) * 2), P["glint"])
    if weather == "storm" and f % 40 in [12, 14]:
        for x0, y0 in [(30, 0), (28, 3), (31, 3), (27, 7), (29, 7), (26, 11)]:
            px(buf, x0, y0, "#ffd23f")
            px(buf, x0, y0 + 1, "#ffd23f")
            px(buf, x0, y0 + 2, "#fff8ef")
    if weather == "snow":
        for i in range(34):
            x = (hashf(i) * W + math.sin(t * 0.7 + i) * 1.5 + f * 0.15) % W
            y = (hashf(i + 20) * H + f * (0.3 + 0.1 * (i % 3))) % H
            px(buf, x, y, P["snowfall"])

    # the season in the air: petals, falling leaves or snow
    if wet:
        pass
    elif season == "spring":
        for i in range(8):
            x = (hashf(i) * W + f * 0.6) % W
            y = (hashf(i + 20) * H + f * 0.3) % H
            px(buf, x, y, P["petals"][i % 3])
    elif season == "autumn":
        for i in range(6):
            x = (hashf(i) * W + math.sin(t + i) * 2 + f * 0.2) % W
            y = (hashf(i + 20) * H + f * 0.25) % H
            px(buf, x, y, P["fallLeaves"][i % 3])
    elif season == "winter":
        for i in range(18):
            x = (hashf(i) * W + math.sin(t * 0.7 + i) * 1.5) % W
            y = (hashf(i + 20) * H + f * (0.2 + 0.1 * (i % 3))) % H
            px(buf, x, y, P["snowfall"])

    return buf

def main(config):
    tz = config.get("$tz", "America/New_York")
    now = time.now().in_location(tz)
    test = [w.strip() for w in config.get("world", "").lower().split(",") if w.strip()]
    env = world_env(now, test, config.bool("night", True))

    weather = "clear"
    loc = config.get("location")
    if loc and config.bool("weather", True):
        weather = fetch_weather(json.decode(loc))
    for k in ["clear", "cloudy", "rain", "storm", "snow", "fog"]:
        if k in test:
            weather = k
    env["weather"] = weather

    P = palette(env)
    P["rain"] = "#4a6a9a" if env["night"] else "#3fbdf0"
    P = dimmed(P, weather, env["night"])

    sky = sky_layer(P)
    land = land_layer(P, env)
    frames = [buf_to_widget(frame(f, sky, land, P, env)) for f in range(FRAMES)]
    child = render.Animation(children = frames)

    if config.bool("time", False):
        fmt = "15:04" if config.bool("24h", False) else "3:04"
        child = render.Stack(children = [child, outlined(now.format(fmt), "tb-8", "#fff8ef", "#1d1530")])

    return render.Root(delay = DELAY, show_full_animation = True, child = child)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(id = "location", name = "Location", desc = "Where to take the weather from. Leave it unset for fair weather always.", icon = "locationDot"),
            schema.Toggle(id = "weather", name = "Real weather", desc = "Rain, snow, fog and storms when your location has them.", icon = "cloudRain", default = True),
            schema.Toggle(id = "night", name = "Lights off after dark", desc = "Switch the world to night from 8 pm to 5 am. Off, it stays at dusk like the site's bright theme.", icon = "moon", default = True),
            schema.Toggle(id = "time", name = "Show the time", desc = "Put the time in the corner of the sky.", icon = "clock", default = False),
            schema.Toggle(id = "24h", name = "24-hour time", desc = "Show the time in 24-hour format.", icon = "clock", default = False),
            schema.Text(id = "world", name = "Preview", desc = "Like the site's ?world=: any of dawn, day, dusk, night, spring, summer, autumn, winter, fullmoon, halloween, christmas, and for the weather clear, cloudy, rain, storm, snow, fog. Leave empty to follow the real date and time.", icon = "eye", default = ""),
        ],
    )
