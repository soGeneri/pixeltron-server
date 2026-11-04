package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"tronbyt-server/internal/auth"
	"tronbyt-server/internal/data"

	"github.com/coreos/go-oidc/v3/oidc"
	"gorm.io/gorm"
)

var appEmailRe = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

var errRegistrationClosed = errors.New("registration closed")

const (
	appleIssuer  = "https://appleid.apple.com"
	googleIssuer = "https://accounts.google.com"
)

type appSignInRequest struct {
	IDToken  string `json:"id_token"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Name     string `json:"name"`
}

// appUserJSON is the app's User shape.
func appUserJSON(u *data.User, method string) map[string]any {
	m := map[string]any{"id": u.Username, "method": method}
	if u.Email != nil {
		m["email"] = *u.Email
	}
	return m
}

// appUserMethod reports how a user signs in, for the "method" field.
func (s *Server) appUserMethod(ctx context.Context, u *data.User) string {
	ident, err := gorm.G[data.OIDCIdentity](s.DB).Where("user_id = ?", u.Username).First(ctx)
	if err == nil {
		switch ident.Issuer {
		case appleIssuer:
			return "apple"
		case googleIssuer:
			return "google"
		}
	}
	return "email"
}

// issueAppSession creates a session and writes the sign-in response.
func (s *Server) issueAppSession(w http.ResponseWriter, r *http.Request, u *data.User, method string) {
	access, err1 := generateSecureToken(32)  // 32 hex chars
	refresh, err2 := generateSecureToken(40) // 40 hex chars
	if err1 != nil || err2 != nil {
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	now := time.Now()
	sess := data.AppSession{
		Username:       u.Username,
		AccessHash:     hashToken(access),
		RefreshHash:    hashToken(refresh),
		AccessExpires:  now.Add(appAccessTTL),
		RefreshExpires: now.Add(appRefreshTTL),
	}
	if err := gorm.G[data.AppSession](s.DB).Create(r.Context(), &sess); err != nil {
		slog.Error("Failed to create app session", "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	writeAppJSON(w, http.StatusOK, map[string]any{
		"token":         access,
		"refresh_token": refresh,
		"expires_in":    int(appAccessTTL.Seconds()),
		"user":          appUserJSON(u, method),
	})
}

// handleAppSignIn handles POST /auth/{apple|google|email}. Email signs in or
// creates the account in one step, like the app's flow expects.
func (s *Server) handleAppSignIn(w http.ResponseWriter, r *http.Request) {
	method := r.PathValue("method")
	var req appSignInRequest
	if err := decodeAppJSON(r, &req); err != nil {
		writeAppError(w, http.StatusBadRequest, "Invalid request.", "bad_request")
		return
	}

	var (
		user *data.User
		err  error
	)
	switch method {
	case "email":
		user, err = s.appEmailSignIn(w, r, req)
		if user == nil && err == nil {
			return // response already written
		}
	case "apple", "google":
		if strings.TrimSpace(req.IDToken) == "" {
			writeAppError(w, http.StatusBadRequest, "Missing identity token.", "no_token")
			return
		}
		user, err = s.appIdentitySignIn(w, r, method, req)
		if user == nil && err == nil {
			return
		}
	default:
		writeAppError(w, http.StatusNotFound, "unknown method", "")
		return
	}
	if errors.Is(err, errRegistrationClosed) {
		writeAppError(w, http.StatusForbidden, "New accounts aren't open on this server.", "registration_closed")
		return
	}
	if err != nil {
		slog.Error("App sign-in failed", "method", method, "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	s.issueAppSession(w, r, user, method)
}

func (s *Server) appEmailSignIn(w http.ResponseWriter, r *http.Request, req appSignInRequest) (*data.User, error) {
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if !appEmailRe.MatchString(email) {
		writeAppError(w, http.StatusBadRequest, "That email doesn't look right.", "bad_email")
		return nil, nil
	}
	if len(req.Password) < 8 {
		writeAppError(w, http.StatusBadRequest, "Passwords need at least 8 characters.", "weak_password")
		return nil, nil
	}

	existing, err := gorm.G[data.User](s.DB).Where("LOWER(email) = ?", email).First(r.Context())
	if err == nil {
		ok, legacy, verr := auth.VerifyPassword(existing.Password, req.Password)
		if verr != nil || !ok {
			writeAppError(w, http.StatusUnauthorized, "That password doesn't match.", "wrong_password")
			return nil, nil
		}
		if legacy {
			if h, herr := auth.HashPassword(req.Password); herr == nil {
				_, _ = gorm.G[data.User](s.DB).Where("username = ?", existing.Username).Update(r.Context(), "password", h)
			}
		}
		return &existing, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	hashed, err := auth.HashPassword(req.Password)
	if err != nil {
		return nil, err
	}
	return s.createAppUser(r.Context(), email, hashed)
}

// createAppUser makes a new account with a generated username.
func (s *Server) createAppUser(ctx context.Context, email, passwordHash string) (*data.User, error) {
	count, err := gorm.G[data.User](s.DB).Count(ctx, "*")
	if err != nil {
		return nil, err
	}
	if count > 0 && s.Config != nil {
		if !s.Config.EnableUserRegistration {
			return nil, errRegistrationClosed
		}
		if s.Config.MaxUsers > 0 && count >= int64(s.Config.MaxUsers) {
			return nil, errRegistrationClosed
		}
	}
	suffix, err := generateSecureToken(12)
	if err != nil {
		return nil, err
	}
	apiKey, err := generateSecureToken(32)
	if err != nil {
		return nil, err
	}
	u := data.User{
		Username: "u-" + suffix,
		Password: passwordHash,
		APIKey:   apiKey,
		IsAdmin:  count == 0,
	}
	if email != "" {
		u.Email = &email
	}
	if err := gorm.G[data.User](s.DB).Create(ctx, &u); err != nil {
		return nil, err
	}
	return &u, nil
}

// --- Apple / Google ---

type appIDVerifier struct {
	mu        sync.Mutex
	providers map[string]*oidc.Provider
}

var appIDVerifiers = &appIDVerifier{providers: map[string]*oidc.Provider{}}

func (v *appIDVerifier) provider(ctx context.Context, issuer string) (*oidc.Provider, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if p, ok := v.providers[issuer]; ok {
		return p, nil
	}
	p, err := oidc.NewProvider(context.WithoutCancel(ctx), issuer)
	if err != nil {
		return nil, err
	}
	v.providers[issuer] = p
	return p, nil
}

func splitList(s string) []string {
	var out []string
	for part := range strings.SplitSeq(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func (s *Server) appIdentitySignIn(w http.ResponseWriter, r *http.Request, method string, req appSignInRequest) (*data.User, error) {
	issuer, audiences := appleIssuer, ""
	if s.Config != nil {
		audiences = s.Config.AppleClientIDs
	}
	if method == "google" {
		issuer = googleIssuer
		if s.Config != nil {
			audiences = s.Config.GoogleClientIDs
		}
	}
	allowed := splitList(audiences)
	if len(allowed) == 0 {
		writeAppError(w, http.StatusNotImplemented, fmt.Sprintf("Sign in with %s isn't set up on this server.", strings.ToUpper(method[:1])+method[1:]), "method_disabled")
		return nil, nil
	}

	provider, err := appIDVerifiers.provider(r.Context(), issuer)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery for %s: %w", issuer, err)
	}
	tok, err := provider.Verifier(&oidc.Config{SkipClientIDCheck: true}).Verify(r.Context(), req.IDToken)
	if err != nil || !slices.ContainsFunc(tok.Audience, func(a string) bool { return slices.Contains(allowed, a) }) {
		writeAppError(w, http.StatusUnauthorized, "We couldn't confirm that sign-in. Try again.", "bad_token")
		return nil, nil
	}
	var claims struct {
		Email string `json:"email"`
	}
	_ = tok.Claims(&claims)
	email := strings.ToLower(claims.Email)

	ctx := r.Context()
	ident, err := gorm.G[data.OIDCIdentity](s.DB).Where("issuer = ? AND subject = ?", issuer, tok.Subject).First(ctx)
	if err == nil {
		u, err := gorm.G[data.User](s.DB).Where("username = ?", ident.UserID).First(ctx)
		if err != nil {
			return nil, err
		}
		return &u, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	// First sign-in with this identity: link to an account with the same
	// (provider-verified) email, or make a new one.
	var user *data.User
	if email != "" {
		if u, err := gorm.G[data.User](s.DB).Where("LOWER(email) = ?", email).First(ctx); err == nil {
			user = &u
		}
	}
	if user == nil {
		if user, err = s.createAppUser(ctx, email, ""); err != nil {
			return nil, err
		}
	}
	var emailPtr *string
	if email != "" {
		emailPtr = &email
	}
	link := data.OIDCIdentity{UserID: user.Username, Subject: tok.Subject, Issuer: issuer, Email: emailPtr}
	if err := gorm.G[data.OIDCIdentity](s.DB).Create(ctx, &link); err != nil {
		return nil, err
	}
	return user, nil
}

// --- session endpoints ---

func (s *Server) handleAppRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := decodeAppJSON(r, &req); err != nil || req.RefreshToken == "" {
		writeAppError(w, http.StatusUnauthorized, "Please sign in again.", "refresh_invalid")
		return
	}
	ctx := r.Context()
	sess, err := gorm.G[data.AppSession](s.DB).
		Where("refresh_hash = ? AND refresh_expires > ?", hashToken(req.RefreshToken), time.Now()).
		First(ctx)
	if err != nil {
		writeAppError(w, http.StatusUnauthorized, "Please sign in again.", "refresh_invalid")
		return
	}
	// Single use: the old pair is gone whether or not the new one is issued.
	n, err := gorm.G[data.AppSession](s.DB).Where("id = ?", sess.ID).Delete(ctx)
	if err != nil || n == 0 {
		writeAppError(w, http.StatusUnauthorized, "Please sign in again.", "refresh_invalid")
		return
	}
	user, err := gorm.G[data.User](s.DB).Where("username = ?", sess.Username).First(ctx)
	if err != nil {
		writeAppError(w, http.StatusUnauthorized, "Please sign in again.", "refresh_invalid")
		return
	}
	s.issueAppSession(w, r, &user, s.appUserMethod(ctx, &user))
}

func (s *Server) handleAppLogout(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	if _, err := gorm.G[data.AppSession](s.DB).Where("username = ?", user.Username).Delete(r.Context()); err != nil {
		slog.Error("Failed to delete app sessions", "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAppMe(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	writeAppJSON(w, http.StatusOK, appUserJSON(user, s.appUserMethod(r.Context(), user)))
}

func (s *Server) handleAppPushToken(w http.ResponseWriter, r *http.Request) {
	user := GetUser(r)
	var req struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if err := decodeAppJSON(r, &req); err != nil || strings.TrimSpace(req.Token) == "" {
		writeAppError(w, http.StatusBadRequest, "Missing push token.", "bad_request")
		return
	}
	ctx := r.Context()
	existing, err := gorm.G[data.PushToken](s.DB).Where("token = ?", req.Token).First(ctx)
	if err == nil {
		_, err = gorm.G[data.PushToken](s.DB).Where("id = ?", existing.ID).
			Updates(ctx, data.PushToken{Username: user.Username, Platform: req.Platform})
	} else if errors.Is(err, gorm.ErrRecordNotFound) {
		err = gorm.G[data.PushToken](s.DB).Create(ctx, &data.PushToken{Username: user.Username, Token: req.Token, Platform: req.Platform})
	}
	if err != nil {
		slog.Error("Failed to save push token", "error", err)
		writeAppError(w, http.StatusInternalServerError, "Something went wrong.", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
