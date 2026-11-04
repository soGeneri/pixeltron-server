package server

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Port of pixeltron-firmware components/pixeltron/src/codeword.c. The
// device derives these from its Wi-Fi MAC and shows them on the panel; the
// server derives the same values so ids match what people see.

var codeWords = [32]string{
	"FOX", "OWL", "CAT", "BEE", "ELK", "YAK", "EMU", "APE",
	"BAT", "COD", "DOG", "EEL", "GNU", "HEN", "JAY", "KOI",
	"RAM", "RAY", "BEAR", "CRAB", "CROW", "DEER", "DOVE", "DUCK",
	"FROG", "GOAT", "HARE", "LION", "LYNX", "MOLE", "NEWT", "PUMA",
}

const setupCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func macHash(mac [6]byte, salt uint32) uint32 {
	h := uint32(2166136261) ^ salt
	for _, b := range mac {
		h ^= uint32(b)
		h *= 16777619
	}
	return h
}

// pixeltronCodeWord returns e.g. "FOX-42".
func pixeltronCodeWord(mac [6]byte) string {
	h := macHash(mac, 0x77)
	return fmt.Sprintf("%s-%02d", codeWords[h&31], 10+(h>>5)%90)
}

// pixeltronSetupCode returns the six-character setup code, e.g. "4F2A9K".
func pixeltronSetupCode(mac [6]byte) string {
	h := macHash(mac, 0x5e)
	var b strings.Builder
	for i := range 6 {
		b.WriteByte(setupCodeAlphabet[(h>>(i*5))&31])
	}
	return b.String()
}

// parseMAC accepts "aa:bb:cc:dd:ee:ff", "aa-bb-...", or 12 hex digits.
func parseMAC(s string) ([6]byte, error) {
	var mac [6]byte
	clean := strings.NewReplacer(":", "", "-", "", ".", "").Replace(strings.TrimSpace(s))
	if len(clean) != 12 {
		return mac, fmt.Errorf("invalid MAC %q", s)
	}
	b, err := hex.DecodeString(clean)
	if err != nil {
		return mac, fmt.Errorf("invalid MAC %q", s)
	}
	copy(mac[:], b)
	return mac, nil
}

// pixeltronDeviceID is the server id for a Pixeltron: "pxt-" plus the code
// word, lower case without the dash ("pxt-fox42"), matching the app's mock.
func pixeltronDeviceID(mac [6]byte) string {
	return "pxt-" + strings.ToLower(strings.ReplaceAll(pixeltronCodeWord(mac), "-", ""))
}
