package server

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestPixelIcon(t *testing.T) {
	svg := string(tmplPixelIcon("minus"))
	assert.Contains(t, svg, `width="16" height="16"`, "default scale is 2×")
	// The minus bitmap is two six-pixel runs.
	assert.Equal(t, 2, strings.Count(svg, "<rect"))
	assert.Contains(t, svg, `<rect x="1" y="3" width="6" height="1"/>`)

	assert.Contains(t, string(tmplPixelIcon("plus", 3)), `width="24"`)
	assert.Contains(t, string(tmplPixelIcon("plus", 20)), `width="64"`, "scale is clamped to 8×")
	assert.Empty(t, string(tmplPixelIcon("no-such-icon")))
}
