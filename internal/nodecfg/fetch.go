package nodecfg

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/arunanshub/devops/internal/logging"
)

const downloadTimeout = 5 * time.Minute

// Binaries locates (downloading and caching on first use) the pinned k3s and
// kubelet binaries whose --help output is the validation schema.
type Binaries struct {
	K3s     string
	Kubelet string
}

// EnsureBinaries returns cached binaries for the given k3s version,
// downloading and checksum-verifying them on first use.
func EnsureBinaries(ctx context.Context, cacheDir, k3sVersion string) (Binaries, error) {
	kubeletVersion, err := KubeletVersion(k3sVersion)
	if err != nil {
		return Binaries{}, err
	}

	arch := runtime.GOARCH // release assets exist for amd64 and arm64

	k3sName := "k3s"
	k3sSums := "sha256sum-amd64.txt"
	if arch == "arm64" {
		k3sName = "k3s-arm64"
		k3sSums = "sha256sum-arm64.txt"
	}
	k3sBase := "https://github.com/k3s-io/k3s/releases/download/" + url.PathEscape(k3sVersion)
	k3sPath := filepath.Join(cacheDir, "k3s", k3sVersion, "k3s")
	if err := ensureBinary(
		ctx,
		k3sPath,
		k3sBase+"/"+k3sName,
		k3sBase+"/"+k3sSums,
		k3sName,
	); err != nil {
		return Binaries{}, fmt.Errorf("fetch k3s %s: %w", k3sVersion, err)
	}

	kubeletBase := fmt.Sprintf("https://dl.k8s.io/release/%s/bin/linux/%s", kubeletVersion, arch)
	kubeletPath := filepath.Join(cacheDir, "kubelet", kubeletVersion, "kubelet")
	err = ensureBinary(ctx, kubeletPath, kubeletBase+"/kubelet", kubeletBase+"/kubelet.sha256", "")
	if err != nil {
		return Binaries{}, fmt.Errorf("fetch kubelet %s: %w", kubeletVersion, err)
	}

	return Binaries{K3s: k3sPath, Kubelet: kubeletPath}, nil
}

// HelpText runs a binary with the given args and returns its combined
// output. Help printing needs no privileges and no config.
func HelpText(ctx context.Context, bin string, args ...string) (string, error) {
	// The binary path is our own checksum-verified cache entry and the args
	// are fixed --help invocations.
	cmd := exec.CommandContext(ctx, bin, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("run %s %s: %w", bin, strings.Join(args, " "), err)
	}
	return string(out), nil
}

// ensureBinary downloads url to dest (atomically, mode 0755) unless it
// already exists, verifying the sha256 published alongside the release.
// sumEntry selects the file's line in a multi-file sums list ("" = the sum
// file contains just the hash).
func ensureBinary(ctx context.Context, dest, binURL, sumURL, sumEntry string) error {
	if _, err := os.Stat(dest); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o750); err != nil {
		return err
	}

	logging.FromContext(ctx).InfoContext(ctx, "downloading schema binary", "url", binURL)

	ctx, cancel := context.WithTimeout(ctx, downloadTimeout)
	defer cancel()

	sums, err := fetch(ctx, sumURL)
	if err != nil {
		return fmt.Errorf("fetch checksums: %w", err)
	}
	expected, err := checksumFor(string(sums), sumEntry)
	if err != nil {
		return err
	}

	data, err := fetch(ctx, binURL)
	if err != nil {
		return err
	}

	actual := sha256.Sum256(data)
	if hex.EncodeToString(actual[:]) != expected {
		return fmt.Errorf("checksum mismatch for %s: got %x, want %s", binURL, actual, expected)
	}

	tmp := dest + ".tmp"
	err = os.WriteFile(tmp, data, 0o755) //nolint:gosec // G306: it's an executable
	if err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

func fetch(ctx context.Context, rawURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, http.NoBody)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", rawURL, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

var hexRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// checksumFor extracts the sha256 for entry from a sums listing. With an
// empty entry the content must be a bare hash (dl.k8s.io style); otherwise
// it's `<hash>  <filename>` lines (k3s release style).
func checksumFor(sums, entry string) (string, error) {
	if entry == "" {
		hash := strings.TrimSpace(sums)
		if !hexRe.MatchString(hash) {
			return "", fmt.Errorf("checksum file does not contain a bare sha256: %q", hash)
		}
		return hash, nil
	}

	for line := range strings.SplitSeq(sums, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == entry && hexRe.MatchString(fields[0]) {
			return fields[0], nil
		}
	}
	return "", fmt.Errorf("no checksum entry for %q", entry)
}
