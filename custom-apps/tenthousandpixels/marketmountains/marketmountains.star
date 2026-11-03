"""
Applet: Market Mountains
Summary: A coin's day as a mountain range
Description: The last 24 hours of a coin's price drawn as a mountain ridge, under a morning sky when it is up and a dusk sky when it is down, with the price and the day's change. Prices from CoinGecko, no key needed.
Author: TenThousandPixels
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

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

COINS = {
    "bitcoin": "BTC",
    "ethereum": "ETH",
    "solana": "SOL",
    "dogecoin": "DOGE",
    "cardano": "ADA",
    "ripple": "XRP",
}

def fetch(coin):
    url = "https://api.coingecko.com/api/v3/coins/%s/market_chart?vs_currency=usd&days=1" % coin
    resp = http.get(url, ttl_seconds = 600)
    if resp.status_code != 200:
        return None
    return [p[1] for p in resp.json().get("prices", [])]

def total(xs):
    s = 0.0
    for v in xs:
        s += v
    return s

def resample(series, n):
    out = []
    for i in range(n):
        a = int(i * len(series) / n)
        b = max(a + 1, int((i + 1) * len(series) / n))
        chunk = series[a:b]
        out.append(total(chunk) / len(chunk))
    return out

def commas(n):
    s = str(n)
    out = ""
    for i in range(len(s)):
        if i > 0 and (len(s) - i) % 3 == 0:
            out += ","
        out += s[i]
    return out

def fmt_price(p):
    if p >= 1000:
        return "$" + commas(int(math.round(p)))
    if p >= 1:
        return "$" + str(math.round(p * 100) / 100.0)
    return "$" + str(math.round(p * 10000) / 10000.0)

def frame(ridge, back, up, t):
    if up:
        top, low = (40, 150, 235), (255, 225, 160)
        near_top, near_low = (47, 210, 140), (12, 90, 80)
        far = (150, 190, 230)
    else:
        top, low = (60, 30, 110), (255, 110, 120)
        near_top, near_low = (255, 143, 184), (70, 30, 90)
        far = (170, 110, 190)
    buf = []
    for y in range(H):
        c = mix(top, low, y / (H - 1.0))
        buf.append([c for _ in range(W)])

    # sun: high when up, sinking when down
    sx, sy = 50, (8 if up else 17)
    for y in range(H):
        for x in range(W):
            dx = x - sx
            dy = y - sy
            d = math.sqrt(dx * dx + dy * dy)
            if d < 3.5:
                buf[y][x] = mix(CREAM, SUN, d / 3.5)
            elif d < 12:
                buf[y][x] = add(buf[y][x], (255, 180, 80), (1 - (d - 3.5) / 8.5) * (0.3 + 0.08 * math.sin(t)))

    # far ridge, hazy
    for x in range(W):
        for y in range(int(back[x]), H):
            buf[y][x] = mix(buf[y][x], far, 0.7)

    # near ridge with snow on the high ground
    peak = min(ridge)
    for x in range(W):
        ry = ridge[x]
        for y in range(int(ry), H):
            depth = (y - ry) / max(1.0, H - ry)
            c = mix(near_top, near_low, depth)
            if y - ry < 1.5 and ry < peak + 2.5:
                c = CREAM
            buf[y][x] = c

    # a glint runs along the ridge from yesterday to now
    gx = int((t / (2 * math.pi)) * (W - 2))
    gy = int(ridge[gx])
    if gy - 1 >= 0:
        buf[gy - 1][gx] = SUN

    # the flag on the summit of now
    fx = W - 2
    fy = int(ridge[fx])
    for y in range(fy - 5, fy):
        if y >= 0:
            buf[y][fx] = MIDNIGHT
    wave = 1 if math.sin(t * 3) > 0 else 0
    for dy in range(2):
        for dx in range(1, 3):
            y = fy - 5 + dy + (wave if dx == 2 else 0)
            x = fx - dx
            if y >= 0:
                buf[y][x] = CHERRY

    buf[1][62] = SUN
    return [[rgb(c) for c in row] for row in buf]

def main(config):
    coin = config.get("coin", "bitcoin")
    if coin == "custom":
        coin = config.get("custom", "bitcoin").strip().lower()
    symbol = COINS.get(coin, coin[:4].upper())

    prices = fetch(coin)
    if not prices:
        return render.Root(child = render.Box(color = "#1d1530", child = render.WrappedText("NO PRICE FOR " + symbol, font = "tom-thumb", color = "#ffd23f", align = "center")))
    if config.get("flip") == "1":
        # preview hook: draw the same day falling
        prices = list(reversed(prices))

    first = prices[0]
    last = prices[-1]
    change = (last - first) / first * 100.0
    up = change >= 0

    # 14 anchor points across the day, joined with smooth slopes, read as peaks and valleys
    anchors = resample(prices, 14)
    lo = min(anchors)
    hi = max(anchors)
    span = max(hi - lo, hi * 0.002)
    ys = [29 - (p - lo) / span * 15 for p in anchors]
    ridge = []
    for x in range(W):
        u = x / (W - 1.0) * (len(ys) - 1)
        i = min(int(u), len(ys) - 2)
        f = u - i
        f = 0.5 - 0.5 * math.cos(f * math.pi)
        ridge.append(ys[i] + (ys[i + 1] - ys[i]) * f)

    # the far ridge is a slower echo of the same day, lifted
    back = []
    for x in range(W):
        win = ridge[max(0, x - 8):min(W, x + 9)]
        back.append(total(win) / len(win) - 6 + 1.5 * math.sin(x * 0.3))

    pct = str(math.round(abs(change) * 10) / 10.0)
    chg = ("+" if up else "-") + pct + "%"
    chg_col = "#2fd28c" if up else "#ff3d4f"

    frames = []
    for f in range(FRAMES):
        t = f * 2.0 * math.pi / FRAMES
        frames.append(render.Stack(children = [
            buf_to_widget(frame(ridge, back, up, t)),
            render.Padding(pad = (0, 0, 0, 0), child = outlined(symbol, "tom-thumb", "#ffd23f", "#1d1530")),
            render.Padding(pad = (len(symbol) * 4 + 3, 0, 0, 0), child = outlined(chg, "tom-thumb", chg_col, "#1d1530")),
            render.Padding(pad = (0, 6, 0, 0), child = outlined(fmt_price(last), "6x13", "#fff8ef", "#1d1530", bold = True)),
        ]))

    return render.Root(delay = DELAY, show_full_animation = True, child = render.Animation(children = frames))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "coin",
                name = "Coin",
                desc = "Which price to draw.",
                icon = "coins",
                default = "bitcoin",
                options = [
                    schema.Option(display = "Bitcoin", value = "bitcoin"),
                    schema.Option(display = "Ethereum", value = "ethereum"),
                    schema.Option(display = "Solana", value = "solana"),
                    schema.Option(display = "Dogecoin", value = "dogecoin"),
                    schema.Option(display = "Cardano", value = "cardano"),
                    schema.Option(display = "XRP", value = "ripple"),
                    schema.Option(display = "Other (CoinGecko id below)", value = "custom"),
                ],
            ),
            schema.Text(id = "custom", name = "CoinGecko id", desc = "Used when Coin is Other, for example 'chainlink'.", icon = "magnifyingGlass", default = ""),
        ],
    )
