#!/bin/bash
set -euo pipefail

mkdir -p /etc/rancher/k3s
# shellcheck disable=SC2154
cat > /etc/rancher/k3s/config.yaml <<EOF
cluster-init: true
disable:
  - traefik
  - servicelb
disable-cloud-controller: true
kubelet-arg:
  - "cloud-provider=external"
node-ip: "${node_private_ip}"
EOF

# install k3s
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION='${k3s_version}' sh -

# wait for the control plane to be ready
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
