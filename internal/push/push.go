// Package push sends notifications to the Pixels app through APNs (iOS)
// and FCM HTTP v1 (Android).
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/jwt"
)

// Message is one notification. The title says what happened; the body says
// what to do, if anything.
type Message struct {
	Title string
	Body  string
	Data  map[string]string
}

// ErrUnregistered means the token is dead and should be forgotten.
var ErrUnregistered = errors.New("push token is no longer valid")

// Sender delivers to one platform.
type Sender interface {
	Send(ctx context.Context, token string, m Message) error
}

// --- APNs ---

// APNsConfig is token-based (.p8) authentication.
type APNsConfig struct {
	KeyPEM  []byte // contents of the AuthKey_XXXX.p8 file
	KeyID   string
	TeamID  string
	Topic   string // the app's bundle id
	Sandbox bool
	BaseURL string // tests only; defaults from Sandbox
}

type apns struct {
	cfg    APNsConfig
	key    *ecdsa.PrivateKey
	client *http.Client

	mu       sync.Mutex
	jwt      string
	jwtIssue time.Time
}

// NewAPNs parses the signing key. Go's client speaks HTTP/2 to APNs on its own.
func NewAPNs(cfg APNsConfig) (Sender, error) {
	block, _ := pem.Decode(cfg.KeyPEM)
	if block == nil {
		return nil, errors.New("apns: key is not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse key: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns: key is not an EC key")
	}
	if cfg.KeyID == "" || cfg.TeamID == "" || cfg.Topic == "" {
		return nil, errors.New("apns: key id, team id and topic are required")
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.push.apple.com"
		if cfg.Sandbox {
			cfg.BaseURL = "https://api.sandbox.push.apple.com"
		}
	}
	return &apns{cfg: cfg, key: ec, client: &http.Client{Timeout: 15 * time.Second}}, nil
}

// providerToken is reused for up to 50 minutes; Apple rejects older than 60.
func (a *apns) providerToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && time.Since(a.jwtIssue) < 50*time.Minute {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding
	h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.cfg.KeyID})
	now := time.Now()
	c, _ := json.Marshal(map[string]any{"iss": a.cfg.TeamID, "iat": now.Unix()})
	signing := enc.EncodeToString(h) + "." + enc.EncodeToString(c)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt = signing + "." + enc.EncodeToString(sig)
	a.jwtIssue = now
	return a.jwt, nil
}

func (a *apns) Send(ctx context.Context, token string, m Message) error {
	payload := map[string]any{
		"aps": map[string]any{
			"alert": map[string]string{"title": m.Title, "body": m.Body},
			"sound": "default",
		},
	}
	for k, v := range m.Data {
		payload[k] = v
	}
	body, _ := json.Marshal(payload)
	bearer, err := a.providerToken()
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.BaseURL+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", a.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	var e struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&e)
	if resp.StatusCode == http.StatusGone || e.Reason == "BadDeviceToken" || e.Reason == "Unregistered" || e.Reason == "DeviceTokenNotForTopic" {
		return fmt.Errorf("%w (apns %d %s)", ErrUnregistered, resp.StatusCode, e.Reason)
	}
	return fmt.Errorf("apns: %d %s", resp.StatusCode, e.Reason)
}

// --- FCM HTTP v1 ---

// FCMConfig is a Firebase service account key file's contents.
type FCMConfig struct {
	ServiceAccountJSON []byte
	BaseURL            string // tests only; default https://fcm.googleapis.com
}

type fcm struct {
	project string
	base    string
	client  *http.Client
}

// NewFCM signs OAuth tokens with the service account (no Google SDK).
func NewFCM(cfg FCMConfig) (Sender, error) {
	var sa struct {
		ProjectID    string `json:"project_id"`
		ClientEmail  string `json:"client_email"`
		PrivateKey   string `json:"private_key"`
		PrivateKeyID string `json:"private_key_id"`
		TokenURI     string `json:"token_uri"`
	}
	if err := json.Unmarshal(cfg.ServiceAccountJSON, &sa); err != nil {
		return nil, fmt.Errorf("fcm: service account: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("fcm: service account needs project_id, client_email and private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	conf := &jwt.Config{
		Email:        sa.ClientEmail,
		PrivateKey:   []byte(sa.PrivateKey),
		PrivateKeyID: sa.PrivateKeyID,
		TokenURL:     sa.TokenURI,
		Scopes:       []string{"https://www.googleapis.com/auth/firebase.messaging"},
	}
	base := cfg.BaseURL
	if base == "" {
		base = "https://fcm.googleapis.com"
	}
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, &http.Client{Timeout: 15 * time.Second})
	client := oauth2.NewClient(ctx, conf.TokenSource(ctx))
	client.Timeout = 15 * time.Second
	return &fcm{project: sa.ProjectID, base: strings.TrimSuffix(base, "/"), client: client}, nil
}

func (f *fcm) Send(ctx context.Context, token string, m Message) error {
	msg := map[string]any{
		"token":        token,
		"notification": map[string]string{"title": m.Title, "body": m.Body},
		"android":      map[string]any{"priority": "high"},
	}
	if len(m.Data) > 0 {
		msg["data"] = m.Data
	}
	body, _ := json.Marshal(map[string]any{"message": msg})
	url := fmt.Sprintf("%s/v1/projects/%s/messages:send", f.base, f.project)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := f.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(raw, &e)
	unregistered := e.Error.Status == "NOT_FOUND"
	for _, d := range e.Error.Details {
		if d.ErrorCode == "UNREGISTERED" {
			unregistered = true
		}
	}
	if unregistered {
		return fmt.Errorf("%w (fcm %d)", ErrUnregistered, resp.StatusCode)
	}
	return fmt.Errorf("fcm: %d %s", resp.StatusCode, strings.TrimSpace(string(raw)))
}

// --- loading from files ---

// LoadAPNs reads the .p8 key from path.
func LoadAPNs(path string, cfg APNsConfig) (Sender, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg.KeyPEM = b
	return NewAPNs(cfg)
}

// LoadFCM reads the service account JSON from path.
func LoadFCM(path string) (Sender, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return NewFCM(FCMConfig{ServiceAccountJSON: b})
}

