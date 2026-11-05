package server

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"tronbyt-server/internal/config"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeIssuer is a minimal OpenID provider: discovery document, JWKS, and a
// way to mint RS256 ID tokens, standing in for Apple or Google.
type fakeIssuer struct {
	srv *httptest.Server
	key *rsa.PrivateKey
}

func newFakeIssuer(t *testing.T) *fakeIssuer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	fi := &fakeIssuer{key: key}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                fi.srv.URL,
			"jwks_uri":                              fi.srv.URL + "/keys",
			"authorization_endpoint":                fi.srv.URL + "/auth",
			"token_endpoint":                        fi.srv.URL + "/token",
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]any{{
			"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "k1",
			"n": b64(key.N.Bytes()),
			"e": b64(big.NewInt(int64(key.E)).Bytes()),
		}}})
	})
	fi.srv = httptest.NewServer(mux)
	t.Cleanup(fi.srv.Close)
	return fi
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// token mints an ID token. Pass a different key to forge one.
func (fi *fakeIssuer) token(t *testing.T, claims map[string]any, signer *rsa.PrivateKey) string {
	t.Helper()
	if signer == nil {
		signer = fi.key
	}
	base := map[string]any{"iss": fi.srv.URL, "iat": time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix()}
	for k, v := range claims {
		base[k] = v
	}
	h, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": "k1", "typ": "JWT"})
	p, _ := json.Marshal(base)
	signing := b64(h) + "." + b64(p)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, signer, crypto.SHA256, sum[:])
	require.NoError(t, err)
	return signing + "." + b64(sig)
}

func TestAppAPIIdentitySignIn(t *testing.T) {
	fi := newFakeIssuer(t)
	old := googleIssuer
	googleIssuer = fi.srv.URL
	t.Cleanup(func() { googleIssuer = old })

	s := newAppTestServer(t, func(c *config.Settings) { c.GoogleClientIDs = "web-client, ios-client" })
	c := &appClient{t: t, s: s}

	signIn := func(tok string) (int, map[string]any) {
		rr := c.do("POST", "/app/v0/auth/google", map[string]any{"id_token": tok})
		return rr.Code, decodeMap(t, rr)
	}

	// A valid token for one of the configured audiences makes an account.
	code, body := signIn(fi.token(t, map[string]any{"sub": "g-123", "aud": "ios-client", "email": "Pat@Example.com", "email_verified": true}, nil))
	require.Equal(t, http.StatusOK, code, body)
	user := body["user"].(map[string]any)
	assert.Equal(t, "google", user["method"])
	assert.Equal(t, "pat@example.com", user["email"])

	// The same subject signs in to the same account, even without an email.
	code, body = signIn(fi.token(t, map[string]any{"sub": "g-123", "aud": "web-client"}, nil))
	require.Equal(t, http.StatusOK, code, body)
	assert.Equal(t, user["id"], body["user"].(map[string]any)["id"])

	// Refreshing keeps the method.
	rr := c.do("POST", "/app/v0/auth/refresh", map[string]any{"refresh_token": body["refresh_token"]})
	require.Equal(t, http.StatusOK, rr.Code)
	assert.Equal(t, "google", decodeMap(t, rr)["user"].(map[string]any)["method"])

	// Rejected: wrong audience, forged signature, expired, wrong issuer.
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	for name, tok := range map[string]string{
		"audience": fi.token(t, map[string]any{"sub": "g-9", "aud": "someone-else"}, nil),
		"forged":   fi.token(t, map[string]any{"sub": "g-9", "aud": "ios-client"}, other),
		"expired":  fi.token(t, map[string]any{"sub": "g-9", "aud": "ios-client", "exp": time.Now().Add(-time.Hour).Unix()}, nil),
		"issuer":   fi.token(t, map[string]any{"sub": "g-9", "aud": "ios-client", "iss": "https://evil.example"}, nil),
	} {
		code, body := signIn(tok)
		assert.Equal(t, http.StatusUnauthorized, code, name)
		assert.Equal(t, "bad_token", body["code"], name)
	}
}

// An existing email account picks up the identity on first sign-in with it.
func TestAppAPIIdentityLinksExistingEmailAccount(t *testing.T) {
	fi := newFakeIssuer(t)
	old := appleIssuer
	appleIssuer = fi.srv.URL
	t.Cleanup(func() { appleIssuer = old })

	s := newAppTestServer(t, func(c *config.Settings) { c.AppleClientIDs = "com.tenthousandpixels.pixels" })
	c := &appClient{t: t, s: s}
	emailUser := c.signUp("sam@example.com")["user"].(map[string]any)

	rr := c.do("POST", "/app/v0/auth/apple", map[string]any{
		"id_token": fi.token(t, map[string]any{"sub": "a-1", "aud": "com.tenthousandpixels.pixels", "email": "sam@example.com", "email_verified": "true"}, nil),
	})
	require.Equal(t, http.StatusOK, rr.Code, rr.Body.String())
	assert.Equal(t, emailUser["id"], decodeMap(t, rr)["user"].(map[string]any)["id"])
}

// Whoever made an email account first can't keep it once the verified owner
// signs in with that email, and an unverified email never links.
func TestAppAPIIdentityTakeoverRules(t *testing.T) {
	fi := newFakeIssuer(t)
	old := googleIssuer
	googleIssuer = fi.srv.URL
	t.Cleanup(func() { googleIssuer = old })
	s := newAppTestServer(t, func(c *config.Settings) { c.GoogleClientIDs = "app" })

	squatter := &appClient{t: t, s: s}
	squatted := squatter.signUp("victim@example.com")["user"].(map[string]any)

	// Unverified email: a separate account, no email on it.
	c := &appClient{t: t, s: s}
	rr := c.do("POST", "/app/v0/auth/google", map[string]any{
		"id_token": fi.token(t, map[string]any{"sub": "g-unverified", "aud": "app", "email": "victim@example.com", "email_verified": false}, nil),
	})
	require.Equal(t, http.StatusOK, rr.Code, rr.Body.String())
	u := decodeMap(t, rr)["user"].(map[string]any)
	assert.NotEqual(t, squatted["id"], u["id"])
	assert.Nil(t, u["email"])

	// Verified owner: takes the account over; the squatter is locked out.
	rr = c.do("POST", "/app/v0/auth/google", map[string]any{
		"id_token": fi.token(t, map[string]any{"sub": "g-owner", "aud": "app", "email": "victim@example.com", "email_verified": true}, nil),
	})
	require.Equal(t, http.StatusOK, rr.Code, rr.Body.String())
	assert.Equal(t, squatted["id"], decodeMap(t, rr)["user"].(map[string]any)["id"])

	assert.Equal(t, http.StatusUnauthorized, squatter.do("GET", "/app/v0/me", nil).Code, "squatter's session ended")
	rr = squatter.do("POST", "/app/v0/auth/email", map[string]any{"email": "victim@example.com", "password": "correct horse"})
	assert.Equal(t, http.StatusUnauthorized, rr.Code, "squatter's password no longer works")
}
