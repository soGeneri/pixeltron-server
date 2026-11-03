"""
Applet: Status Reef
Summary: Service status as a fish reef
Description: Up to four services you rely on swim as fish in a reef. Healthy fish swim laps, a fish with a minor incident hovers in place, and a major outage floats belly-up while the water turns red. Reads each service's public status page, no key needed.
Author: TenThousandPixels
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

W = 64
H = 32
FRAMES = 60
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
GREY = (150, 146, 170)

# id: (tag, status page host)
SERVICES = {
    "github": ("GH", "www.githubstatus.com"),
    "cloudflare": ("CF", "www.cloudflarestatus.com"),
    "claude": ("AI", "status.claude.com"),
    "openai": ("OAI", "status.openai.com"),
    "discord": ("DC", "discordstatus.com"),
    "vercel": ("VC", "www.vercel-status.com"),
    "digitalocean": ("DO", "status.digitalocean.com"),
}

FISH_COLORS = [(255, 210, 63), (255, 143, 184), (63, 189, 240), (47, 210, 140)]

# drawn facing left: o = eye, t = tail
LONG = [
    "..###...",
    ".#####.t",
    "#o#####t",
    ".#####.t",
    "..###...",
]
ANGEL = [
    "...#...",
    "..##..t",
    ".####tt",
    "#o###tt",
    ".####tt",
    "..##..t",
    "...#...",
]
DART = [
    ".##.t",
    "o###t",
    ".##.t",
]
PUFFER = [
    ".#.#.#.",
    "######t",
    "#o####t",
    "######t",
    ".#.#.#.",
]

# each of the four fish has its own body, heading, pace and swimming style:
# (shape, faces right, laps per loop, bob height, bob speed)
PERSONAS = [
    (LONG, False, 1, 1.0, 2.0),
    (ANGEL, True, 1, 1.0, 1.0),
    (DART, True, 2, 0.6, 4.0),
    (PUFFER, False, 1, 1.0, 1.5),
]

def status_of(host):
    resp = http.get("https://%s/api/v2/status.json" % host, ttl_seconds = 120)
    if resp.status_code != 200:
        return "unknown"
    return resp.json().get("status", {}).get("indicator", "unknown")

def draw_fish(buf, shape, x, y, color, dead, right):
    h = len(shape)
    w = len(shape[0])
    for r, line in enumerate(shape):
        for c, ch in enumerate(line.elems()):
            if ch == ".":
                continue
            px = x + (w - 1 - c if right else c)
            py = y + (h - 1 - r if dead else r)
            if px < 0 or px >= W or py < 0 or py >= H:
                continue
            if ch == "o":
                buf[py][px] = MIDNIGHT
            elif ch == "t":
                buf[py][px] = mix(color, MIDNIGHT, 0.3)
            else:
                buf[py][px] = color

def frame(fish, t, f, alarm):
    buf = []
    for y in range(H):
        c = mix((63, 189, 240), (25, 40, 120), y / (H - 1.0))
        if alarm:
            c = mix(c, (200, 30, 60), (0.25 + 0.12 * math.sin(t * 2)) * (1 - y / (H * 1.5)))
        buf.append([c for _ in range(W)])

    # light shafts from the surface
    for x in range(W):
        for y in range(H - 4):
            k = math.sin((x + y * 0.6) * 0.35 + t)
            if k > 0.8:
                buf[y][x] = mix(buf[y][x], CREAM, (k - 0.8) * 0.9 * (1 - y / 28.0))

    # surface ripple
    for x in range(W):
        if math.sin(x * 0.5 + t * 2) > 0.3:
            buf[0][x] = mix(buf[0][x], CREAM, 0.5)

    # sand and seaweed
    for x in range(W):
        top = 30 if (x * 5) % 7 > 2 else 29
        for y in range(top, H):
            buf[y][x] = (230, 200, 140) if y == top else (200, 160, 110)
    for i, sx in enumerate([4, 13, 27, 40, 52, 60]):
        hgt = 6 + (i * 3) % 5
        for k in range(hgt):
            x = sx + int(math.round(math.sin(t + i + k * 0.4) * (k / float(hgt)) * 1.5))
            y = 29 - k
            if x >= 0 and x < W:
                buf[y][x] = (47, 210, 140) if k % 2 else (20, 140, 90)

    # bubbles
    for i in range(5):
        bx = (i * 13 + 5) % W
        by = int(29 - ((f * 0.6 + i * 9) % 29))
        buf[by][bx] = mix(buf[by][bx], CREAM, 0.7)

    # fish
    for i, fs in enumerate(fish):
        shape, right, laps, bob, speed = PERSONAS[i % len(PERSONAS)]
        w = len(shape[0])

        # lanes by the fish's middle row, spread from below the surface to above the sand
        lane = [10, 16, 21, 26][i % 4] - len(shape) // 2
        fs["w"] = w
        fs["right"] = right
        if fs["state"] == "none" or fs["state"] == "unknown":
            # whole laps per loop so the animation joins up; each fish starts somewhere different
            span = W + 28
            run = (f / float(FRAMES)) * span * laps + i * 23
            x = int(run % span) - 14
            if not right:
                x = W - 1 - x - w
            y = lane + int(math.round(math.sin(t * speed + i * 1.7) * bob))
            draw_fish(buf, shape, x, y, fs["color"] if fs["state"] == "none" else GREY, False, right)
        elif fs["state"] == "minor":
            # hovering in place, fidgeting
            x = 18 + i * 7 + int(math.round(math.sin(t * 4 + i)))
            y = lane + int(math.round(math.sin(t * 6 + i) * 0.6))
            draw_fish(buf, shape, x, y, fs["color"], False, right)
        else:
            # belly-up near the surface, rocking gently
            x = min(6 + i * 13, W - w - 5 - len(fs["tag"] + " DOWN") * 4)
            y = 1 + int(math.round(math.sin(t + i) * 0.6))
            right = False
            fs["right"] = False
            draw_fish(buf, shape, x, y, GREY, True, False)
        fs["x"] = x
        fs["y"] = y + len(shape) // 2 - 2

    buf[H - 1][62] = SUN
    return [[rgb(c) for c in row] for row in buf]

def main(config):
    fish = []
    for slot in range(4):
        sid = config.get("s%d" % (slot + 1), ["github", "cloudflare", "claude", "openai"][slot])
        if sid == "none" or sid not in SERVICES:
            continue
        tag, host = SERVICES[sid]
        st = status_of(host)
        if st == "critical":
            st = "major"
        fish.append({"tag": tag, "state": st, "color": FISH_COLORS[slot]})

    alarm = len([f for f in fish if f["state"] == "major"]) > 0

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        layers = [buf_to_widget(frame(fish, t, f, alarm))]

        # each fish tows its tag behind its tail, whichever way it is swimming
        for fs in fish:
            col = "#fff8ef"
            label = fs["tag"]
            if fs["state"] == "minor":
                col = "#ffd23f"
                label += " SLOW"
            elif fs["state"] == "major":
                col = "#ff3d4f"
                label += " DOWN"
            lw = len(label) * 4
            tx = fs["x"] - lw - 1 if fs["right"] else fs["x"] + fs["w"] + 1
            if tx >= 0 and tx + lw <= W:
                layers.append(render.Padding(pad = (tx, max(0, fs["y"]), 0, 0), child = shadowed(label, col)))

        frames.append(render.Stack(children = layers))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def shadowed(text, color):
    # a one-pixel drop shadow keeps tags readable without boxing the water in
    return render.Stack(children = [
        render.Padding(pad = (1, 1, 0, 0), child = render.Text(content = text, font = "tom-thumb", color = "#1d1530")),
        render.Text(content = text, font = "tom-thumb", color = color),
    ])

def options():
    return [
        schema.Option(display = "GitHub", value = "github"),
        schema.Option(display = "Cloudflare", value = "cloudflare"),
        schema.Option(display = "Claude", value = "claude"),
        schema.Option(display = "OpenAI", value = "openai"),
        schema.Option(display = "Discord", value = "discord"),
        schema.Option(display = "Vercel", value = "vercel"),
        schema.Option(display = "DigitalOcean", value = "digitalocean"),
        schema.Option(display = "Nothing", value = "none"),
    ]

def get_schema():
    defaults = ["github", "cloudflare", "claude", "openai"]
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(id = "s%d" % (i + 1), name = "Fish %d" % (i + 1), desc = "Service to watch.", icon = "fish", default = defaults[i], options = options())
            for i in range(4)
        ],
    )
