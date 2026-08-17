package mtu

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	linkMTURe    = regexp.MustCompile(`\bmtu (\d+)\b`)
	packetLossRe = regexp.MustCompile(`(\d+)% packet loss`)
)

// linkMTU extracts the MTU from `ip link show <dev>` output.
func linkMTU(out string) (int, error) {
	m := linkMTURe.FindStringSubmatch(out)
	if m == nil {
		return 0, fmt.Errorf("no MTU in link output %q", strings.TrimSpace(out))
	}

	mtu, err := strconv.Atoi(m[1])
	if err != nil {
		return 0, fmt.Errorf("parse MTU %q: %w", m[1], err)
	}
	return mtu, nil
}

// packetLossPercent extracts the packet-loss percentage from ping output.
// Unparseable output counts as full loss, matching the shell implementation
// this replaced.
func packetLossPercent(out string) int {
	m := packetLossRe.FindStringSubmatch(out)
	if m == nil {
		return 100
	}

	loss, err := strconv.Atoi(m[1])
	if err != nil {
		return 100
	}
	return loss
}
