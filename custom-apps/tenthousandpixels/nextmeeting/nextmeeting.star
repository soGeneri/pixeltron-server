"""
Applet: Next Meeting
Summary: Next meeting, arriving by train
Description: Your next meeting as a little train pulling into the station: it appears an hour out and rolls in as the start gets closer, then waits at the platform while the meeting runs. Reads the private calendar link (ICS) that Google Calendar, Outlook and iCloud all offer.
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
LOOKAHEAD_DAYS = 7

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
MINT = (47, 210, 140)
GRAPE = (155, 93, 229)
MIDNIGHT = (29, 21, 48)
WOOD = (160, 103, 63)

DAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
DAY_OF = {"Mon": "MO", "Tue": "TU", "Wed": "WE", "Thu": "TH", "Fri": "FR", "Sat": "SA", "Sun": "SU"}

# ---------- calendar parsing ----------

def unfold(text):
    return text.replace("\r\n", "\n").replace("\n ", "").replace("\n\t", "")

def unescape(s):
    return s.replace("\\n", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\").strip()

def parse_dt(prop, value, tz):
    # returns (time, all_day) or (None, False)
    params = prop.split(";")[1:]
    zone = tz
    all_day = False
    for p in params:
        if p.startswith("TZID="):
            zone = p[5:].strip('"')
        if p == "VALUE=DATE":
            all_day = True
    v = value.strip()
    if len(v) == 8:
        all_day = True
    if all_day:
        return None, True
    if len(v) < 15 or not v[:8].isdigit():
        return None, False
    y = int(v[0:4])
    mo = int(v[4:6])
    d = int(v[6:8])
    hh = int(v[9:11])
    mm = int(v[11:13])
    if v.endswith("Z"):
        return time.time(year = y, month = mo, day = d, hour = hh, minute = mm, location = "UTC"), False

    # Outlook writes Windows zone names; fall back to the device's zone for those
    if "/" not in zone and zone != "UTC":
        zone = tz
    return time.time(year = y, month = mo, day = d, hour = hh, minute = mm, location = zone), False

def zone_of(prop, value, tz):
    # the zone an event's wall-clock time belongs to, so repeats keep their local time across DST
    if value.strip().endswith("Z"):
        return "UTC"
    for p in prop.split(";")[1:]:
        if p.startswith("TZID="):
            z = p[5:].strip('"')
            return z if "/" in z or z == "UTC" else tz
    return tz

def parse_duration(v):
    # PT1H30M, PT45M, P1D
    mins = 0
    num = ""
    for ch in v.elems():
        if ch.isdigit():
            num += ch
        elif ch == "D" and num:
            mins += int(num) * 1440
            num = ""
        elif ch == "H" and num:
            mins += int(num) * 60
            num = ""
        elif ch == "M" and num:
            mins += int(num)
            num = ""
        else:
            num = ""
    return mins

def parse_events(text, tz):
    events = []
    for block in unfold(text).split("BEGIN:VEVENT")[1:]:
        block = block.split("END:VEVENT")[0]
        ev = {"rrule": None, "exdates": [], "recid": None, "dur": 30, "summary": "Meeting", "status": "", "uid": ""}
        end = None
        for line in block.split("\n"):
            if ":" not in line:
                continue
            i = line.index(":")
            prop = line[:i]
            val = line[i + 1:]
            name = prop.split(";")[0].upper()
            if name == "DTSTART":
                ev["start"], ev["allday"] = parse_dt(prop, val, tz)
                ev["zone"] = zone_of(prop, val, tz)
            elif name == "DTEND":
                end, _ = parse_dt(prop, val, tz)
            elif name == "DURATION":
                ev["dur"] = parse_duration(val)
            elif name == "SUMMARY":
                ev["summary"] = unescape(val)
            elif name == "RRULE":
                ev["rrule"] = val.strip()
            elif name == "EXDATE":
                for part in val.split(","):
                    t, _ = parse_dt(prop, part, tz)
                    if t != None:
                        ev["exdates"].append(t.unix)
            elif name == "RECURRENCE-ID":
                t, _ = parse_dt(prop, val, tz)
                if t != None:
                    ev["recid"] = t.unix
            elif name == "STATUS":
                ev["status"] = val.strip().upper()
            elif name == "UID":
                ev["uid"] = val.strip()
        if ev.get("allday") or ev.get("start") == None:
            continue
        if end != None:
            ev["dur"] = max(1, int((end - ev["start"]).minutes))
        events.append(ev)
    return events

def rule_parts(rrule):
    parts = {}
    for kv in rrule.split(";"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            parts[k.upper()] = v
    return parts

def occurrences(ev, window_start, window_end, tz):
    # start times (as time values) of this event that overlap the window
    start = ev["start"]
    dur = time.parse_duration("%dm" % ev["dur"])
    if ev["rrule"] == None:
        if start + dur > window_start and start < window_end:
            return [start]
        return []

    r = rule_parts(ev["rrule"])
    freq = r.get("FREQ", "")
    interval = int(r.get("INTERVAL", "1"))
    count = int(r.get("COUNT", "0"))
    until = None
    if "UNTIL" in r:
        until, _ = parse_dt("UNTIL", r["UNTIL"], tz)
    zone = ev.get("zone", tz)
    local = start.in_location(zone)
    byday = [d[-2:] for d in r.get("BYDAY", "").split(",") if d]
    if freq == "WEEKLY" and not byday:
        byday = [DAY_OF[local.format("Mon")]]

    out = []
    first_day = time.time(year = local.year, month = local.month, day = local.day, location = zone)
    span = int((window_start - first_day).hours // 24) - 1
    span = max(0, span)
    for n in range(span, span + LOOKAHEAD_DAYS + 3):
        cand = time.time(year = local.year, month = local.month, day = local.day + n, hour = local.hour, minute = local.minute, location = zone)
        if cand < start:
            continue
        ok = False
        idx = 0
        if freq == "DAILY":
            ok = n % interval == 0
            idx = n // interval
        elif freq == "WEEKLY":
            wd = DAY_OF[cand.format("Mon")]
            start_monday = local.day - DAYS.index(DAY_OF[local.format("Mon")])
            week = (local.day + n - start_monday) // 7
            ok = wd in byday and week % interval == 0
            idx = (week // interval) * len(byday) + byday.index(wd) if wd in byday else 0
        elif freq == "MONTHLY" and "BYDAY" not in r:
            months = (cand.year - local.year) * 12 + cand.month - local.month
            ok = cand.day == local.day and months % interval == 0
            idx = months // interval
        if not ok:
            continue
        if count and idx >= count:
            continue
        if until != None and cand > until:
            continue
        if cand.unix in ev["exdates"]:
            continue
        if cand + dur > window_start and cand < window_end:
            out.append(cand)
    return out

def next_meeting(text, now, tz, skip_declined):
    events = parse_events(text, tz)
    moved = {}
    for ev in events:
        if ev["recid"] != None:
            moved[ev["uid"] + str(ev["recid"])] = True

    window_end = now + time.parse_duration("%dh" % (24 * LOOKAHEAD_DAYS))
    best = None
    for ev in events:
        if ev["status"] == "CANCELLED":
            continue
        if skip_declined and ev["summary"].lower().startswith("declined"):
            continue
        for st in occurrences(ev, now, window_end, tz):
            if ev["recid"] == None and (ev["uid"] + str(st.unix)) in moved:
                continue
            if best == None or st < best[0]:
                best = (st, ev["dur"], ev["summary"])
    return best

# ---------- the station ----------

def sky_for(hour):
    if hour < 6 or hour >= 20:
        return (12, 8, 30), (50, 30, 100), True
    if hour < 8:
        return (120, 170, 235), (255, 200, 170), False
    if hour < 17:
        return (63, 170, 240), (217, 243, 253), False
    return (110, 80, 180), (255, 150, 120), False

def put(buf, x, y, c):
    x = int(x)
    y = int(y)
    if x >= 0 and x < W and y >= 0 and y < H:
        buf[y][x] = c

def rect(buf, x, y, w, h, c):
    for yy in range(int(y), int(y + h)):
        for xx in range(int(x), int(x + w)):
            put(buf, xx, yy, c)

def frame(f, train_x, at_platform, hour, moving):
    top, low, night = sky_for(hour)
    t = f * 2.0 * math.pi / FRAMES
    buf = []
    for y in range(H):
        c = mix(top, low, y / (H - 1.0))
        buf.append([c for _ in range(W)])
    if night:
        for i, s in enumerate([(3, 2), (11, 5), (20, 1), (29, 4), (37, 2), (45, 6), (8, 9)]):
            put(buf, s[0], s[1], mix(buf[s[1]][s[0]], CREAM, 0.4 + 0.3 * math.sin(t * 2 + i)))
    put(buf, 62, 1, SUN)

    # hills behind the line
    for x in range(W):
        hy = int(18 + 1.5 * math.sin(x * 0.13 + 1) + math.sin(x * 0.31))
        for y in range(hy, 26):
            put(buf, x, y, mix(MINT, MIDNIGHT, 0.65 if night else 0.15))

    # the station: cream wall, stepped cherry roof, a clock, a lit window after dark
    sx = 47
    rect(buf, sx, 15, 15, 8, mix(CREAM, MIDNIGHT, 0.55) if night else CREAM)
    for k in range(4):
        rect(buf, sx + 3 - k, 11 + k, 9 + 2 * k, 1, CHERRY if k % 2 == 0 else (196, 26, 46))
    rect(buf, sx + 6, 9, 3, 2, CREAM)
    put(buf, sx + 7, 9, MIDNIGHT)
    rect(buf, sx + 10, 17, 3, 3, SUN if night else (159, 224, 249))
    rect(buf, sx + 2, 17, 3, 6, WOOD)

    # the platform and a lamp
    rect(buf, 40, 23, 24, 2, (232, 220, 203) if not night else (90, 80, 110))
    rect(buf, 40, 23, 24, 1, CHERRY)
    rect(buf, 42, 15, 1, 8, MIDNIGHT)
    put(buf, 42, 14, SUN if night or f % 20 < 18 else CREAM)

    # the line: sleepers and rail
    for x in range(W):
        put(buf, x, 27, (110, 100, 120))
        if x % 3 == 0:
            put(buf, x, 28, WOOD)
    for x in range(W):
        for y in range(29, H):
            put(buf, x, y, mix(MINT, MIDNIGHT, 0.6 if night else 0.25))

    # the train: cherry engine, then sun and sky carriages, front at train_x
    if train_x != None:
        fx = int(train_x)
        cars = [(SKY, 9), (SUN, 9)]
        x = fx - 11
        for col, cw in cars:
            x -= cw + 1
            rect(buf, x, 21, cw, 5, col)
            for wx in range(x + 1, x + cw - 1, 3):
                rect(buf, wx, 22, 2, 2, MIDNIGHT if at_platform and wx % 2 == 0 else (CREAM if not night else SUN))
            put(buf, x + 1, 26, MIDNIGHT)
            put(buf, x + cw - 2, 26, MIDNIGHT)

        # engine
        ex = fx - 10
        rect(buf, ex, 19, 4, 7, CHERRY)
        rect(buf, ex + 4, 22, 6, 4, CHERRY)
        rect(buf, ex + 6, 19, 2, 3, MIDNIGHT)
        rect(buf, ex + 1, 20, 2, 2, CREAM if not night else SUN)
        put(buf, ex + 10, 24, SUN)
        for wx in [ex + 1, ex + 4, ex + 7]:
            put(buf, wx + (f // 2) % 2 if moving else wx, 26, MIDNIGHT)

        # steam while it is moving
        if moving:
            for i in range(4):
                age = ((f + i * 10) % 40) / 40.0
                cx = ex + 7 - age * 10
                cy = 18 - age * 8
                r = 0.8 + age * 2.0
                for yy in range(int(cy - r), int(cy + r) + 1):
                    for xx in range(int(cx - r), int(cx + r) + 1):
                        if (xx - cx) * (xx - cx) + (yy - cy) * (yy - cy) < r * r and xx >= 0 and xx < W and yy >= 0:
                            buf[yy][xx] = mix(buf[yy][xx], CREAM, 0.8 * (1 - age))
    return buf

def fmt_clock(t, use_24h):
    return t.format("15:04") if use_24h else t.format("3:04")

def fmt_mins(m):
    if m < 60:
        return "%dM" % m
    if m < 1440:
        return "%dH %dM" % (m // 60, m % 60)
    return "%dD %dH" % (m // 1440, (m % 1440) // 60)

def main(config):
    tz = config.get("$tz", "America/New_York")
    now = time.now().in_location(tz)
    use_24h = config.bool("24h", False)
    url = config.get("ics", "").strip()
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]

    sample = url == ""
    if sample:
        # no calendar yet: show how it looks with a made-up meeting
        best = (now + time.parse_duration("18m"), 30, "Sample: design review")
    else:
        resp = http.get(url, ttl_seconds = 300)
        if resp.status_code != 200:
            return render.Root(child = render.Box(color = "#1d1530", child = render.WrappedText("CALENDAR LINK FAILED", font = "tom-thumb", color = "#ffd23f", align = "center")))
        best = next_meeting(resp.body(), now, tz, config.bool("skip_declined", True))

    if best == None:
        title = "NO MEETINGS THIS WEEK"
        big = "FREE"
        small = "ALL WEEK"
        train_x = None
        at_platform = False
        moving = False
    else:
        st, dur, summary = best
        st = st.in_location(tz)
        title = summary.upper()
        left = int((st - now).minutes)
        end_left = int((st + time.parse_duration("%dm" % dur) - now).minutes)
        if left <= 0:
            big = fmt_mins(max(1, end_left)) + " LEFT"
            small = "UNTIL " + fmt_clock(st + time.parse_duration("%dm" % dur), use_24h)
            train_x = 62
            at_platform = True
            moving = False
        else:
            big = "IN " + fmt_mins(left)
            if st.format("2006-01-02") == now.format("2006-01-02"):
                small = "AT " + fmt_clock(st, use_24h)
            else:
                small = st.format("Mon").upper() + " " + fmt_clock(st, use_24h)
            if left <= 60:
                train_x = 62 - (left / 60.0) * 80
                at_platform = False
                moving = True
            else:
                train_x = None
                at_platform = False
                moving = False

    frames = []
    for f in range(FRAMES):
        tx = train_x
        if moving and tx != None:
            tx = tx + f * 0.05
        frames.append(buf_to_widget([[rgb(c) for c in row] for row in frame(f, tx, at_platform, now.hour, moving)]))

    # one scrolling line on top (when, then what) and the countdown under it;
    # the rest of the screen belongs to the station and the train
    line = small + "  " + title
    if sample:
        line = "SAMPLE  " + line
    title_widget = render.Marquee(
        width = W,
        offset_start = 2,
        child = shadowed(line, "tom-thumb", "#ffd23f"),
    )
    return render.Root(
        delay = DELAY,
        show_full_animation = True,
        child = render.Stack(children = [
            render.Animation(children = frames),
            render.Padding(pad = (0, 1, 0, 0), child = title_widget),
            render.Padding(pad = (1, 7, 0, 0), child = shadowed(big, "tb-8", "#fff8ef")),
        ]),
    )

def shadowed(text, font, color):
    # a one-pixel drop shadow: readable over the sky without boxing the scene in
    return render.Stack(children = [
        render.Padding(pad = (1, 1, 0, 0), child = render.Text(content = text, font = font, color = "#1d1530")),
        render.Text(content = text, font = font, color = color),
    ])

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "ics", name = "Calendar link (ICS)", desc = "Your calendar's secret iCal address. Google: Settings, your calendar, 'Secret address in iCal format'. Outlook: Settings, Shared calendars, Publish, ICS.", icon = "calendar", default = ""),
            schema.Toggle(id = "skip_declined", name = "Skip declined", desc = "Ignore events whose title starts with 'Declined'.", icon = "xmark", default = True),
            schema.Toggle(id = "24h", name = "24-hour time", desc = "Show times in 24-hour format.", icon = "clock", default = False),
        ],
    )
