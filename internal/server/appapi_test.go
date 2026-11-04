package server

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tronbyt-server/internal/config"

	"github.com/gorilla/websocket"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Two tiny Pixlet apps in the featured dir: "clock" (installed on claim)
// and "aquarium" (three schema fields, like the mock's next-train).
const testClockStar = `load("render.star", "render")

def main(config):
    return render.Root(child = render.Text("12:00"))
`

const testAquariumStar = `load("render.star", "render")
load("schema.star", "schema")

def main(config):
    return render.Root(child = render.Box(color = config.get("color", "#0000ff")))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "msg", name = "Message", desc = "Shown on top", icon = "font"),
            schema.Toggle(id = "bubbles", name = "Bubbles", desc = "Show bubbles", icon = "water", default = True),
            schema.Color(id = "color", name = "Water", desc = "Water colour", icon = "brush", default = "#0000ff"),
        ],
    )
`

func writeTestApp(t *testing.T, dataDir, id, name, category, star string) {
	t.Helper()
	dir := filepath.Join(dataDir, "featured-apps", id)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	manifest := "id: " + id + "\nname: " + name + "\nsummary: " + name + " app\ncategory: " + category + "\nfileName: " + id + ".star\npackageName: " + id + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, id+".star"), []byte(star), 0o644))
}

func newAppTestServer(t *testing.T, opts ...option) *Server {
	t.Helper()
	appRenderSync = true
	t.Cleanup(func() { appRenderSync = false })
	all := append([]option{func(c *config.Settings) {
		c.FeaturedAppsDir = "featured-apps"
		c.PixelsDevHooks = true
		c.EnableUserRegistration = true
	}}, opts...)
	s := newTestServer(t, all...)
	// One connection: with cache=private every new connection is a new, empty
	// in-memory database, and background work (pushes, renders) would see it.
	sqlDB, err := s.DB.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	writeTestApp(t, s.DataDir, "clock", "Clock", "time", testClockStar)
	writeTestApp(t, s.DataDir, "aquarium", "Aquarium", "art", testAquariumStar)
	return s
}

type appClient struct {
	t     *testing.T
	s     *Server
	token string
}

func (c *appClient) do(method, path string, body any) *httptest.ResponseRecorder {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		require.NoError(c.t, json.NewEncoder(&buf).Encode(body))
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	rr := httptest.NewRecorder()
	c.s.ServeHTTP(rr, req)
	return rr
}

func decodeMap(t *testing.T, rr *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal(rr.Body.Bytes(), &m), rr.Body.String())
	return m
}

func (c *appClient) signUp(email string) map[string]any {
	c.t.Helper()
	rr := c.do("POST", "/app/v0/auth/email", map[string]any{"email": email, "password": "correct horse"})
	require.Equal(c.t, http.StatusOK, rr.Code, rr.Body.String())
	m := decodeMap(c.t, rr)
	c.token = m["token"].(string)
	return m
}

// registerDevice plays the device: check in and get a claim code.
func registerDevice(t *testing.T, s *Server, mac string) map[string]any {
	t.Helper()
	dev := &appClient{t: t, s: s}
	rr := dev.do("POST", "/app/v0/device/register", map[string]any{"mac": mac, "product": "pixeltron", "firmware": "1.7.3-pxt.2"})
	require.Equal(t, http.StatusOK, rr.Code, rr.Body.String())
	return decodeMap(t, rr)
}

func installationIDs(d map[string]any) []string {
	var ids []string
	for _, i := range d["installations"].([]any) {
		ids = append(ids, i.(map[string]any)["id"].(string))
	}
	return ids
}

func testPNG(t *testing.T) string {
	img := image.NewRGBA(image.Rect(0, 0, 64, 32))
	for x := range 64 {
		img.Set(x, 10, color.RGBA{R: 255, A: 255})
	}
	var buf bytes.Buffer
	require.NoError(t, png.Encode(&buf, img))
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

// TestAppAPIContractFlow follows the Pixels contract test
// (tools/mock_server/test/client_test.dart) against the real server.
func TestAppAPIContractFlow(t *testing.T) {
	s := newAppTestServer(t)
	c := &appClient{t: t, s: s}

	// Sign-up validation, then sign up and sign in again.
	rr := c.do("POST", "/app/v0/auth/email", map[string]any{"email": "nope", "password": "correct horse"})
	assert.Equal(t, http.StatusBadRequest, rr.Code)
	assert.Equal(t, "bad_email", decodeMap(t, rr)["code"])
	rr = c.do("POST", "/app/v0/auth/email", map[string]any{"email": "a@b.co", "password": "short"})
	assert.Equal(t, "weak_password", decodeMap(t, rr)["code"])

	signed := c.signUp("a@b.co")
	assert.EqualValues(t, 3600, signed["expires_in"])
	assert.Len(t, signed["token"], 32)
	assert.Len(t, signed["refresh_token"], 40)
	user := signed["user"].(map[string]any)
	assert.Equal(t, "a@b.co", user["email"])
	assert.Equal(t, "email", user["method"])

	rr = c.do("POST", "/app/v0/auth/email", map[string]any{"email": "A@B.co", "password": "wrong password"})
	assert.Equal(t, http.StatusUnauthorized, rr.Code)
	assert.Equal(t, "wrong_password", decodeMap(t, rr)["code"])

	rr = c.do("GET", "/app/v0/me", nil)
	require.Equal(t, http.StatusOK, rr.Code)
	assert.Equal(t, user["id"], decodeMap(t, rr)["id"])

	// Products: api_base points back at this server's app API.
	rr = c.do("GET", "/app/v0/products", nil)
	require.Equal(t, http.StatusOK, rr.Code)
	products := decodeMap(t, rr)["products"].([]any)
	px := products[0].(map[string]any)
	assert.Equal(t, "pixeltron", px["id"])
	assert.True(t, strings.HasSuffix(px["api_base"].(string), "/app/v0"), px["api_base"])

	// Device checks in, app claims it; the code is single use.
	reg := registerDevice(t, s, "24:0a:c4:12:34:56")
	assert.Equal(t, "pxt-gnu62", reg["device_id"])
	assert.Equal(t, "GNU-62", reg["code_word"])
	code := reg["claim_code"].(string)
	rr = c.do("POST", "/app/v0/claims", map[string]any{"claim_code": strings.ToLower(code), "name": "Pixeltron", "timezone": "Europe/London"})
	require.Equal(t, http.StatusCreated, rr.Code, rr.Body.String())
	d := decodeMap(t, rr)
	assert.Equal(t, "pxt-gnu62", d["id"])
	assert.Equal(t, "pixeltron", d["product"])
	assert.Equal(t, "Pixeltron-GNU62", d["hotspot"])
	assert.Equal(t, "Europe/London", d["timezone"])
	assert.Equal(t, "1.7.3-pxt.2", d["firmware"])
	require.Len(t, d["installations"], 1, "default clock installed")
	assert.Equal(t, "clock", d["installations"].([]any)[0].(map[string]any)["app_id"])

	rr = c.do("POST", "/app/v0/claims", map[string]any{"claim_code": code})
	assert.Equal(t, http.StatusGone, rr.Code)
	assert.Equal(t, "invalid_claim", decodeMap(t, rr)["code"])

	// The device can tell it has been claimed.
	dev := &appClient{t: t, s: s, token: reg["api_key"].(string)}
	rr = dev.do("GET", "/app/v0/device/claim", nil)
	assert.Equal(t, true, decodeMap(t, rr)["claimed"])

	// Patch: names, and settings merge one level deep.
	rr = c.do("PATCH", "/app/v0/devices/pxt-gnu62", map[string]any{"displayName": "Kitchen", "room": "Kitchen", "settings": map[string]any{"dim_sunset": true}})
	require.Equal(t, http.StatusOK, rr.Code, rr.Body.String())
	rr = c.do("PATCH", "/app/v0/devices/pxt-gnu62", map[string]any{"settings": map[string]any{"sound": true, "night_mode": map[string]any{"enabled": true, "from": "23:00", "to": "06:30", "level": 5}}})
	d = decodeMap(t, rr)
	settings := d["settings"].(map[string]any)
	assert.Equal(t, true, settings["dim_sunset"])
	assert.Equal(t, true, settings["sound"])
	nm := settings["night_mode"].(map[string]any)
	assert.Equal(t, "23:00", nm["from"])
	assert.EqualValues(t, 5, nm["level"])
	assert.Equal(t, "Kitchen", d["displayName"])
	assert.Equal(t, "Kitchen", d["room"])

	// Installations: add twice, reorder, change duration, remove.
	rr = c.do("POST", "/app/v0/devices/pxt-gnu62/installations", map[string]any{"app_id": "aquarium", "config": map[string]any{"color": "#00ff00"}})
	require.Equal(t, http.StatusCreated, rr.Code, rr.Body.String())
	rr = c.do("POST", "/app/v0/devices/pxt-gnu62/installations", map[string]any{"app_id": "aquarium"})
	require.Equal(t, http.StatusCreated, rr.Code)
	ids := installationIDs(decodeMap(t, rr))
	require.Len(t, ids, 3)
	rr = c.do("POST", "/app/v0/devices/pxt-gnu62/installations", map[string]any{"app_id": "nope"})
	assert.Equal(t, "unknown_app", decodeMap(t, rr)["code"])

	reversed := []string{ids[2], ids[1], ids[0]}
	rr = c.do("PUT", "/app/v0/devices/pxt-gnu62/installations/order", map[string]any{"order": reversed})
	require.Equal(t, http.StatusOK, rr.Code)
	assert.Equal(t, reversed, installationIDs(decodeMap(t, rr)))

	rr = c.do("PATCH", "/app/v0/devices/pxt-gnu62/installations/"+ids[0], map[string]any{"duration_sec": 30, "name": "Big clock"})
	require.Equal(t, http.StatusOK, rr.Code)
	for _, i := range decodeMap(t, rr)["installations"].([]any) {
		if inst := i.(map[string]any); inst["id"] == ids[0] {
			assert.EqualValues(t, 30, inst["duration_sec"])
			assert.Equal(t, "Big clock", inst["name"])
		}
	}

	rr = c.do("PATCH", "/app/v0/devices/pxt-gnu62", map[string]any{"pinnedApp": ids[2]})
	require.Equal(t, http.StatusOK, rr.Code)
	rr = c.do("DELETE", "/app/v0/devices/pxt-gnu62/installations/"+ids[2], nil)
	require.Equal(t, http.StatusOK, rr.Code)
	d = decodeMap(t, rr)
	assert.Len(t, d["installations"], 2)
	assert.Nil(t, d["pinnedApp"], "deleting the pinned app unpins it")

	// Frame and previews are PNGs at the panel size.
	for _, path := range []string{"/app/v0/devices/pxt-gnu62/frame", "/app/v0/apps/aquarium/preview"} {
		rr = c.do("GET", path, nil)
		require.Equal(t, http.StatusOK, rr.Code, path+": "+rr.Body.String())
		assert.Equal(t, "image/png", rr.Header().Get("Content-Type"))
		img, err := png.Decode(rr.Body)
		require.NoError(t, err)
		assert.Equal(t, image.Rect(0, 0, 64, 32), img.Bounds(), path)
	}

	// Catalog.
	rr = c.do("GET", "/app/v0/apps?category=Popular", nil)
	assert.Len(t, decodeMap(t, rr)["apps"], 2)
	rr = c.do("GET", "/app/v0/apps?q=aqua", nil)
	apps := decodeMap(t, rr)["apps"].([]any)
	require.Len(t, apps, 1)
	aq := apps[0].(map[string]any)
	assert.Equal(t, "Art", aq["category"])
	assert.True(t, strings.HasSuffix(aq["preview"].(string), "/app/v0/apps/aquarium/preview"), aq["preview"])
	assert.True(t, strings.HasPrefix(aq["preview"].(string), "http"), "absolute, so the app fetches it as is")
	assert.Len(t, aq["schema"], 3)
	rr = c.do("GET", "/app/v0/apps/aquarium", nil)
	require.Equal(t, http.StatusOK, rr.Code)
	assert.Len(t, decodeMap(t, rr)["schema"], 3)

	// Push an image and show an installation now.
	rr = c.do("POST", "/app/v0/devices/pxt-gnu62/push", map[string]any{"image": testPNG(t), "format": "png", "chime": false})
	assert.Equal(t, http.StatusNoContent, rr.Code, rr.Body.String())
	rr = c.do("POST", "/app/v0/devices/pxt-gnu62/push_app", map[string]any{"installation": ids[1]})
	assert.Equal(t, http.StatusNoContent, rr.Code, rr.Body.String())
	rr = c.do("GET", "/app/v0/devices/pxt-gnu62", nil)
	assert.Equal(t, ids[1], decodeMap(t, rr)["nowShowing"])

	// Push tokens and reboot.
	assert.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/me/push-tokens", map[string]any{"token": "abc", "platform": "ios"}).Code)
	assert.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/devices/pxt-gnu62/reboot", nil).Code)

	// Release: the device is gone and its key no longer works.
	assert.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/devices/pxt-gnu62/release", nil).Code)
	rr = c.do("GET", "/app/v0/devices", nil)
	assert.Empty(t, decodeMap(t, rr)["devices"])
	rr = dev.do("GET", "/app/v0/device/claim", nil)
	assert.Equal(t, http.StatusUnauthorized, rr.Code)
	assert.Equal(t, "not_linked", decodeMap(t, rr)["code"])

	// It can set up again and be claimed by someone else.
	reg = registerDevice(t, s, "24:0a:c4:12:34:56")
	other := &appClient{t: t, s: s}
	other.signUp("b@b.co")
	rr = other.do("POST", "/app/v0/claims", map[string]any{"claim_code": reg["claim_code"]})
	assert.Equal(t, http.StatusCreated, rr.Code)
}

func TestAppAPIAuthErrorsAndOwnership(t *testing.T) {
	s := newAppTestServer(t)
	anon := &appClient{t: t, s: s}

	rr := anon.do("GET", "/app/v0/devices", nil)
	assert.Equal(t, http.StatusUnauthorized, rr.Code)
	assert.Equal(t, "unauthorized", decodeMap(t, rr)["code"])

	rr = anon.do("POST", "/app/v0/auth/apple", map[string]any{})
	assert.Equal(t, "no_token", decodeMap(t, rr)["code"])
	rr = anon.do("POST", "/app/v0/auth/google", map[string]any{"id_token": "x"})
	assert.Equal(t, http.StatusNotImplemented, rr.Code)
	assert.Equal(t, "method_disabled", decodeMap(t, rr)["code"])
	assert.Equal(t, http.StatusNotFound, anon.do("POST", "/app/v0/auth/myspace", map[string]any{}).Code)

	// Someone else's device is "not found", not "forbidden".
	alice := &appClient{t: t, s: s}
	alice.signUp("alice@example.com")
	reg := registerDevice(t, s, "01:02:03:04:05:06")
	require.Equal(t, http.StatusCreated, alice.do("POST", "/app/v0/claims", map[string]any{"claim_code": reg["claim_code"]}).Code)
	bob := &appClient{t: t, s: s}
	bob.signUp("bob@example.com")
	rr = bob.do("GET", "/app/v0/devices/"+reg["device_id"].(string), nil)
	assert.Equal(t, http.StatusNotFound, rr.Code)
	assert.Equal(t, "not found", decodeMap(t, rr)["error"])

	// A claimed device can't register again to steal a fresh code.
	dev := &appClient{t: t, s: s}
	rr = dev.do("POST", "/app/v0/device/register", map[string]any{"mac": "01:02:03:04:05:06"})
	assert.Equal(t, http.StatusConflict, rr.Code)

	// Self-hosted mode: a user API key works as a bearer token.
	var key string
	require.NoError(t, s.DB.Raw("SELECT api_key FROM users WHERE LOWER(email) = ?", "alice@example.com").Scan(&key).Error)
	selfHosted := &appClient{t: t, s: s, token: key}
	rr = selfHosted.do("GET", "/app/v0/devices", nil)
	require.Equal(t, http.StatusOK, rr.Code)
	assert.Len(t, decodeMap(t, rr)["devices"], 1)
}

func TestAppAPIRefreshAndLogout(t *testing.T) {
	s := newAppTestServer(t)
	c := &appClient{t: t, s: s}
	signed := c.signUp("a@b.co")
	refresh := signed["refresh_token"].(string)

	rr := c.do("POST", "/app/v0/auth/refresh", map[string]any{"refresh_token": refresh})
	require.Equal(t, http.StatusOK, rr.Code)
	next := decodeMap(t, rr)
	assert.NotEqual(t, signed["token"], next["token"])

	// Refresh tokens are single use.
	rr = c.do("POST", "/app/v0/auth/refresh", map[string]any{"refresh_token": refresh})
	assert.Equal(t, http.StatusUnauthorized, rr.Code)
	assert.Equal(t, "refresh_invalid", decodeMap(t, rr)["code"])

	c.token = next["token"].(string)
	assert.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/auth/logout", nil).Code)
	assert.Equal(t, http.StatusUnauthorized, c.do("GET", "/app/v0/me", nil).Code)
	rr = c.do("POST", "/app/v0/auth/refresh", map[string]any{"refresh_token": next["refresh_token"]})
	assert.Equal(t, http.StatusUnauthorized, rr.Code)
}

func TestAppAPIRegistrationClosed(t *testing.T) {
	s := newAppTestServer(t, func(c *config.Settings) { c.EnableUserRegistration = false })
	first := &appClient{t: t, s: s}
	first.signUp("owner@example.com") // the first account is always allowed
	second := &appClient{t: t, s: s}
	rr := second.do("POST", "/app/v0/auth/email", map[string]any{"email": "other@example.com", "password": "correct horse"})
	assert.Equal(t, http.StatusForbidden, rr.Code)
	assert.Equal(t, "registration_closed", decodeMap(t, rr)["code"])
}

// TestAppAPIEvents reads the SSE stream through a real HTTP server, with
// the gzip and metrics middleware in the way.
func TestAppAPIEvents(t *testing.T) {
	s := newAppTestServer(t)
	c := &appClient{t: t, s: s}
	c.signUp("a@b.co")
	reg := registerDevice(t, s, "24:0a:c4:12:34:56")
	require.Equal(t, http.StatusCreated, c.do("POST", "/app/v0/claims", map[string]any{"claim_code": reg["claim_code"]}).Code)

	ts := httptest.NewServer(s)
	defer ts.Close()
	req, err := http.NewRequest("GET", ts.URL+"/app/v0/devices/pxt-gnu62/events", nil)
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer func() { _ = resp.Body.Close() }()
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))
	assert.Empty(t, resp.Header.Get("Content-Encoding"), "event streams must not be gzipped")

	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	expect := func(want string) {
		t.Helper()
		deadline := time.After(5 * time.Second)
		for {
			select {
			case l, ok := <-lines:
				require.True(t, ok, "stream closed waiting for %q", want)
				if strings.Contains(l, want) {
					return
				}
			case <-deadline:
				t.Fatalf("no %q on the event stream", want)
			}
		}
	}
	expect(": hello")

	// Brightness from the app arrives as a state event.
	c.do("PATCH", "/app/v0/devices/pxt-gnu62", map[string]any{"brightness": 40})
	expect("event: state")
	expect(`"brightness":40`)

	// A dial turn (dev hook) arrives as a dial event, +10 per detent.
	c.do("POST", "/app/_mock/devices/pxt-gnu62/dial", map[string]any{"action": "turn", "delta": 1})
	expect("event: dial")
	expect(`"brightness":50`)
}

func TestAppAPIDevHooksOffByDefault(t *testing.T) {
	appRenderSync = true
	t.Cleanup(func() { appRenderSync = false })
	s := newTestServer(t)
	c := &appClient{t: t, s: s}
	rr := c.do("POST", "/app/_mock/seed", map[string]any{"email": "a@b.co"})
	assert.NotEqual(t, http.StatusOK, rr.Code)
}

func TestAppCategoryAliases(t *testing.T) {
	assert.True(t, categoryMatches("Time", "Clocks"))
	assert.True(t, categoryMatches("Money", "Finance"))
	assert.True(t, categoryMatches("weather", "Weather"))
	assert.False(t, categoryMatches("Time", "Weather"))
}

// TestAppAPIDeviceWebsocketEvents connects as the device over the real
// websocket and checks each knob and update message reaches the app's
// event stream.
func TestAppAPIDeviceWebsocketEvents(t *testing.T) {
	s := newAppTestServer(t)
	c := &appClient{t: t, s: s}
	c.signUp("a@b.co")
	reg := registerDevice(t, s, "24:0a:c4:12:34:56")
	require.Equal(t, http.StatusCreated, c.do("POST", "/app/v0/claims", map[string]any{"claim_code": reg["claim_code"]}).Code)

	ts := httptest.NewServer(s)
	defer ts.Close()

	// App: event stream.
	req, err := http.NewRequest("GET", ts.URL+"/app/v0/devices/pxt-gnu62/events", nil)
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer func() { _ = resp.Body.Close() }()
	lines := make(chan string, 256)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	expect := func(want string) {
		t.Helper()
		deadline := time.After(5 * time.Second)
		for {
			select {
			case l, ok := <-lines:
				require.True(t, ok, "stream closed waiting for %q", want)
				if strings.Contains(l, want) {
					return
				}
			case <-deadline:
				t.Fatalf("no %q on the event stream", want)
			}
		}
	}
	expect(": hello")

	// Device: websocket with its key.
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/pxt-gnu62/ws"
	hdr := http.Header{"Authorization": {"Bearer " + reg["api_key"].(string)}}
	conn, wsResp, err := websocket.DefaultDialer.Dial(wsURL, hdr)
	require.NoError(t, err)
	_ = wsResp.Body.Close()
	defer func() { _ = conn.Close() }()
	expect(`"online":true`)

	send := func(m map[string]any) {
		t.Helper()
		require.NoError(t, conn.WriteJSON(m))
	}
	send(map[string]any{"client_info": map[string]any{"firmware_version": "1.7.3-pxt.2", "mac": "24:0a:c4:12:34:56"}})

	send(map[string]any{"brightness": 35})
	expect("event: dial")
	expect(`"brightness":35`)

	send(map[string]any{"button": "next"})
	expect(`"action":"press"`)

	// The reset countdown, then letting go.
	send(map[string]any{"hold": 3})
	expect(`"action":"hold"`)
	send(map[string]any{"hold": 4})
	expect(`"hold":4`)
	send(map[string]any{"hold": 0})
	expect(`"action":"release"`)

	send(map[string]any{"ota": map[string]any{"progress": 0.5}})
	expect("event: ota")
	expect(`"progress":0.5`)

	// Reconnecting on a new version reports the update as done.
	send(map[string]any{"client_info": map[string]any{"firmware_version": "1.8.0", "mac": "24:0a:c4:12:34:56"}})
	expect(`"to":"1.8.0"`)

	_ = conn.Close()
	expect(`"online":false`)
}
