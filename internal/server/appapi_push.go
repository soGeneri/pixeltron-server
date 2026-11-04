package server

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"tronbyt-server/internal/data"
	"tronbyt-server/internal/push"

	"gorm.io/gorm"
)

// Notification kinds, matching the app's choices (NotificationPrefs).
// household and milestones are stored but nothing sends them yet.
var appNotifyDefaults = map[string]bool{
	"offline":    true,
	"updates":    true,
	"household":  true,
	"milestones": false,
}

const (
	offlineNotifyAfter    = 30 * time.Minute
	offlineCheckInterval  = time.Minute
	offlineNotifiedSetKey = "offline_notified"
)

// initPush builds the senders that are configured and, if any are, starts
// watching for devices that go quiet.
func (s *Server) initPush() {
	s.pushSenders = map[string]push.Sender{}
	cfg := s.Config
	if cfg == nil {
		return
	}
	if cfg.APNsKeyFile != "" {
		sndr, err := push.LoadAPNs(cfg.APNsKeyFile, push.APNsConfig{
			KeyID: cfg.APNsKeyID, TeamID: cfg.APNsTeamID, Topic: cfg.APNsTopic, Sandbox: cfg.APNsSandbox,
		})
		if err != nil {
			slog.Error("APNs push disabled", "error", err)
		} else {
			s.pushSenders["ios"] = sndr
			slog.Info("APNs push enabled", "topic", cfg.APNsTopic, "sandbox", cfg.APNsSandbox)
		}
	}
	if cfg.FCMServiceAccountFile != "" {
		sndr, err := push.LoadFCM(cfg.FCMServiceAccountFile)
		if err != nil {
			slog.Error("FCM push disabled", "error", err)
		} else {
			s.pushSenders["android"] = sndr
			slog.Info("FCM push enabled")
		}
	}
	if len(s.pushSenders) > 0 {
		go s.watchOfflineDevices(context.Background())
	}
}

func normalizePushPlatform(p string) string {
	switch strings.ToLower(strings.TrimSpace(p)) {
	case "ios", "apns", "iphone", "ipad":
		return "ios"
	case "android", "fcm":
		return "android"
	}
	return strings.ToLower(strings.TrimSpace(p))
}

func appNotifyPrefs(u *data.User) map[string]bool {
	out := map[string]bool{}
	for k, v := range appNotifyDefaults {
		out[k] = v
		if b, ok := u.AppNotify[k].(bool); ok {
			out[k] = b
		}
	}
	return out
}

func (s *Server) handleAppGetNotify(w http.ResponseWriter, r *http.Request) {
	writeAppJSON(w, http.StatusOK, appNotifyPrefs(GetUser(r)))
}

// handleAppPutNotify merges {kind: bool} into the user's choices.
func (s *Server) handleAppPutNotify(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	var body map[string]bool
	if err := decodeAppJSON(r, &body); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	prefs := data.JSONMap{}
	for k, v := range user.AppNotify {
		prefs[k] = v
	}
	for k, v := range body {
		if _, known := appNotifyDefaults[k]; !known {
			writeAppError(w, http.StatusBadRequest, "Unknown notification: "+k, "bad_request")
			return
		}
		prefs[k] = v
	}
	if err := s.DB.Model(&data.User{Username: user.Username}).Update("app_notify", prefs).Error; err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	user.AppNotify = prefs
	writeAppJSON(w, http.StatusOK, appNotifyPrefs(user))
}

// notifyUser sends one notification of a kind to every phone of the user
// who wants that kind. Dead tokens are forgotten. Returns how many sends
// succeeded.
func (s *Server) notifyUser(ctx context.Context, username, kind string, m push.Message) int {
	if len(s.pushSenders) == 0 {
		return 0
	}
	user, err := gorm.G[data.User](s.DB).Where("username = ?", username).First(ctx)
	if err != nil || !appNotifyPrefs(&user)[kind] {
		return 0
	}
	tokens, err := gorm.G[data.PushToken](s.DB).Where("username = ?", username).Find(ctx)
	if err != nil {
		slog.Error("Failed to load push tokens", "user", username, "error", err)
		return 0
	}
	if m.Data == nil {
		m.Data = map[string]string{}
	}
	m.Data["kind"] = kind
	sent := 0
	for _, t := range tokens {
		sndr := s.pushSenders[normalizePushPlatform(t.Platform)]
		if sndr == nil {
			continue
		}
		err := sndr.Send(ctx, t.Token, m)
		switch {
		case err == nil:
			sent++
		case errors.Is(err, push.ErrUnregistered):
			slog.Info("Forgetting dead push token", "user", username, "platform", t.Platform)
			if _, derr := gorm.G[data.PushToken](s.DB).Where("id = ?", t.ID).Delete(ctx); derr != nil {
				slog.Error("Failed to delete push token", "error", derr)
			}
		default:
			slog.Warn("Push failed", "user", username, "platform", t.Platform, "error", err)
		}
	}
	return sent
}

// notifyUserAsync sends without holding up the caller (e.g. a websocket loop).
func (s *Server) notifyUserAsync(username, kind string, m push.Message) {
	if len(s.pushSenders) == 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		s.notifyUser(ctx, username, kind, m)
	}()
}

func deviceDisplayName(d *data.Device) string {
	if strings.TrimSpace(d.Name) != "" {
		return d.Name
	}
	return "Your Pixeltron"
}

func (s *Server) watchOfflineDevices(ctx context.Context) {
	t := time.NewTicker(offlineCheckInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			s.checkOfflineDevices(ctx, now)
		}
	}
}

// checkOfflineDevices notifies owners once per outage about app devices
// that haven't been heard from for offlineNotifyAfter.
func (s *Server) checkOfflineDevices(ctx context.Context, now time.Time) {
	devices, err := gorm.G[data.Device](s.DB).
		Where("product <> '' AND last_seen IS NOT NULL AND last_seen < ?", now.Add(-offlineNotifyAfter)).
		Find(ctx)
	if err != nil {
		slog.Error("Offline check failed", "error", err)
		return
	}
	for i := range devices {
		d := &devices[i]
		if done, _ := d.AppSettings[offlineNotifiedSetKey].(bool); done {
			continue
		}
		settings := data.JSONMap{}
		for k, v := range d.AppSettings {
			settings[k] = v
		}
		settings[offlineNotifiedSetKey] = true
		if err := s.DB.Model(&data.Device{ID: d.ID}).Update("app_settings", settings).Error; err != nil {
			slog.Error("Failed to mark device offline-notified", "device", d.ID, "error", err)
			continue
		}
		name := deviceDisplayName(d)
		s.notifyUser(ctx, d.Username, "offline", push.Message{
			Title: name + " went quiet",
			Body:  "It's been offline for 30 minutes. Check it's plugged in and the Wi-Fi is up.",
			Data:  map[string]string{"device": d.ID},
		})
	}
}

// deviceBackOnline clears the once-per-outage flag when a device reconnects.
func (s *Server) deviceBackOnline(ctx context.Context, d *data.Device) {
	if done, _ := d.AppSettings[offlineNotifiedSetKey].(bool); !done {
		return
	}
	settings := data.JSONMap{}
	for k, v := range d.AppSettings {
		if k != offlineNotifiedSetKey {
			settings[k] = v
		}
	}
	d.AppSettings = settings
	if err := s.DB.Model(&data.Device{ID: d.ID}).Update("app_settings", settings).Error; err != nil {
		slog.Error("Failed to clear offline flag", "device", d.ID, "error", err)
	}
}
