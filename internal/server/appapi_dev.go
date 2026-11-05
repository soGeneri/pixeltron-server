package server

import (
	"log/slog"
	"net/http"
	"strings"
	"time"

	"tronbyt-server/internal/data"

	"gorm.io/gorm"
)

// Test hooks matching the Pixels mock's /_mock/* routes, so the app's
// Developer menu and the Dart contract tests run against this server.
// Only registered when PIXELS_DEV_HOOKS=true.
func (s *Server) setupAppDevHooks() {
	r := s.Router
	r.HandleFunc("POST /app/_mock/seed", s.handleDevSeed)
	r.HandleFunc("POST /app/_mock/devices/{id}/dial", s.handleDevDial)
	r.HandleFunc("POST /app/_mock/devices/{id}/status", s.handleDevStatus)
	r.HandleFunc("POST /app/_mock/devices/{id}/ota", s.handleDevOTA)
}

func (s *Server) devDevice(w http.ResponseWriter, r *http.Request) *data.Device {
	d, err := s.reloadAppDevice(r.Context(), r.PathValue("id"))
	if err != nil {
		http.Error(w, "no device", http.StatusNotFound)
		return nil
	}
	return d
}

// handleDevSeed gives the email's account two devices: Kitchen (healthy) and
// Desk (E3, last seen two hours ago).
func (s *Server) handleDevSeed(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	_ = decodeAppJSON(r, &req)
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if email == "" {
		email = "a@b.c"
	}
	ctx := r.Context()
	user, err := gorm.G[data.User](s.DB).Where("LOWER(email) = ?", email).First(ctx)
	if err != nil {
		writeAppError(w, http.StatusNotFound, "Sign in with that email first.", "unknown_user")
		return
	}

	now := time.Now()
	twoHoursAgo := now.Add(-2 * time.Hour)
	tz := "America/New_York"
	seeds := []data.Device{
		{ID: "pxt-cat11", Name: "Kitchen", Room: "Kitchen", LastSeen: &now},
		{ID: "pxt-owl07", Name: "Desk", Room: "Office", LastSeen: &twoHoursAgo, AppSettings: data.JSONMap{"status": "E3"}},
	}
	for _, d := range seeds {
		if _, err := gorm.G[data.Device](s.DB).Where("id = ?", d.ID).First(ctx); err == nil {
			continue
		}
		key, _ := generateSecureToken(32)
		d.Username = user.Username
		d.Type = data.DeviceTronbytS3
		d.Product = "pixeltron"
		d.APIKey = key
		d.RequireAPIKey = true
		d.Brightness = 70
		d.DefaultInterval = 15
		d.Timezone = &tz
		d.NightStart, d.NightEnd, d.NightBrightness, d.NightModeEnabled = "22:00", "07:00", 10, true
		if d.AppSettings == nil {
			d.AppSettings = data.JSONMap{}
		}
		d.AppSettings["dim_sunset"] = true
		d.AppSettings["sound"] = false
		d.Info = data.DeviceInfo{FirmwareVersion: "1.7.3-pxt.2"}
		if err := gorm.G[data.Device](s.DB).Create(ctx, &d); err != nil {
			slog.Error("Seed failed", "device", d.ID, "error", err)
			writeAppError(w, http.StatusInternalServerError, "Seed failed.", "")
			return
		}
		for _, id := range appDefaultInstallCandidates {
			if entry, ok := s.findCatalogApp(id); ok {
				_, _ = s.installCatalogApp(ctx, &d, entry, nil)
				break
			}
		}
	}

	devices, _ := gorm.G[data.Device](s.DB).Preload("Apps", orderedAppsPreload).Where("username = ?", user.Username).Find(ctx)
	out := make([]map[string]any, 0, len(devices))
	for i := range devices {
		out = append(out, s.toAppDevice(&devices[i]))
	}
	writeAppJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleDevDial simulates a dial gesture. A turn moves brightness by 10 per
// detent, like the mock.
func (s *Server) handleDevDial(w http.ResponseWriter, r *http.Request) {
	d := s.devDevice(w, r)
	if d == nil {
		return
	}
	var req struct {
		Action string `json:"action"`
		Delta  *int   `json:"delta"`
		Hold   any    `json:"hold"`
	}
	_ = decodeAppJSON(r, &req)
	if req.Action == "" {
		req.Action = "turn"
	}
	delta := 1
	if req.Delta != nil {
		delta = *req.Delta
	}
	if req.Action == "turn" {
		level := min(100, max(0, int(d.Brightness)+delta*10))
		if _, err := gorm.G[data.Device](s.DB).Where("id = ?", d.ID).Update(r.Context(), "brightness", level); err == nil {
			d.Brightness = data.Brightness(level)
			s.Broadcaster.Notify(d.ID, nil)
		}
	}
	s.emitDeviceEvent(d.ID, "dial", map[string]any{
		"action": req.Action, "delta": delta, "brightness": int(d.Brightness), "hold": req.Hold,
	})
	writeAppJSON(w, http.StatusOK, s.toAppDevice(d))
}

func (s *Server) handleDevStatus(w http.ResponseWriter, r *http.Request) {
	d := s.devDevice(w, r)
	if d == nil {
		return
	}
	var req struct {
		Status *string `json:"status"`
	}
	_ = decodeAppJSON(r, &req)
	if d.AppSettings == nil {
		d.AppSettings = data.JSONMap{}
	}
	updates := map[string]any{}
	if req.Status != nil && *req.Status != "" {
		d.AppSettings["status"] = *req.Status
	} else {
		delete(d.AppSettings, "status")
		now := time.Now()
		d.LastSeen = &now
		updates["last_seen"] = now
	}
	updates["app_settings"] = d.AppSettings
	if err := s.DB.Model(&data.Device{ID: d.ID}).Updates(updates).Error; err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	s.emitDeviceEvent(d.ID, "state", map[string]any{"status": req.Status, "online": req.Status == nil || *req.Status == ""})
	writeAppJSON(w, http.StatusOK, s.toAppDevice(d))
}

func (s *Server) handleDevOTA(w http.ResponseWriter, r *http.Request) {
	d := s.devDevice(w, r)
	if d == nil {
		return
	}
	var body map[string]any
	_ = decodeAppJSON(r, &body)
	s.emitDeviceEvent(d.ID, "ota", body)
	if done, _ := body["done"].(bool); done {
		if to, ok := body["to"].(string); ok && to != "" {
			d.Info.FirmwareVersion = to
			delete(d.AppSettings, "update_required")
			if err := s.DB.Model(&data.Device{ID: d.ID}).Updates(map[string]any{"info": d.Info, "app_settings": d.AppSettings}).Error; err != nil {
				slog.Error("Failed to save OTA result", "device", d.ID, "error", err)
			}
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
