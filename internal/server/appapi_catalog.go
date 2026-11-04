package server

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"image"
	"image/gif"
	"image/png"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tronbyt-server/internal/apps"
	"tronbyt-server/internal/chunker"
	"tronbyt-server/internal/renderer"

	securejoin "github.com/cyphar/filepath-securejoin"
)

//go:embed appapi_products.json
var appProductsJSON []byte

// appCatalogEntry is one app the Pixels app can install.
type appCatalogEntry struct {
	meta    apps.AppMetadata
	popular bool
}

func (e appCatalogEntry) category() string {
	c := strings.TrimSpace(e.meta.Category)
	if c == "" {
		return "Other"
	}
	return strings.ToUpper(c[:1]) + c[1:]
}

// appCatalogState caches schemas (keyed by app path + mtime) and previews.
type appCatalogState struct {
	mu       sync.Mutex
	schemas  map[string][]map[string]any
	previews map[string][]byte
}

var appCatalogCache = &appCatalogState{
	schemas:  map[string][]map[string]any{},
	previews: map[string][]byte{},
}

func (s *Server) appAPIBase(r *http.Request) string {
	return strings.TrimSuffix(s.GetBaseURL(r), "/") + appAPIPrefix
}

func (s *Server) handleAppProducts(w http.ResponseWriter, r *http.Request) {
	var products []map[string]any
	if err := json.Unmarshal(appProductsJSON, &products); err != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	base := s.appAPIBase(r)
	for _, p := range products {
		if p["api_base"] == "{api_base}" {
			p["api_base"] = base
		}
	}
	writeAppJSON(w, http.StatusOK, map[string]any{"products": products})
}

// appCatalog lists featured apps first (marked popular), then system apps.
// Broken apps are left out.
func (s *Server) appCatalog() []appCatalogEntry {
	var out []appCatalogEntry
	seen := map[string]bool{}
	if s.Config != nil && s.Config.FeaturedAppsDir != "" {
		featured, err := apps.ListAppsInDir(s.DataDir, s.Config.FeaturedAppsDir)
		if err != nil {
			slog.Warn("Failed to list featured apps", "dir", s.Config.FeaturedAppsDir, "error", err)
		}
		for _, m := range featured {
			if m.Broken || seen[m.ID] {
				continue
			}
			seen[m.ID] = true
			out = append(out, appCatalogEntry{meta: m, popular: true})
		}
	}
	for _, m := range s.ListSystemApps() {
		if m.Broken || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		out = append(out, appCatalogEntry{meta: m})
	}
	return out
}

func (s *Server) findCatalogApp(id string) (appCatalogEntry, bool) {
	for _, e := range s.appCatalog() {
		if e.meta.ID == id {
			return e, true
		}
	}
	return appCatalogEntry{}, false
}

// catalogAppName returns the display name for an app id, or the id itself.
func (s *Server) catalogAppName(id string) string {
	if e, ok := s.findCatalogApp(id); ok && e.meta.Name != "" {
		return e.meta.Name
	}
	return id
}

// appSchema returns the app's Pixlet schema fields. Results are cached by
// path and modification time; a failure yields no fields.
func (s *Server) appSchema(ctx context.Context, e appCatalogEntry) []map[string]any {
	dir := filepath.Join(s.DataDir, e.meta.Path)
	star := filepath.Join(dir, e.meta.FileName)
	key := dir
	if info, err := os.Stat(star); err == nil {
		key += "@" + info.ModTime().UTC().Format(time.RFC3339Nano)
	}
	appCatalogCache.mu.Lock()
	cached, ok := appCatalogCache.schemas[key]
	appCatalogCache.mu.Unlock()
	if ok {
		return cached
	}

	fields := []map[string]any{}
	raw, err := renderer.GetSchema(ctx, dir, 64, 32, false)
	if err != nil {
		slog.Warn("Failed to load app schema", "app", e.meta.ID, "error", err)
	} else {
		var doc struct {
			Schema []map[string]any `json:"schema"`
		}
		if err := json.Unmarshal(raw, &doc); err == nil && doc.Schema != nil {
			fields = doc.Schema
		}
	}
	appCatalogCache.mu.Lock()
	appCatalogCache.schemas[key] = fields
	appCatalogCache.mu.Unlock()
	return fields
}

// apiBase makes the preview URL absolute: the app fetches absolute preview
// URLs as they are, and only knows how to rebase paths that start with /v0.
func (s *Server) appListingJSON(ctx context.Context, apiBase string, e appCatalogEntry, withSchema bool) map[string]any {
	m := map[string]any{
		"id":       e.meta.ID,
		"name":     e.meta.Name,
		"category": e.category(),
		"popular":  e.popular,
		"preview":  apiBase + "/apps/" + url.PathEscape(e.meta.ID) + "/preview",
	}
	if e.meta.Summary != "" {
		m["summary"] = e.meta.Summary
	}
	if withSchema {
		m["schema"] = s.appSchema(ctx, e)
	}
	return m
}

// maxUnfilteredApps bounds GET /apps without a query or category.
const maxUnfilteredApps = 300

// schemaInListLimit: lists at most this long include schemas inline (they
// cost a Starlark load each the first time). Longer lists leave them out and
// the app fetches GET /apps/{id} when it needs one.
const schemaInListLimit = 40

// appCategoryAliases maps the app's category chips (Time, Money, ...) to the
// categories Pixlet app manifests use.
var appCategoryAliases = map[string][]string{
	"time":  {"clocks", "clock", "time"},
	"money": {"finance", "money"},
	"art":   {"art", "artwork"},
}

func categoryMatches(want, have string) bool {
	if strings.EqualFold(want, have) {
		return true
	}
	for _, c := range appCategoryAliases[strings.ToLower(want)] {
		if strings.EqualFold(c, have) {
			return true
		}
	}
	return false
}

func (s *Server) handleAppCatalog(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	category := r.URL.Query().Get("category")

	var matched []appCatalogEntry
	for _, e := range s.appCatalog() {
		if q != "" && !strings.Contains(strings.ToLower(e.meta.Name), q) &&
			!strings.Contains(strings.ToLower(e.category()), q) &&
			!strings.Contains(strings.ToLower(e.meta.ID), q) {
			continue
		}
		switch {
		case category == "":
		case strings.EqualFold(category, "Popular"):
			if !e.popular {
				continue
			}
		case !categoryMatches(category, e.category()):
			continue
		}
		matched = append(matched, e)
	}
	if q == "" && category == "" && len(matched) > maxUnfilteredApps {
		matched = matched[:maxUnfilteredApps]
	}

	base := s.appAPIBase(r)
	withSchema := len(matched) <= schemaInListLimit
	out := make([]map[string]any, 0, len(matched))
	for _, e := range matched {
		out = append(out, s.appListingJSON(r.Context(), base, e, withSchema))
	}
	writeAppJSON(w, http.StatusOK, map[string]any{"apps": out})
}

func (s *Server) handleAppCatalogItem(w http.ResponseWriter, r *http.Request) {
	e, ok := s.findCatalogApp(r.PathValue("id"))
	if !ok {
		writeAppError(w, http.StatusNotFound, "unknown app", "unknown_app")
		return
	}
	writeAppJSON(w, http.StatusOK, s.appListingJSON(r.Context(), s.appAPIBase(r), e, true))
}

// handleAppPreview serves a 64x32 PNG of the app: its shipped preview image
// if it has one, otherwise a fresh render.
func (s *Server) handleAppPreview(w http.ResponseWriter, r *http.Request) {
	e, ok := s.findCatalogApp(r.PathValue("id"))
	if !ok {
		writeAppError(w, http.StatusNotFound, "unknown app", "unknown_app")
		return
	}
	appCatalogCache.mu.Lock()
	cached, ok := appCatalogCache.previews[e.meta.Path]
	appCatalogCache.mu.Unlock()
	if !ok {
		var err error
		cached, err = s.renderAppPreviewPNG(r.Context(), e)
		if err != nil {
			slog.Warn("Failed to build app preview", "app", e.meta.ID, "error", err)
			writeAppError(w, http.StatusNotFound, "No preview for this app.", "no_preview")
			return
		}
		appCatalogCache.mu.Lock()
		appCatalogCache.previews[e.meta.Path] = cached
		appCatalogCache.mu.Unlock()
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(cached)
}

func (s *Server) renderAppPreviewPNG(ctx context.Context, e appCatalogEntry) ([]byte, error) {
	if e.meta.Preview != "" {
		p, err := securejoin.SecureJoin(filepath.Join(s.DataDir, e.meta.Path), filepath.Base(e.meta.Preview))
		if err == nil {
			if b, err := os.ReadFile(p); err == nil {
				if out, err := firstFramePNG(b); err == nil {
					return out, nil
				}
			}
		}
	}
	img, _, err := s.RenderApp(ctx, nil, nil, filepath.Join(s.DataDir, e.meta.Path), nil)
	if err != nil {
		return nil, err
	}
	return firstFramePNG(img)
}

// firstFramePNG turns a WebP, GIF or PNG (animated or not) into a PNG of its
// first frame.
func firstFramePNG(b []byte) ([]byte, error) {
	switch {
	case bytes.HasPrefix(b, []byte("\x89PNG")):
		return b, nil
	case bytes.HasPrefix(b, []byte("GIF8")):
		g, err := gif.DecodeAll(bytes.NewReader(b))
		if err != nil {
			return nil, err
		}
		if len(g.Image) == 0 {
			return nil, image.ErrFormat
		}
		return encodePNG(g.Image[0])
	}
	frames, _, err := chunker.DecodeWebPAnimation(b)
	if err != nil {
		return nil, err
	}
	if len(frames) == 0 {
		return nil, image.ErrFormat
	}
	return encodePNG(frames[0])
}

// pngToWebP converts a pushed PNG (or passes through a WebP) for the device.
func pngToWebP(b []byte) ([]byte, error) {
	if !bytes.HasPrefix(b, []byte("\x89PNG")) {
		return b, nil // already WebP (or GIF the device can't show; let it fail there)
	}
	img, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	rgba := image.NewRGBA(img.Bounds())
	for y := img.Bounds().Min.Y; y < img.Bounds().Max.Y; y++ {
		for x := img.Bounds().Min.X; x < img.Bounds().Max.X; x++ {
			rgba.Set(x, y, img.At(x, y))
		}
	}
	return chunker.EncodeFramesToWebP([]*image.RGBA{rgba}, 15*time.Second)
}
