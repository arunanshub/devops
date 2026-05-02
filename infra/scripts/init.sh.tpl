#!/bin/bash
set -euo pipefail

# install k3s
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION='${k3s_version}' \
    INSTALL_K3S_EXEC='server --cluster-init --disable traefik --disable servicelb' \
    sh -

k3s kubectl wait node --all --for condition=Ready --timeout=5m

# enable hardening
apt-get update -qq
apt-get install -y unattended-upgrades lsb-release

# shellcheck disable=SC2034
DISTRO_ID=$(lsb_release -is)
# shellcheck disable=SC2034
DISTRO_CODENAME=$(lsb_release -cs)

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "$${DISTRO_ID}:$${DISTRO_CODENAME}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
