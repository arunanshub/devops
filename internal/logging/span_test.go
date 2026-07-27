package logging

import (
	"bytes"
	"log/slog"
	"testing"

	"github.com/stretchr/testify/assert"
)

func captureDefault(t *testing.T) *bytes.Buffer {
	t.Helper()
	old := slog.Default()
	t.Cleanup(func() { slog.SetDefault(old) })

	var buf bytes.Buffer
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{
		Level: slog.LevelDebug,
	})))
	return &buf
}

func TestSpanComposesPathAndInheritsAttrs(t *testing.T) {
	buf := captureDefault(t)

	ctx, endRoot := Span(t.Context(), "root", slog.String("cluster", "hetzner-k3s"))
	ctx, endChild := Span(ctx, "child")
	FromContext(ctx).InfoContext(ctx, "hello")
	endChild()
	endRoot()

	out := buf.String()
	assert.Contains(t, out, "span started")
	assert.Contains(t, out, "span=root.child")
	assert.Contains(t, out, "cluster=hetzner-k3s")
	assert.Contains(t, out, "msg=hello")
	assert.Contains(t, out, "span finished")
	assert.Contains(t, out, "duration=")
}

func TestFromContextWithoutSpanFallsBackToDefault(t *testing.T) {
	buf := captureDefault(t)

	FromContext(t.Context()).Info("plain")

	out := buf.String()
	assert.Contains(t, out, "msg=plain")
	assert.NotContains(t, out, "span=")
}
