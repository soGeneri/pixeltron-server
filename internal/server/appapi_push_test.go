package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"tronbyt-server/internal/data"
	"tronbyt-server/internal/push"

	"github.com/gorilla/websocket"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

type fakeSender struct {
	mu   sync.Mutex
	sent []struct {
		token string
		msg   push.Message
	}
	dead map[string]bool
}

func (f *fakeSender) Send(_ context.Context, token string, m push.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.dead[token] {
		return push.ErrUnregistered
	}
	f.sent = append(f.sent, struct {
		token string
		msg   push.Message
	}{token, m})
	return nil
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}

func (f *fakeSender) last() push.Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.sent[len(f.sent)-1].msg
}

func TestAppAPIPushNotifications(t *testing.T) {
	s := newAppTestServer(t)
	ios := &fakeSender{dead: map[string]bool{"dead-token": true}}
	s.pushSenders = map[string]push.Sender{"ios": ios}

	c := &appClient{t: t, s: s}
	c.signUp("a@b.co")
	reg := registerDevice(t, s, "24:0a:c4:12:34:56")
	require.Equal(t, http.StatusCreated, c.do("POST", "/app/v0/claims", map[string]any{"claim_code": reg["claim_code"], "name": "Kitchen"}).Code)

	// Preferences: app defaults, then a change.
	rr := c.do("GET", "/app/v0/me/notifications", nil)
	prefs := decodeMap(t, rr)
	assert.Equal(t, true, prefs["offline"])
	assert.Equal(t, false, prefs["milestones"])
	assert.Equal(t, http.StatusBadRequest, c.do("PUT", "/app/v0/me/notifications", map[string]any{"spam": true}).Code)

	// "iOS" is stored as ios; the dead token goes away on first use.
	require.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/me/push-tokens", map[string]any{"token": "good-token", "platform": "iOS"}).Code)
	require.Equal(t, http.StatusNoContent, c.do("POST", "/app/v0/me/push-tokens", map[string]any{"token": "dead-token", "platform": "ios"}).Code)

	ctx := context.Background()
	later := time.Now().Add(offlineNotifyAfter + time.Minute)

	// Offline: one notification per outage.
	s.checkOfflineDevices(ctx, later)
	require.Equal(t, 1, ios.count())
	msg := ios.last()
	assert.Equal(t, "Kitchen went quiet", msg.Title)
	assert.Equal(t, "offline", msg.Data["kind"])
	assert.Equal(t, "pxt-gnu62", msg.Data["device"])
	n, err := gorm.G[data.PushToken](s.DB).Where("token = ?", "dead-token").Count(ctx, "*")
	require.NoError(t, err)
	assert.Zero(t, n, "dead token forgotten")

	s.checkOfflineDevices(ctx, later)
	assert.Equal(t, 1, ios.count(), "no repeat for the same outage")

	// Back online, then quiet again: notified again.
	d, err := s.reloadAppDevice(ctx, "pxt-gnu62")
	require.NoError(t, err)
	s.deviceBackOnline(ctx, d)
	s.checkOfflineDevices(ctx, later)
	assert.Equal(t, 2, ios.count())

	// Turned off: nothing.
	require.Equal(t, http.StatusOK, c.do("PUT", "/app/v0/me/notifications", map[string]any{"offline": false}).Code)
	s.deviceBackOnline(ctx, d)
	s.checkOfflineDevices(ctx, later)
	assert.Equal(t, 2, ios.count())

	// A device that reconnects on a new firmware version sends "updates".
	ts := httptest.NewServer(s)
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/pxt-gnu62/ws"
	dial := func(version string) {
		conn, resp, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"Authorization": {"Bearer " + reg["api_key"].(string)}})
		require.NoError(t, err)
		_ = resp.Body.Close()
		require.NoError(t, conn.WriteJSON(map[string]any{"client_info": map[string]any{"firmware_version": version}}))
		time.Sleep(200 * time.Millisecond)
		_ = conn.Close()
	}
	dial("1.7.3-pxt.2")
	dial("1.8.0")
	require.Eventually(t, func() bool { return ios.count() == 3 }, 3*time.Second, 20*time.Millisecond)
	assert.Equal(t, "Kitchen learned something new", ios.last().Title)
	assert.Contains(t, ios.last().Body, "1.8.0")
}
