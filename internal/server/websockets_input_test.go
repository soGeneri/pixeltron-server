package server

import (
	"slices"
	"testing"
)

func TestRememberDisplayed(t *testing.T) {
	var h []string
	h = rememberDisplayed(h, "clock")
	h = rememberDisplayed(h, "clock") // repeat ACK for the same app
	h = rememberDisplayed(h, "weather")
	if want := []string{"clock", "weather"}; !slices.Equal(h, want) {
		t.Fatalf("history = %v, want %v", h, want)
	}

	for i := range maxDisplayHistory + 5 {
		h = rememberDisplayed(h, string(rune('a'+i%26))+string(rune('0'+i/26)))
	}
	if len(h) != maxDisplayHistory {
		t.Fatalf("history length = %d, want %d", len(h), maxDisplayHistory)
	}
}
