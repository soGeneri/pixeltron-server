package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAPNsSend(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	require.NoError(t, err)
	p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})

	var got struct {
		path, auth, topic, pushType string
		body                        map[string]any
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.path, got.auth = r.URL.Path, r.Header.Get("authorization")
		got.topic, got.pushType = r.Header.Get("apns-topic"), r.Header.Get("apns-push-type")
		_ = json.NewDecoder(r.Body).Decode(&got.body)
		if strings.HasSuffix(r.URL.Path, "/dead") {
			w.WriteHeader(http.StatusGone)
			_, _ = io.WriteString(w, `{"reason":"Unregistered"}`)
		}
	}))
	defer srv.Close()

	s, err := NewAPNs(APNsConfig{KeyPEM: p8, KeyID: "KEY123", TeamID: "TEAM456", Topic: "com.tenthousandpixels.pixels", BaseURL: srv.URL})
	require.NoError(t, err)

	msg := Message{Title: "Kitchen went quiet", Body: "Check it's plugged in.", Data: map[string]string{"device": "pxt-fox42"}}
	require.NoError(t, s.Send(context.Background(), "abc123", msg))
	assert.Equal(t, "/3/device/abc123", got.path)
	assert.Equal(t, "com.tenthousandpixels.pixels", got.topic)
	assert.Equal(t, "alert", got.pushType)
	alert := got.body["aps"].(map[string]any)["alert"].(map[string]any)
	assert.Equal(t, "Kitchen went quiet", alert["title"])
	assert.Equal(t, "pxt-fox42", got.body["device"])

	// The provider token is an ES256 JWT from the team, signed by the key.
	tok := strings.TrimPrefix(got.auth, "bearer ")
	parts := strings.Split(tok, ".")
	require.Len(t, parts, 3)
	var hdr, claims map[string]any
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	require.NoError(t, json.Unmarshal(h, &hdr))
	require.NoError(t, json.Unmarshal(c, &claims))
	assert.Equal(t, "ES256", hdr["alg"])
	assert.Equal(t, "KEY123", hdr["kid"])
	assert.Equal(t, "TEAM456", claims["iss"])
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	require.Len(t, sig, 64)
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	assert.True(t, ecdsa.Verify(&key.PublicKey, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])))

	err = s.Send(context.Background(), "dead", msg)
	assert.True(t, errors.Is(err, ErrUnregistered), err)
}

func TestFCMSend(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	require.NoError(t, err)

	var gotBody map[string]any
	var gotAuth, gotPath string
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "urn:ietf:params:oauth:grant-type:jwt-bearer", r.Form.Get("grant_type"))
		w.Header().Set("content-type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"ya29.test","token_type":"Bearer","expires_in":3600}`)
	})
	mux.HandleFunc("/v1/projects/pixels-test/messages:send", func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("authorization"), r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		msg := gotBody["message"].(map[string]any)
		if msg["token"] == "dead" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"code":404,"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`)
			return
		}
		_, _ = io.WriteString(w, `{"name":"projects/pixels-test/messages/1"}`)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	sa, _ := json.Marshal(map[string]string{
		"type":         "service_account",
		"project_id":   "pixels-test",
		"client_email": "push@pixels-test.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"token_uri":    srv.URL + "/token",
	})
	s, err := NewFCM(FCMConfig{ServiceAccountJSON: sa, BaseURL: srv.URL})
	require.NoError(t, err)

	require.NoError(t, s.Send(context.Background(), "tok-1", Message{Title: "T", Body: "B", Data: map[string]string{"device": "pxt-fox42"}}))
	assert.Equal(t, "Bearer ya29.test", gotAuth)
	assert.Equal(t, "/v1/projects/pixels-test/messages:send", gotPath)
	msg := gotBody["message"].(map[string]any)
	assert.Equal(t, "tok-1", msg["token"])
	assert.Equal(t, "T", msg["notification"].(map[string]any)["title"])
	assert.Equal(t, "pxt-fox42", msg["data"].(map[string]any)["device"])

	err = s.Send(context.Background(), "dead", Message{Title: "T", Body: "B"})
	assert.True(t, errors.Is(err, ErrUnregistered), err)
}

func TestConfigErrors(t *testing.T) {
	_, err := NewAPNs(APNsConfig{KeyPEM: []byte("nope")})
	assert.Error(t, err)
	_, err = NewFCM(FCMConfig{ServiceAccountJSON: []byte(`{}`)})
	assert.Error(t, err)
}
