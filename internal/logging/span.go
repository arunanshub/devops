package logging

import (
	"context"
	"log/slog"
	"time"
)

type spanKey struct{}

// spanInfo carries the accumulated span state through a context. base holds
// the inherited attributes without the span path, so nesting never produces
// duplicate "span" keys.
type spanInfo struct {
	base *slog.Logger
	path string
}

func spanFrom(ctx context.Context) spanInfo {
	if info, ok := ctx.Value(spanKey{}).(spanInfo); ok {
		return info
	}
	return spanInfo{base: slog.Default()}
}

// FromContext returns a logger scoped to the innermost Span carried by ctx,
// or slog.Default() when no span is active.
func FromContext(ctx context.Context) *slog.Logger {
	info := spanFrom(ctx)
	if info.path == "" {
		return info.base
	}
	return info.base.With(slog.String("span", info.path))
}

// Span begins a named logical operation, in the spirit of Rust tracing
// spans. It logs entry at debug level and returns a derived context plus an
// end function that logs the operation's duration. The attributes passed
// here — and the dotted span path — are inherited by every log line emitted
// through FromContext(ctx) inside the span, including nested spans.
//
//	ctx, end := logging.Span(ctx, "create-pods", slog.String("node", node))
//	defer end()
func Span(ctx context.Context, name string, args ...any) (context.Context, func()) {
	parent := spanFrom(ctx)

	path := name
	if parent.path != "" {
		path = parent.path + "." + name
	}

	base := parent.base
	if len(args) > 0 {
		base = base.With(args...)
	}

	log := base.With(slog.String("span", path))
	log.DebugContext(ctx, "span started")

	ctx = context.WithValue(ctx, spanKey{}, spanInfo{base: base, path: path})
	start := time.Now()

	return ctx, func() {
		log.DebugContext(ctx, "span finished", slog.Duration("duration", time.Since(start)))
	}
}
