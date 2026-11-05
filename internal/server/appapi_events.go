package server

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Device events for the app's SSE stream (GET /devices/{id}/events):
//   dial   {action: turn|press|hold|release, delta, brightness, hold}
//   state  {brightness} | {now} | {status, online} | {online}
//   ota    {from, to, progress, done}

type appDeviceEvent struct {
	Name string
	Data map[string]any
}

func appEventTopic(deviceID string) string { return "events:" + deviceID }

// emitDeviceEvent publishes an event to anyone watching the device.
func (s *Server) emitDeviceEvent(deviceID, name string, payload map[string]any) {
	s.Broadcaster.Notify(appEventTopic(deviceID), appDeviceEvent{Name: name, Data: payload})
}

const appSSEPing = 15 * time.Second

func (s *Server) handleAppEvents(w http.ResponseWriter, r *http.Request) {
	device := GetDevice(r)
	rc := http.NewResponseController(w)
	// The server's WriteTimeout would cut the stream off.
	if err := rc.SetWriteDeadline(time.Time{}); err != nil {
		slog.Debug("SSE: could not clear write deadline", "error", err)
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	ch := s.Broadcaster.Subscribe(appEventTopic(device.ID))
	defer s.Broadcaster.Unsubscribe(appEventTopic(device.ID), ch)

	write := func(chunk string) bool {
		if _, err := fmt.Fprint(w, chunk); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	if !write(": hello\n\n") {
		return
	}

	ping := time.NewTicker(appSSEPing)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			if !write(": ping\n\n") {
				return
			}
		case msg, ok := <-ch:
			if !ok {
				return
			}
			ev, ok := msg.(appDeviceEvent)
			if !ok {
				continue
			}
			b, err := json.Marshal(ev.Data)
			if err != nil {
				continue
			}
			if !write("event: " + ev.Name + "\ndata: " + string(b) + "\n\n") {
				return
			}
		}
	}
}

// --- claim codes & rate limiting ---

// Same alphabet as the setup code: no 0/O or 1/I, safe to read aloud and to
// put in an upper-case QR code.
func newClaimCode() (string, error) {
	var b strings.Builder
	for range 6 {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(setupCodeAlphabet))))
		if err != nil {
			return "", err
		}
		b.WriteByte(setupCodeAlphabet[n.Int64()])
	}
	return b.String(), nil
}

// ipLimiter allows a burst of requests per IP per window.
type ipLimiter struct {
	mu     sync.Mutex
	window time.Duration
	max    int
	hits   map[string][]time.Time
}

var deviceRegisterLimiter = &ipLimiter{window: time.Minute, max: 20, hits: map[string][]time.Time{}}

func (l *ipLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	cutoff := now.Add(-l.window)
	kept := l.hits[ip][:0]
	for _, t := range l.hits[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= l.max {
		l.hits[ip] = kept
		return false
	}
	l.hits[ip] = append(kept, now)
	if len(l.hits) > 10000 { // don't grow without bound
		l.hits = map[string][]time.Time{ip: l.hits[ip]}
	}
	return true
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
