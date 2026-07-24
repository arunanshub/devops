package mtu

import (
	"bufio"
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

// minQuicClientMTU scans Prometheus metrics text for quic_client_mtu samples
// and returns the smallest value. found is false when no sample is present.
func minQuicClientMTU(metrics string) (minMTU int, found bool) {
	scanner := bufio.NewScanner(strings.NewReader(metrics))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "quic_client_mtu{") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}

		value, err := strconv.ParseFloat(fields[len(fields)-1], 64)
		if err != nil {
			continue
		}

		if mtu := int(value); !found || mtu < minMTU {
			minMTU = mtu
			found = true
		}
	}
	return minMTU, found
}
