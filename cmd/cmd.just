buildflags := "-s -w"
dir := source_dir()

@verify-mtu2 *flags:
    go run -ldflags="{{ buildflags }}" -trimpath {{ dir }}/verify-mtu {{ flags }}
