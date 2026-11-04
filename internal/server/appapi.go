package server

// Pixels app API, mounted at /app/v0. The contract is the Pixels mock server
// (pixels/tools/mock_server/lib/cloud.dart) and its contract tests; field
// names and status codes here must match it. The legacy /v0 API (API.md) is
// separate and unchanged.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"tronbyt-server/internal/data"

	"gorm.io/gorm"
)

const (
	appAPIPrefix  = "/app/v0"
	appAccessTTL  = time.Hour
	appRefreshTTL = 90 * 24 * time.Hour
	claimCodeTTL  = 30 * time.Minute
)

// SetupAppAPIRoutes registers the Pixels app API.
func (s *Server) SetupAppAPIRoutes() {
	p := appAPIPrefix
	r := s.Router

	// Account
	r.HandleFunc("POST "+p+"/auth/refresh", s.handleAppRefresh)
	r.HandleFunc("POST "+p+"/auth/logout", s.appAuth(s.handleAppLogout))
	r.HandleFunc("POST "+p+"/auth/{method}", s.handleAppSignIn)
	r.HandleFunc("GET "+p+"/me", s.appAuth(s.handleAppMe))
	r.HandleFunc("POST "+p+"/me/push-tokens", s.appAuth(s.handleAppPushToken))

	// Catalog
	r.HandleFunc("GET "+p+"/products", s.handleAppProducts)
	r.HandleFunc("GET "+p+"/apps", s.appAuth(s.handleAppCatalog))
	r.HandleFunc("GET "+p+"/apps/{id}", s.appAuth(s.handleAppCatalogItem))
	r.HandleFunc("GET "+p+"/apps/{id}/preview", s.handleAppPreview)

	// Devices
	r.HandleFunc("POST "+p+"/claims", s.appAuth(s.handleAppClaim))
	r.HandleFunc("GET "+p+"/devices", s.appAuth(s.handleAppDevices))
	r.HandleFunc("GET "+p+"/devices/{id}", s.appDevice(s.handleAppDevice))
	r.HandleFunc("PATCH "+p+"/devices/{id}", s.appDevice(s.handleAppPatchDevice))
	r.HandleFunc("POST "+p+"/devices/{id}/release", s.appDevice(s.handleAppRelease))
	r.HandleFunc("POST "+p+"/devices/{id}/reboot", s.appDevice(s.handleAppReboot))
	r.HandleFunc("GET "+p+"/devices/{id}/frame", s.appDevice(s.handleAppFrame))
	r.HandleFunc("POST "+p+"/devices/{id}/installations", s.appDevice(s.handleAppAddInstallation))
	r.HandleFunc("PUT "+p+"/devices/{id}/installations/order", s.appDevice(s.handleAppReorder))
	r.HandleFunc("PATCH "+p+"/devices/{id}/installations/{iname}", s.appDevice(s.handleAppPatchInstallation))
	r.HandleFunc("DELETE "+p+"/devices/{id}/installations/{iname}", s.appDevice(s.handleAppDeleteInstallation))
	r.HandleFunc("POST "+p+"/devices/{id}/push_app", s.appDevice(s.handleAppPushApp))
	r.HandleFunc("POST "+p+"/devices/{id}/push", s.appDevice(s.handleAppPush))
	r.HandleFunc("GET "+p+"/devices/{id}/events", s.appDevice(s.handleAppEvents))

	// Device-facing bootstrap (authenticated by the device's own key)
	r.HandleFunc("POST "+p+"/device/register", s.handleDeviceRegister)
	r.HandleFunc("GET "+p+"/device/claim", s.handleDeviceClaimStatus)

	if s.Config != nil && s.Config.PixelsDevHooks {
		slog.Warn("PIXELS_DEV_HOOKS is on: /app/_mock/* test hooks are enabled")
		s.setupAppDevHooks()
	}
}

// --- responses ---

func writeAppJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("Failed to encode app API response", "error", err)
	}
}

// writeAppError writes the app's error shape: {"error": message, "code": code}.
// code may be empty.
func writeAppError(w http.ResponseWriter, status int, message, code string) {
	body := map[string]string{"error": message}
	if code != "" {
		body["code"] = code
	}
	writeAppJSON(w, status, body)
}

func writeAppNotFound(w http.ResponseWriter) {
	writeAppError(w, http.StatusNotFound, "not found", "")
}

func decodeAppJSON(r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(nil, r.Body, 8<<20)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

// --- auth ---

func hashToken(t string) string {
	sum := sha256.Sum256([]byte(t))
	return hex.EncodeToString(sum[:])
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// appUserFromRequest resolves the caller from an app access token or, for
// the app's self-hosted mode, a user API key.
func (s *Server) appUserFromRequest(r *http.Request) (*data.User, error) {
	token := bearerToken(r)
	if token == "" {
		return nil, gorm.ErrRecordNotFound
	}
	ctx := r.Context()

	username := ""
	sess, err := gorm.G[data.AppSession](s.DB).
		Where("access_hash = ? AND access_expires > ?", hashToken(token), time.Now()).
		First(ctx)
	switch {
	case err == nil:
		username = sess.Username
	case !errors.Is(err, gorm.ErrRecordNotFound):
		return nil, err
	}

	q := gorm.G[data.User](s.DB).
		Preload("Devices", func(db gorm.PreloadBuilder) error {
			db.Order("name ASC")
			return nil
		}).
		Preload("Devices.Apps", orderedAppsPreload)
	var user data.User
	if username != "" {
		user, err = q.Where("username = ?", username).First(ctx)
	} else {
		user, err = q.Where("api_key = ?", token).First(ctx)
	}
	if err != nil {
		return nil, err
	}
	return &user, nil
}

// appAuth requires a signed-in app user.
func (s *Server) appAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, err := s.appUserFromRequest(r)
		if err != nil {
			if !errors.Is(err, gorm.ErrRecordNotFound) {
				slog.Error("App API auth failed", "error", err)
				writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
				return
			}
			writeAppError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), userContextKey, user)))
	}
}

// appDevice requires a signed-in user who owns the {id} device.
func (s *Server) appDevice(next http.HandlerFunc) http.HandlerFunc {
	return s.appAuth(func(w http.ResponseWriter, r *http.Request) {
		user := GetUser(r)
		id := r.PathValue("id")
		for i := range user.Devices {
			if user.Devices[i].ID == id {
				ctx := context.WithValue(r.Context(), deviceContextKey, &user.Devices[i])
				next(w, r.WithContext(ctx))
				return
			}
		}
		writeAppNotFound(w)
	})
}

// reloadAppDevice re-reads a device with its apps after a change.
func (s *Server) reloadAppDevice(ctx context.Context, id string) (*data.Device, error) {
	d, err := gorm.G[data.Device](s.DB).Preload("Apps", orderedAppsPreload).Where("id = ?", id).First(ctx)
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// writeAppDevice reloads a device and writes it in the app's shape.
func (s *Server) writeAppDevice(w http.ResponseWriter, r *http.Request, status int, id string) {
	d, err := s.reloadAppDevice(r.Context(), id)
	if err != nil {
		slog.Error("Failed to reload device", "device", id, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	writeAppJSON(w, status, s.toAppDevice(d))
}
