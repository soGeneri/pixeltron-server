"""
Applet: Commit Garden
Summary: Your GitHub activity as a garden
Description: The last three weeks of your GitHub contributions grown in three raised beds, one per week. Busier days grow bigger flowers, from tulips to sunflowers, in a dozen species. The garden follows the seasons and the time of day, a different visitor drops by each hour, and a full week earns its bed a flag.
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
TAU = 2.0 * math.pi

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

def outlined(text, font, color, shadow):
    layers = []
    for d in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
        layers.append(render.Padding(pad = (1 + d[0], 1 + d[1], 0, 0), child = render.Text(content = text, font = font, color = shadow)))
    layers.append(render.Padding(pad = (1, 1, 0, 0), child = render.Text(content = text, font = font, color = color)))
    return render.Stack(children = layers)

def seeded(s):
    v = hash(s)
    return -v if v < 0 else v

CREAM = (255, 248, 239)
SUN = (255, 210, 63)
MIDNIGHT = (29, 21, 48)
CHERRY = (255, 61, 79)
STEM = (22, 128, 82)
LEAF = (47, 200, 130)
SOIL = (92, 56, 48)
SOIL_DOT = (122, 78, 60)
PLANK = (176, 108, 62)
PLANK_HI = (214, 150, 92)
POST = (120, 70, 44)
PETAL_GOLD = (255, 172, 36)
SEED = (110, 58, 40)
FIREFLY = (200, 245, 120)

# sky top and horizon by time of day; night is deep indigo, never black
SKIES = {
    "dawn": ((150, 186, 238), (255, 210, 172)),
    "day": ((86, 178, 240), (255, 226, 196)),
    "dusk": ((104, 76, 168), (255, 146, 112)),
    "night": ((26, 32, 78), (66, 62, 128)),
}

# what the light does to everything on the ground
TINTS = {
    "dawn": ((255, 200, 170), 0.1),
    "day": ((255, 255, 255), 0.0),
    "dusk": ((150, 70, 120), 0.22),
    "night": ((38, 42, 100), 0.36),
}

# far hill, near hill, lawn, lawn shadow
LANDS = {
    "spring": ((150, 200, 224), (104, 196, 128), (72, 206, 122), (44, 164, 98)),
    "summer": ((122, 186, 214), (58, 160, 98), (47, 190, 110), (30, 148, 90)),
    "autumn": ((196, 176, 172), (164, 128, 84), (150, 170, 72), (120, 136, 56)),
    "winter": ((200, 214, 236), (226, 236, 248), (238, 244, 252), (200, 214, 236)),
}

BLOOMS = {
    "spring": [(255, 90, 140), (255, 176, 60), (170, 110, 240), (70, 160, 240), (255, 252, 246)],
    "summer": [(255, 61, 79), (255, 128, 176), (155, 93, 229), (63, 170, 240), (255, 132, 60)],
    "autumn": [(224, 44, 60), (252, 212, 90), (150, 70, 180), (255, 240, 222), (246, 120, 40)],
    "winter": [(220, 40, 60), (255, 120, 160), (160, 120, 230), (90, 150, 240), (244, 244, 252)],
}

PHASES = ["dawn", "day", "dusk", "night"]
SEASONS = ["spring", "summer", "autumn", "winter"]
VISITORS = ["butterfly", "ladybug", "snail", "bird"]

GROUND = 25  # first soil row; stems stand on the row above

def fetch(user):
    resp = http.get("https://github-contributions-api.jogruber.de/v4/%s?y=last" % user, ttl_seconds = 1800)
    if resp.status_code != 200:
        return None
    return resp.json().get("contributions")

def put(buf, x, y, c):
    if x >= 0 and x < W and y >= 0 and y < H:
        buf[y][x] = c

def paint(buf, env, x, y, c):
    # ground-level things take on the light of the hour
    put(buf, x, y, mix(c, env["tint"][0], env["tint"][1]))

def paint_bloom(buf, env, x, y, c):
    # petals hold their colour better than the ground as the light goes
    put(buf, x, y, mix(c, env["tint"][0], env["tint"][1] * 0.45))

def plant_x(i):
    b = i // 7
    return b * 21 + (2 if b == 2 else 1) + (i % 7) * 3

# each size of flower has its own height, so a busy week reads as a skyline
HEIGHTS = [0, 5, 8, 10, 13]

def sky(env, t, f):
    top, low = SKIES[env["phase"]]
    buf = []
    for y in range(H):
        c = mix(top, low, (y - 4) / 20.0)
        buf.append([c for _ in range(W)])

    if env["phase"] == "night":
        for k, s in enumerate([(31, 2), (32, 6), (8, 10), (19, 12), (44, 11), (52, 15), (3, 15), (27, 13), (36, 9), (13, 16), (61, 12)]):
            on = (k * 5 + f) % 11
            if on != 0:
                put(buf, s[0], s[1], mix(CREAM, low, 0.5 if on < 4 else 0.1))

        # a crescent moon under the run label
        for p in [(57, 9), (58, 9), (56, 10), (56, 11), (57, 12), (58, 12)]:
            put(buf, p[0], p[1], (250, 244, 214))
        put(buf, 57, 10, mix((250, 244, 214), top, 0.6))
        return buf

    # two soft clouds drifting through the gap under the labels
    tint = {"dawn": (255, 214, 200), "day": CREAM, "dusk": (255, 170, 176)}[env["phase"]]
    for i in range(2):
        cx = (i * 38 + t / TAU * 64) % 84 - 10
        cy = 11 + i * 3
        for y in range(cy - 2, cy + 1):
            for x in range(int(cx) - 5, int(cx) + 6):
                dx = (x - cx) / 5.0
                dy = (y - cy + 0.5) / 1.6
                if dx * dx + dy * dy < 1.0 and x >= 0 and x < W:
                    buf[y][x] = mix(buf[y][x], tint, 0.85)
    return buf

def land(buf, env, flags):
    far_c, near_c, lawn, lawn_dark = LANDS[env["season"]]
    winter = env["season"] == "winter"
    for x in range(W):
        far = int(17 + 2.5 * math.sin(x * 0.11 + 0.6) + 1.2 * math.sin(x * 0.31))
        for y in range(far, GROUND):
            c = far_c if y > far else mix(far_c, CREAM, 0.3)
            paint(buf, env, x, y, c)
        near = int(21 + 1.6 * math.sin(x * 0.19 + 2.2))
        for y in range(near, GROUND):
            c = near_c if y > near else mix(near_c, CREAM if winter else (180, 230, 140), 0.5)
            paint(buf, env, x, y, c)

    # three raised beds, one per week
    for b in range(3):
        x0 = b * 21
        x1 = 63 if b == 2 else x0 + 20
        for x in range(x0, x1 + 1):
            paint(buf, env, x, GROUND, SOIL_DOT if (x * 5 + b) % 7 == 0 else SOIL)
            paint(buf, env, x, GROUND + 1, (240, 246, 255) if winter else PLANK_HI)
            paint(buf, env, x, GROUND + 2, PLANK if (x + b) % 9 != 0 else POST)
        for px in [x0, x1]:
            paint(buf, env, px, GROUND - 1, (240, 246, 255) if winter else POST)
            for y in range(GROUND, GROUND + 3):
                paint(buf, env, px, y, POST)

    # lawn in front
    for x in range(W):
        for y in range(GROUND + 3, H):
            paint(buf, env, x, y, lawn_dark if (x * 3 + y) % 5 == 0 else lawn)
        if not winter and (x * 7) % 11 < 2:
            paint(buf, env, x, GROUND + 2, lawn)

    if env["season"] == "autumn":
        # pumpkins on the lawn
        for px in [9, 48]:
            for p in [(0, 29), (1, 29), (2, 29), (0, 30), (1, 30), (2, 30)]:
                paint(buf, env, px + p[0], p[1], (232, 118, 32) if p[0] != 1 else (204, 92, 24))
            paint(buf, env, px + 1, 28, (90, 120, 40))

def flag(buf, env, x0, t):
    # a finished week (no empty days) earns its bed a pennant
    ft = GROUND - 10
    for y in range(ft, GROUND - 1):
        paint(buf, env, x0, y, POST)
    wave = int(t * 4 / TAU) % 2
    paint_bloom(buf, env, x0 + 1, ft, CREAM)
    paint_bloom(buf, env, x0 + 2, ft, CREAM)
    paint_bloom(buf, env, x0 + 3, ft + wave, CHERRY)
    paint_bloom(buf, env, x0 + 1, ft + 1, CHERRY)
    paint_bloom(buf, env, x0 + 2, ft + 1 + wave, CREAM)

def draw_plant(buf, env, i, d, t, today):
    count = int(d["count"])
    lvl = min(4, max(1, int(d.get("level", 1)))) if count > 0 else 0
    seed = seeded(d["date"] + env["user"])
    kind = seed % 3
    x = plant_x(i)
    base = GROUND - 1
    if lvl == 0:
        # a quiet day: a little sprout, or a snowdrop in winter
        paint(buf, env, x, base, LEAF)
        paint(buf, env, x - 1, base - 1, LEAF)
        paint(buf, env, x + 1, base - 1, (240, 246, 255) if env["season"] == "winter" else LEAF)
        return None

    h = HEIGHTS[lvl] + (count % 2)
    top = base - h + 1
    sway = math.sin(t + i * 0.8)
    lean = int(math.round(sway * 0.8))
    for y in range(top, base + 1):
        dx = lean if y < top + h // 3 else 0
        paint(buf, env, x + dx, y, STEM)

    side = 1 if seed % 2 else -1
    paint(buf, env, x + side, base - h // 3, LEAF)
    if lvl >= 3:
        paint(buf, env, x - side, base - (2 * h) // 3 + 1, LEAF)

    bx = x + lean
    palette = BLOOMS[env["season"]]
    col = palette[(seed // 3) % len(palette)]
    glow = 0.25 + 0.25 * math.sin(t * 2) if today else 0.0
    c = mix(col, CREAM, glow)
    lite = mix(c, CREAM, 0.4)
    dark = mix(c, MIDNIGHT, 0.35)
    pts = []

    if lvl == 1:
        if kind == 0:
            # tulip
            pts = [(-1, -1, c), (1, -1, c), (-1, 0, c), (0, 0, c), (1, 0, c), (0, 1, c), (0, -1, lite)]
        elif kind == 1:
            # bluebells nodding off a curled tip
            pts = [(0, -1, STEM), (1, 0, c), (1, 1, dark), (-1, 1, c), (-1, 2, dark)]
        else:
            # a closed bud in its sepals
            pts = [(0, -1, lite), (0, 0, c), (-1, 1, LEAF), (1, 1, LEAF)]
    elif lvl == 2:
        if kind == 0:
            # daisy
            pts = [(-1, 0, c), (1, 0, c), (0, -1, c), (0, 1, c), (0, 0, CREAM)]
        elif kind == 1:
            # poppy: an open cup with a dark eye
            pts = [(-1, -1, c), (1, -1, c), (-1, 0, c), (1, 0, c), (0, 0, MIDNIGHT), (0, 1, dark)]
        else:
            # lavender spike
            pts = [(0, -3, lite), (0, -2, c), (-1, -1, c), (0, -1, lite), (1, 0, c), (0, 0, c), (-1, 1, dark)]
    elif lvl == 3:
        if kind == 0:
            # full bloom with a crown
            pts = [(dx, dy, c) for dy in [-1, 0, 1] for dx in [-1, 0, 1]] + [(0, -2, c), (0, 0, CREAM), (-1, -1, lite)]
        elif kind == 1:
            # allium: a speckled ball on a bare stem
            pts = [(0, -2, c), (-1, -1, lite), (0, -1, c), (1, -1, dark), (-1, 0, c), (0, 0, lite), (1, 0, c), (0, 1, dark)]
        else:
            # rose: petals spiralling into a dark heart
            pts = [(dx, dy, c) for dy in [-1, 0] for dx in [-1, 0, 1]] + [(0, 1, dark), (0, -1, dark), (-1, -1, lite), (1, 0, dark), (-1, 1, LEAF), (1, 1, LEAF)]
    else:
        if kind == 0:
            # sunflower
            g = mix(PETAL_GOLD, CREAM, glow)
            pts = [(dx, dy, g) for dy in [-1, 0, 1] for dx in [-1, 0, 1]] + [(0, -2, g), (0, 0, SEED), (-1, -1, mix(g, CREAM, 0.4))]
        elif kind == 1:
            # hollyhock: blooms stacked down the stem
            pts = [(0, -1, lite), (0, 0, c)]
            for k, y in enumerate([2, 5, 8]):
                s = 1 if k % 2 == 0 else -1
                pts += [(s, y, c), (s, y + 1, dark), (0, y, lite)]
        else:
            # foxglove: bells hanging down one side
            pts = [(0, -1, lite), (0, 0, c)]
            for y in [1, 3, 5, 7]:
                pts += [(1, y, c), (1, y + 1, dark)]
            pts += [(-1, 2, c), (-1, 4, c)]

    for p in pts:
        px = bx + p[0] if p[1] < h // 3 else x + p[0]
        paint_bloom(buf, env, px, top + p[1], p[2])
    if env["season"] == "winter" and lvl >= 2:
        paint(buf, env, bx, top - (3 if kind == 2 and lvl == 2 else 2), (244, 248, 255))
    return (bx, top)

def particles(buf, env, t):
    p = t / TAU
    season = env["season"]
    if season == "spring":
        n, cols = 5, [(255, 200, 220), (255, 236, 244)]
    elif season == "autumn":
        n, cols = 5, [(230, 100, 40), (240, 170, 50), (190, 70, 50)]
    elif season == "winter":
        n, cols = 9, [(250, 252, 255), (226, 236, 250)]
    else:
        return
    for k in range(n):
        y = int((k * 11 + p * 32 * (2 if season == "winter" else 1)) % 32)
        x = int((k * 23 + 7) % 64 + 2.5 * math.sin(t * 2 + k * 1.7))
        if y > 8 and y < GROUND + 3:
            put(buf, x % W, y, cols[k % len(cols)])

def visitor(buf, env, days, heads, t, f):
    v = env["visitor"]
    winter = env["season"] == "winter"
    if v == "butterfly" and not winter:
        x = int(8 + 46 * (0.5 + 0.5 * math.sin(t)))
        y = int(15 + 3 * math.sin(t * 3))
        wing = (255, 143, 184) if env["season"] != "autumn" else (240, 140, 40)
        put(buf, x, y, MIDNIGHT)
        if f % 2 == 0:
            put(buf, x - 1, y, wing)
            put(buf, x + 1, y, wing)
            put(buf, x - 1, y - 1, mix(wing, CREAM, 0.4))
            put(buf, x + 1, y - 1, mix(wing, CREAM, 0.4))
        else:
            put(buf, x, y - 1, wing)
    elif v == "ladybug" and not winter:
        k = -1
        for j in range(DAYS):
            jj = (env["seed"] + j * 5) % DAYS
            if heads[jj] != None and jj < len(days) - 1:
                k = jj
                break
        if k < 0:
            return
        x = plant_x(k)
        top = heads[k][1] + 2
        y = int(GROUND - 1 - (0.5 - 0.5 * math.cos(t)) * (GROUND - 1 - top))
        put(buf, x, y, (230, 40, 50))
        put(buf, x, y - 1 if math.sin(t) > 0 else y + 1, MIDNIGHT)
    elif v == "snail" and not winter:
        x = 14 + env["seed"] % 30
        for p in [(0, 29), (1, 29), (0, 30), (1, 30)]:
            paint(buf, env, x + p[0], p[1], (210, 140, 70) if p != (1, 30) else (150, 90, 50))
        for dx in [-1, 0, 1, 2]:
            paint(buf, env, x + dx, 31, (214, 200, 176))
        paint(buf, env, x + 2, 30, (214, 200, 176))
        paint(buf, env, x + 3 if f % 8 < 4 else x + 2, 29, (214, 200, 176))
    else:
        # a bird on a fence post: a robin in the cold months, a bluebird otherwise
        px = [20, 41][env["seed"] % 2]
        body = (200, 80, 50) if winter or env["season"] == "autumn" else (80, 120, 210)
        hop = 1 if f % 16 == 3 or f % 16 == 4 else 0
        y = GROUND - 3 - hop
        paint(buf, env, px, y + 1, (110, 80, 70))
        paint(buf, env, px, y, body)
        paint(buf, env, px + 1, y, (110, 80, 70))
        look = 1 if f % 16 < 10 else -1
        paint(buf, env, px + look, y - 1 if look < 0 else y - 1, (110, 80, 70))
        paint(buf, env, px + 2 * look, y - 1, (240, 170, 60))

def frame(days, env, t, f):
    buf = sky(env, t, f)
    land(buf, env, None)
    heads = []
    for i, d in enumerate(days):
        heads.append(draw_plant(buf, env, i, d, t, i == len(days) - 1))
    head = heads[-1] if heads[-1] != None else (plant_x(len(days) - 1), GROUND - 2)

    particles(buf, env, t)
    for b in range(3):
        week = days[b * 7:b * 7 + 7]
        if len(week) == 7 and len([d for d in week if int(d["count"]) > 0]) == 7:
            flag(buf, env, b * 21, t)
    if env["phase"] != "night":
        visitor(buf, env, days, heads, t, f)

    # today's plant gets a twinkle beside it
    if f % 8 < 2:
        put(buf, head[0] - 3, head[1] - 2, CREAM)

    if env["season"] == "winter":
        # no bees in winter: a lantern burns on the post beside today
        put(buf, 63, GROUND - 3, POST)
        put(buf, 63, GROUND - 2, mix(SUN, (255, 140, 60), 0.5 + 0.5 * math.sin(t * 5)))
        put(buf, 62, GROUND - 2, mix(SUN, buf[GROUND - 2][62], 0.6))
    elif env["phase"] == "night":
        # fireflies, and the brightest one keeps watch over today
        for k in range(5 if env["season"] == "summer" else 3):
            fx = int(8 + (k * 17) % 50 + 3 * math.sin(t + k * 2))
            fy = int(14 + (k * 5) % 8 + 2 * math.cos(t * 2 + k))
            if (f + k * 7) % 12 < 8:
                put(buf, fx, fy, FIREFLY)
        bx = int(math.round(head[0] - 5 + 4 * math.cos(t)))
        by = int(math.round(head[1] - 4 + 2 * math.sin(t * 2)))
        put(buf, bx, by, SUN)
        put(buf, bx + 1, by, mix(SUN, buf[by][min(bx + 1, W - 1)], 0.6))
    else:
        # the bee: the loose sun pixel, circling today's flower
        bx = int(math.round(head[0] - 5 + 4 * math.cos(t)))
        by = int(math.round(head[1] - 4 + 2 * math.sin(t * 2)))
        put(buf, bx, by, SUN)
        put(buf, bx + 1, by, MIDNIGHT)
        if int(t * 4) % 2 == 0:
            put(buf, bx, by - 1, CREAM)

    return [[rgb(c) for c in row] for row in buf]

def scene(config, user, now):
    hour = now.hour
    if hour >= 5 and hour < 8:
        phase = "dawn"
    elif hour >= 8 and hour < 17:
        phase = "day"
    elif hour >= 17 and hour < 20:
        phase = "dusk"
    else:
        phase = "night"
    m = now.month
    season = "spring" if m in [3, 4, 5] else "summer" if m in [6, 7, 8] else "autumn" if m in [9, 10, 11] else "winter"

    # a different visitor drops by each hour
    seed = seeded(now.format("2006-01-02-15") + user)
    vis = VISITORS[seed % len(VISITORS)]

    # preview: any of dawn/day/dusk/night, a season, a visitor, comma separated
    for w in config.get("preview", "").lower().split(","):
        w = w.strip()
        if w in PHASES:
            phase = w
        elif w in SEASONS:
            season = w
        elif w in VISITORS:
            vis = w
    return {"phase": phase, "season": season, "visitor": vis, "seed": seed, "user": user, "tint": TINTS[phase]}

def main(config):
    user = config.get("user", "soGeneri").strip().lstrip("@")
    contribs = fetch(user)
    if contribs == None or len(contribs) == 0:
        return render.Root(child = render.Box(color = "#1d1530", child = render.WrappedText("NO GARDEN FOR " + user.upper(), font = "tom-thumb", color = "#ffd23f", align = "center")))

    now = time.now().in_location(config.get("$tz", "America/New_York"))
    today = now.format("2006-01-02")
    env = scene(config, user, now)

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
        t = f * TAU / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(days, env, t, f)),
            outlined(left, "tom-thumb", "#fff8ef", "#1d1530"),
            render.Padding(pad = (W - 2 - len(right) * 4, 0, 0, 0), child = outlined(right, "tom-thumb", "#ffd23f", "#1d1530")),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "user", name = "GitHub user", desc = "Whose garden to grow.", icon = "github", default = "soGeneri"),
            schema.Text(id = "preview", name = "Preview", desc = "Optional. Force a look, e.g. night,summer or dawn,spring,butterfly. Leave blank to follow the clock.", icon = "eye", default = ""),
        ],
    )
