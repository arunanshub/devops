package mtu

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLinkMTU(t *testing.T) {
	tests := []struct {
		name    string
		out     string
		want    int
		wantErr bool
	}{
		{
			name: "pod eth0",
			out:  "2: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue qlen 1000",
			want: 1450,
		},
		{
			name: "cilium_wg0",
			out:  "3: cilium_wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1355 qdisc noqueue state UNKNOWN",
			want: 1355,
		},
		{
			name:    "device missing",
			out:     "ip: can't find device 'eth0'",
			wantErr: true,
		},
		{
			name:    "empty output",
			out:     "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := linkMTU(tt.out)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestPacketLossPercent(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want int
	}{
		{
			name: "no loss",
			out:  "3 packets transmitted, 3 packets received, 0% packet loss",
			want: 0,
		},
		{
			name: "full loss",
			out:  "3 packets transmitted, 0 packets received, 100% packet loss",
			want: 100,
		},
		{
			name: "partial loss",
			out:  "3 packets transmitted, 2 packets received, 33% packet loss",
			want: 33,
		},
		{
			name: "unparseable counts as full loss",
			out:  "ping: sendto: Network unreachable",
			want: 100,
		},
		{
			name: "empty counts as full loss",
			out:  "",
			want: 100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, packetLossPercent(tt.out))
		})
	}
}

func TestMinQuicClientMTU(t *testing.T) {
	tests := []struct {
		name      string
		metrics   string
		want      int
		wantFound bool
	}{
		{
			name: "single sample",
			metrics: `# HELP quic_client_mtu QUIC path MTU
quic_client_mtu{conn_index="0"} 1344
`,
			want:      1344,
			wantFound: true,
		},
		{
			name: "multiple samples returns minimum",
			metrics: `quic_client_mtu{conn_index="0"} 1344
quic_client_mtu{conn_index="1"} 1310
quic_client_mtu{conn_index="2"} 1400
`,
			want:      1310,
			wantFound: true,
		},
		{
			name: "float sample truncated",
			metrics: `quic_client_mtu{conn_index="0"} 1344.0
`,
			want:      1344,
			wantFound: true,
		},
		{
			name:      "no samples",
			metrics:   "# only comments here\nsome_other_metric 42\n",
			wantFound: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, found := minQuicClientMTU(tt.metrics)
			assert.Equal(t, tt.wantFound, found)
			if tt.wantFound {
				assert.Equal(t, tt.want, got)
			}
		})
	}
}
