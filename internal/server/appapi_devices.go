package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"tronbyt-server/internal/data"
	"tronbyt-server/web"

	"gorm.io/gorm"
)

// Default installations for a newly claimed device, first match wins.
var appDefaultInstallCandidates = []string{"auroraclock", "bigclock", "analogclock", "clock"}

// --- device JSON ---

// toAppDevice renders a device in the app's shape (the mock's _newDevice).
func (s *Server) toAppDevice(d *data.Device) map[string]any {
	product := d.Product
	if product == "" {
		product = "pixeltron"
	}

	settings := map[string]any{}
	maps.Copy(settings, d.AppSettings)
	delete(settings, "status")
	settings["night_mode"] = map[string]any{
		"enabled": d.NightModeEnabled,
		"from":    d.NightStart,
		"to":      d.NightEnd,
		"level":   int(d.NightBrightness),
	}

	apps := slices.Clone(d.Apps)
	sort.SliceStable(apps, func(i, j int) bool { return apps[i].Order < apps[j].Order })
	installs := make([]map[string]any, 0, len(apps))
	for _, a := range apps {
		if a.Pushed {
			continue // one-off pushes aren't part of the rotation the app edits
		}
		name := a.Notes
		if name == "" {
			name = s.catalogAppName(a.Name)
		}
		item := map[string]any{"id": a.Iname, "app_id": a.Name, "name": name}
		if a.DisplayTime > 0 {
			item["duration_sec"] = a.DisplayTime
		} else {
			item["duration_sec"] = nil
		}
		if len(a.Config) > 0 {
			item["config"] = a.Config
		}
		installs = append(installs, item)
	}

	var lastSeen, firmware, wifi, hotspot, status any
	if d.LastSeen != nil {
		lastSeen = d.LastSeen.UTC().Format(time.RFC3339)
	}
	if d.Info.FirmwareVersion != "" {
		firmware = d.Info.FirmwareVersion
	}
	if d.Info.SSID != nil && *d.Info.SSID != "" {
		wifi = *d.Info.SSID
	}
	if code, ok := strings.CutPrefix(d.ID, "pxt-"); ok {
		hotspot = "Pixeltron-" + strings.ToUpper(code)
	}
	if st, ok := d.AppSettings["status"].(string); ok && st != "" {
		status = st
	}

	return map[string]any{
		"id":            d.ID,
		"product":       product,
		"displayName":   d.Name,
		"room":          nilIfEmpty(d.Room),
		"timezone":      d.Timezone,
		"brightness":    int(d.Brightness),
		"intervalSec":   d.DefaultInterval,
		"pinnedApp":     d.PinnedApp,
		"lastSeen":      lastSeen,
		"status":        status,
		"firmware":      firmware,
		"wifi":          wifi,
		"hotspot":       hotspot,
		"nowShowing":    d.DisplayingApp,
		"settings":      settings,
		"installations": installs,
	}
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Server) handleAppDevices(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	out := make([]map[string]any, 0, len(user.Devices))
	for i := range user.Devices {
		out = append(out, s.toAppDevice(&user.Devices[i]))
	}
	writeAppJSON(w, http.StatusOK, map[string]any{"devices": out})
}

func (s *Server) handleAppDevice(w http.ResponseWriter, r *http.Request) {
	writeAppJSON(w, http.StatusOK, s.toAppDevice(GetDevice(r)))
}

// handleAppPatchDevice applies the whitelisted fields; settings is merged
// one level deep (night_mode is replaced as a whole).
func (s *Server) handleAppPatchDevice(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)

	var body map[string]json.RawMessage
	if err := decodeAppJSON(r, &body); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	bad := func(field string) {
		writeAppError(w, http.StatusBadRequest, "Invalid "+field+".", "bad_request")
	}
	isNull := func(raw json.RawMessage) bool { return string(raw) == "null" }

	brightnessChanged := false
	if raw, ok := body["displayName"]; ok {
		var v string
		if json.Unmarshal(raw, &v) != nil || strings.TrimSpace(v) == "" {
			bad("displayName")
			return
		}
		device.Name = strings.TrimSpace(v)
	}
	if raw, ok := body["room"]; ok {
		var v *string
		if json.Unmarshal(raw, &v) != nil {
			bad("room")
			return
		}
		device.Room = ""
		if v != nil {
			device.Room = strings.TrimSpace(*v)
		}
	}
	if raw, ok := body["timezone"]; ok {
		var v *string
		if json.Unmarshal(raw, &v) != nil {
			bad("timezone")
			return
		}
		if v != nil {
			if _, err := time.LoadLocation(*v); err != nil {
				bad("timezone")
				return
			}
		}
		device.Timezone = v
	}
	if raw, ok := body["brightness"]; ok {
		var v int
		if json.Unmarshal(raw, &v) != nil || v < 0 || v > 100 {
			bad("brightness")
			return
		}
		brightnessChanged = int(device.Brightness) != v
		device.Brightness = data.Brightness(v)
	}
	if raw, ok := body["intervalSec"]; ok {
		var v int
		if json.Unmarshal(raw, &v) != nil || v < 1 {
			bad("intervalSec")
			return
		}
		device.DefaultInterval = v
	}
	if raw, ok := body["pinnedApp"]; ok {
		if isNull(raw) {
			device.PinnedApp = nil
		} else {
			var v string
			if json.Unmarshal(raw, &v) != nil {
				bad("pinnedApp")
				return
			}
			if v == "" {
				device.PinnedApp = nil
			} else if device.GetApp(v) == nil {
				writeAppError(w, http.StatusBadRequest, "That app isn't on this device.", "unknown_installation")
				return
			} else {
				device.PinnedApp = &v
			}
		}
	}
	if raw, ok := body["settings"]; ok {
		var patch map[string]any
		if json.Unmarshal(raw, &patch) != nil {
			bad("settings")
			return
		}
		if device.AppSettings == nil {
			device.AppSettings = data.JSONMap{}
		}
		for k, v := range patch {
			switch k {
			case "night_mode":
				nm, _ := v.(map[string]any)
				if nm == nil {
					bad("night_mode")
					return
				}
				if en, ok := nm["enabled"].(bool); ok {
					device.NightModeEnabled = en
				}
				if from, ok := nm["from"].(string); ok {
					device.NightStart = from
					device.NightSchedule.Start = nil
				}
				if to, ok := nm["to"].(string); ok {
					device.NightEnd = to
					device.NightSchedule.End = nil
				}
				if lvl, ok := nm["level"].(float64); ok && lvl >= 0 && lvl <= 100 {
					device.NightBrightness = data.Brightness(int(lvl))
				}
				clearNightModeOverride(device)
			case "status":
				// Set by the device side, not the app.
			default:
				if v == nil {
					delete(device.AppSettings, k)
				} else {
					device.AppSettings[k] = v
				}
			}
		}
	}

	if err := s.DB.Omit("Apps").Save(device).Error; err != nil {
		slog.Error("Failed to save device from app", "device", device.ID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	if brightnessChanged {
		s.emitDeviceEvent(device.ID, "state", map[string]any{"brightness": int(device.Brightness)})
	}
	s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	s.writeAppDevice(w, r, http.StatusOK, device.ID)
}

func (s *Server) handleAppRelease(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)
	if err := s.deleteDevice(r.Context(), device.ID); err != nil {
		slog.Error("Failed to release device", "device", device.ID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	s.notifyDashboard(user.Username, WSEvent{Type: "device_deleted", DeviceID: device.ID})
	s.emitDeviceEvent(device.ID, "state", map[string]any{"online": false})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAppReboot(w http.ResponseWriter, r *http.Request) {
	if err := s.sendRebootCommand(r.Context(), GetDevice(r).ID); err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleAppFrame returns what the device is showing as a PNG (first frame).
func (s *Server) handleAppFrame(w http.ResponseWriter, r *http.Request) {
	device := GetDevice(r)
	img, _, err := s.GetCurrentAppImage(r.Context(), device)
	if err != nil || len(img) == 0 {
		img, err = defaultWebP()
		if err != nil {
			writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
			return
		}
	}
	out, err := firstFramePNG(img)
	if err != nil {
		slog.Warn("Failed to convert frame", "device", device.ID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(out)
}

func defaultWebP() ([]byte, error) {
	f, err := web.Assets.Open("static/images/default.webp")
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	return io.ReadAll(f)
}

// --- installations ---

func (s *Server) handleAppAddInstallation(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)
	var req struct {
		AppID  string         `json:"app_id"`
		Config map[string]any `json:"config"`
	}
	if err := decodeAppJSON(r, &req); err != nil || req.AppID == "" {
		writeAppError(w, http.StatusBadRequest, "Pick an app to add.", "bad_request")
		return
	}
	entry, ok := s.findCatalogApp(req.AppID)
	if !ok {
		writeAppError(w, http.StatusNotFound, "unknown app", "unknown_app")
		return
	}
	if _, err := s.installCatalogApp(r.Context(), device, entry, req.Config); err != nil {
		slog.Error("Failed to add installation", "device", device.ID, "app", req.AppID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	s.writeAppDevice(w, r, http.StatusCreated, device.ID)
}

// installCatalogApp appends a catalog app to a device and renders it in the
// background.
func (s *Server) installCatalogApp(ctx context.Context, device *data.Device, entry appCatalogEntry, config map[string]any) (*data.App, error) {
	iname, err := generateUniqueIname(s.DB, device.ID)
	if err != nil {
		return nil, err
	}
	interval := entry.meta.RecommendedInterval
	if interval <= 0 {
		interval = 10
	}
	path := entry.meta.Path
	app := data.App{
		DeviceID:  device.ID,
		Iname:     iname,
		Name:      entry.meta.ID,
		UInterval: interval,
		Enabled:   true,
		Path:      &path,
		Config:    data.JSONMap(config),
	}
	if err := s.insertApp(ctx, nil, device.ID, &app, -1); err != nil {
		return nil, err
	}
	s.renderInBackground(device.ID, app.Iname)
	return &app, nil
}

// renderInBackground renders one installation without holding up the
// response; the device picks it up on its next rotation.
func (s *Server) renderInBackground(deviceID, iname string) {
	run := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		d, err := s.reloadAppDevice(ctx, deviceID)
		if err != nil {
			return
		}
		app := d.GetApp(iname)
		if app == nil {
			return
		}
		owner, err := gorm.G[data.User](s.DB).Where("username = ?", d.Username).First(ctx)
		if err != nil {
			return
		}
		s.possiblyRender(ctx, app, d, &owner)
		s.Broadcaster.Notify(deviceID, nil)
	}
	if appRenderSync {
		run()
		return
	}
	go run()
}

// appRenderSync makes renderInBackground block; tests set it so renders
// finish before the test's temp dir and database go away.
var appRenderSync = false

func (s *Server) handleAppReorder(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)
	var req struct {
		Order []string `json:"order"`
	}
	if err := decodeAppJSON(r, &req); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	pos := map[string]int{}
	for i, iname := range req.Order {
		if _, dup := pos[iname]; !dup {
			pos[iname] = i
		}
	}
	apps := slices.Clone(device.Apps)
	sort.SliceStable(apps, func(i, j int) bool {
		pi, iok := pos[apps[i].Iname]
		pj, jok := pos[apps[j].Iname]
		switch {
		case iok && jok:
			return pi < pj
		case iok != jok:
			return iok // listed apps first, unlisted keep their order after
		default:
			return apps[i].Order < apps[j].Order
		}
	})
	err := s.DB.Transaction(func(tx *gorm.DB) error {
		for i, a := range apps {
			if _, err := gorm.G[data.App](tx).Where("id = ?", a.ID).Update(r.Context(), "order", i); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	s.writeAppDevice(w, r, http.StatusOK, device.ID)
}

func (s *Server) handleAppPatchInstallation(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)
	app := device.GetApp(r.PathValue("iname"))
	if app == nil || app.Pushed {
		writeAppNotFound(w)
		return
	}
	var body map[string]json.RawMessage
	if err := decodeAppJSON(r, &body); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	updates := map[string]any{}
	rerender := false
	if raw, ok := body["duration_sec"]; ok {
		var v *int
		if json.Unmarshal(raw, &v) != nil || (v != nil && *v < 0) {
			writeAppError(w, http.StatusBadRequest, "Invalid duration_sec.", "bad_request")
			return
		}
		updates["display_time"] = 0
		if v != nil {
			updates["display_time"] = *v
		}
	}
	if raw, ok := body["name"]; ok {
		var v *string
		if json.Unmarshal(raw, &v) != nil {
			writeAppError(w, http.StatusBadRequest, "Invalid name.", "bad_request")
			return
		}
		updates["notes"] = ""
		if v != nil {
			updates["notes"] = strings.TrimSpace(*v)
		}
	}
	if raw, ok := body["config"]; ok {
		var v map[string]any
		if json.Unmarshal(raw, &v) != nil {
			writeAppError(w, http.StatusBadRequest, "Invalid config.", "bad_request")
			return
		}
		updates["config"] = data.JSONMap(v)
		rerender = true
	}
	if len(updates) > 0 {
		if err := s.DB.Model(&data.App{ID: app.ID}).Updates(updates).Error; err != nil {
			writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
			return
		}
	}
	if rerender {
		s.removeAppRenders(device.ID, app.Iname)
		s.cleanupAppChunks(device.ID, app)
		s.invalidateAppChunks(device.ID, app.Iname)
		s.renderInBackground(device.ID, app.Iname)
	}
	s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	s.writeAppDevice(w, r, http.StatusOK, device.ID)
}

func (s *Server) handleAppDeleteInstallation(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	device := GetDevice(r)
	iname := r.PathValue("iname")
	if app := device.GetApp(iname); app != nil {
		if err := s.deleteApp(r.Context(), device.ID, app); err != nil {
			writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
			return
		}
		if device.PinnedApp != nil && *device.PinnedApp == iname {
			if _, err := gorm.G[data.Device](s.DB).Where("id = ?", device.ID).Update(r.Context(), "pinned_app", nil); err != nil {
				slog.Error("Failed to clear pinned app", "device", device.ID, "error", err)
			}
		}
		s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	}
	s.writeAppDevice(w, r, http.StatusOK, device.ID)
}

// --- push ---

// handleAppPushApp shows one installation on the device now.
func (s *Server) handleAppPushApp(w http.ResponseWriter, r *http.Request) {
	device := GetDevice(r)
	var req struct {
		Installation string `json:"installation"`
	}
	if err := decodeAppJSON(r, &req); err != nil || req.Installation == "" {
		writeAppError(w, http.StatusBadRequest, "Pick an app to show.", "bad_request")
		return
	}
	app := device.GetApp(req.Installation)
	if app == nil {
		writeAppNotFound(w)
		return
	}

	var img []byte
	if dir, err := s.ensureDeviceImageDir(device.ID); err == nil {
		img, _ = os.ReadFile(s.getAppWebpPath(dir, app))
	}
	if len(img) == 0 && app.Path != nil && !strings.HasPrefix(*app.Path, "pushed:") {
		var err error
		img, _, err = s.RenderApp(r.Context(), device, app, filepath.Join(s.DataDir, *app.Path), nil)
		if err != nil {
			slog.Error("Failed to render app for push", "device", device.ID, "app", app.Iname, "error", err)
			writeAppError(w, http.StatusBadGateway, "That app couldn't draw right now.", "render_failed")
			return
		}
	}
	if len(img) == 0 {
		writeAppError(w, http.StatusConflict, "That app has nothing to show yet.", "empty_render")
		return
	}
	s.Broadcaster.Notify(device.ID, img)
	if _, err := gorm.G[data.Device](s.DB).Where("id = ?", device.ID).Update(r.Context(), "displaying_app", app.Iname); err != nil {
		slog.Error("Failed to update displaying_app", "device", device.ID, "error", err)
	}
	s.emitDeviceEvent(device.ID, "state", map[string]any{"now": app.Iname})
	w.WriteHeader(http.StatusNoContent)
}

// handleAppPush shows a one-off image (the app's Send tab).
func (s *Server) handleAppPush(w http.ResponseWriter, r *http.Request) {
	device := GetDevice(r)
	var req struct {
		Image  string `json:"image"`
		Format string `json:"format"`
		Chime  bool   `json:"chime"`
	}
	if err := decodeAppJSON(r, &req); err != nil || req.Image == "" {
		writeAppError(w, http.StatusBadRequest, "No image to send.", "bad_request")
		return
	}
	raw, err := base64.StdEncoding.DecodeString(req.Image)
	if err != nil {
		writeAppError(w, http.StatusBadRequest, "That image didn't come through.", "bad_image")
		return
	}
	webpBytes, err := pngToWebP(raw)
	if err != nil {
		writeAppError(w, http.StatusBadRequest, "That image didn't come through.", "bad_image")
		return
	}
	if err := s.processPushedImage(r.Context(), device, "", "", false, webpBytes); err != nil {
		slog.Error("Failed to push image", "device", device.ID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	if req.Chime && device.Type.SupportsAudio() {
		if err := s.TriggerDeviceSound(r.Context(), device, "chime", s.GetDeviceBaseURL(device)); err != nil {
			slog.Warn("Failed to chime on push", "device", device.ID, "error", err)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- claiming ---

func (s *Server) handleAppClaim(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	var req struct {
		ClaimCode string  `json:"claim_code"`
		Name      string  `json:"name"`
		Room      string  `json:"room"`
		Timezone  *string `json:"timezone"`
	}
	if err := decodeAppJSON(r, &req); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	code := strings.ToUpper(strings.TrimSpace(req.ClaimCode))
	expired := func() {
		writeAppError(w, http.StatusGone, "That claim code has expired.", "invalid_claim")
	}
	if code == "" {
		expired()
		return
	}
	ctx := r.Context()
	reg, err := gorm.G[data.DeviceRegistration](s.DB).
		Where("claim_code = ? AND claim_expires > ?", code, time.Now()).
		First(ctx)
	if err != nil {
		expired()
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = "Pixeltron"
	}
	tz := req.Timezone
	if tz != nil {
		if _, err := time.LoadLocation(*tz); err != nil {
			tz = nil
		}
	}
	if tz == nil {
		def := "America/New_York"
		tz = &def
	}
	now := time.Now()
	device := data.Device{
		ID:              reg.ID,
		Username:        user.Username,
		Name:            name,
		Type:            data.DeviceTronbytS3,
		APIKey:          reg.APIKey,
		RequireAPIKey:   true,
		Brightness:      60,
		DefaultInterval: 15,
		NightStart:      "22:00",
		NightEnd:        "07:00",
		NightBrightness: 10,
		Timezone:        tz,
		Product:         reg.Product,
		Room:            strings.TrimSpace(req.Room),
		AppSettings:     data.JSONMap{"dim_sunset": false, "sound": false},
		Info:            data.DeviceInfo{FirmwareVersion: reg.Firmware, MACAddress: reg.MAC},
		LastSeen:        &now,
	}
	err = s.DB.Transaction(func(tx *gorm.DB) error {
		// Delete first so two claims with the same code can't both win.
		n, err := gorm.G[data.DeviceRegistration](tx).Where("id = ? AND claim_code = ?", reg.ID, code).Delete(ctx)
		if err != nil {
			return err
		}
		if n == 0 {
			return errClaimTaken
		}
		return gorm.G[data.Device](tx).Create(ctx, &device)
	})
	if errors.Is(err, errClaimTaken) {
		expired()
		return
	}
	if err != nil {
		slog.Error("Failed to claim device", "device", reg.ID, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}

	for _, id := range appDefaultInstallCandidates {
		if entry, ok := s.findCatalogApp(id); ok {
			if _, err := s.installCatalogApp(ctx, &device, entry, nil); err != nil {
				slog.Warn("Failed to add default app", "device", device.ID, "app", id, "error", err)
			}
			break
		}
	}
	slog.Info("Device claimed", "device", device.ID, "user", user.Username)
	s.notifyDashboard(user.Username, WSEvent{Type: "apps_changed", DeviceID: device.ID})
	s.writeAppDevice(w, r, http.StatusCreated, device.ID)
}

var errClaimTaken = errors.New("claim already used")

// handleDeviceRegister is called by an unclaimed device once it is online.
// It returns the device's id and key and a fresh claim code to show the app.
func (s *Server) handleDeviceRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		MAC      string `json:"mac"`
		Product  string `json:"product"`
		Firmware string `json:"firmware"`
	}
	if err := decodeAppJSON(r, &req); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}
	mac, err := parseMAC(req.MAC)
	if err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid MAC address.", "bad_mac")
		return
	}
	if !deviceRegisterLimiter.allow(clientIP(r)) {
		writeAppError(w, http.StatusTooManyRequests, "Too many requests. Wait a minute.", "rate_limited")
		return
	}
	product := req.Product
	if product == "" {
		product = "pixeltron"
	}
	id := pixeltronDeviceID(mac)
	macStr := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(req.MAC, "-", ":"), ".", ":"))
	ctx := r.Context()

	if _, err := gorm.G[data.Device](s.DB).Where("id = ?", id).First(ctx); err == nil {
		writeAppError(w, http.StatusConflict, "This device already has an owner.", "already_claimed")
		return
	}

	code, err := newClaimCode()
	if err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	expires := time.Now().Add(claimCodeTTL)

	reg, err := gorm.G[data.DeviceRegistration](s.DB).Where("id = ?", id).First(ctx)
	switch {
	case err == nil:
		// Same device again (reboot, retry): keep its key, issue a new code.
		_, err = gorm.G[data.DeviceRegistration](s.DB).Where("id = ?", id).
			Updates(ctx, data.DeviceRegistration{ClaimCode: code, ClaimExpires: expires, Firmware: req.Firmware, Product: product})
		reg.ClaimCode, reg.ClaimExpires = code, expires
	case errors.Is(err, gorm.ErrRecordNotFound):
		key, kerr := generateSecureToken(32)
		if kerr != nil {
			err = kerr
			break
		}
		reg = data.DeviceRegistration{
			ID: id, MAC: macStr, Product: product, Firmware: req.Firmware,
			APIKey: key, ClaimCode: code, ClaimExpires: expires,
		}
		err = gorm.G[data.DeviceRegistration](s.DB).Create(ctx, &reg)
	}
	if err != nil {
		slog.Error("Failed to register device", "device", id, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	writeAppJSON(w, http.StatusOK, map[string]any{
		"device_id":  reg.ID,
		"api_key":    reg.APIKey,
		"claim_code": reg.ClaimCode,
		"expires_in": int(claimCodeTTL.Seconds()),
		"code_word":  pixeltronCodeWord(mac),
		"ws_url":     s.getWebsocketURL(r, reg.ID),
	})
}

// handleDeviceClaimStatus lets a registered device ask, with its key,
// whether someone has claimed it yet.
func (s *Server) handleDeviceClaimStatus(w http.ResponseWriter, r *http.Request) {
	key := bearerToken(r)
	if key == "" {
		writeAppError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
		return
	}
	ctx := r.Context()
	if d, err := gorm.G[data.Device](s.DB).Where("api_key = ?", key).First(ctx); err == nil {
		writeAppJSON(w, http.StatusOK, map[string]any{"claimed": true, "device_id": d.ID})
		return
	}
	if reg, err := gorm.G[data.DeviceRegistration](s.DB).Where("api_key = ?", key).First(ctx); err == nil {
		writeAppJSON(w, http.StatusOK, map[string]any{"claimed": false, "device_id": reg.ID})
		return
	}
	// Unknown key: the device was released. It should start setup again.
	writeAppError(w, http.StatusUnauthorized, "This device isn't linked.", "not_linked")
}
