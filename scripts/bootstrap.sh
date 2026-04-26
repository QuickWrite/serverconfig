#!/usr/bin/env bash

# File stolen and modified from https://git.gamecrash.dev/root/configuration/src/branch/main/scripts/bootstrap.sh

# currently only used on deb 13
set -euo pipefail

SERVICE_USER="infra"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || err "This script must be run as root."


log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

log "Installing essential packages..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    git-lfs \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    unattended-upgrades \
    ufw \
    fail2ban \
    ncdu \
    tmux \
    apache2-utils \
    rsync \
    cron

if ! command -v docker &>/dev/null; then
    log "Installing Docker Engine..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    log "Docker installed: $(docker --version)"
else
    log "Docker already installed: $(docker --version)"
fi

if ! id "$SERVICE_USER" &>/dev/null; then
    log "Creating service user '${SERVICE_USER}'..."
    useradd -r -m -s /bin/bash -G docker "$SERVICE_USER"
else
    log "Service user '${SERVICE_USER}' already exists."
    usermod -aG docker "$SERVICE_USER" 2>/dev/null || true
fi

# create dir structure
log "Creating /srv/ directory structure..."
declare -a SRV_DIRS=(
    
)

for dir in "${SRV_DIRS[@]}"; do
    mkdir -p "$dir"
done

chown -R "$SERVICE_USER":"$SERVICE_USER" /srv/

log "Directory structure created under /srv/"

log "Configuring firewall (UFW)..."
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# HTTP/HTTPS
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# mail ports
ufw allow 25/tcp comment 'SMTP'
ufw allow 465/tcp comment 'SMTPS'
ufw allow 587/tcp comment 'SMTP Submission'
ufw allow 993/tcp comment 'IMAPS'

echo "y" | ufw enable
ufw status verbose

# fail2ban
log "Configuring fail2ban..."
systemctl enable --now fail2ban

# cp custom confs if they exist
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$SCRIPT_DIR/config/fail2ban/jail.local" ]]; then
    cp "$SCRIPT_DIR/config/fail2ban/jail.local" /etc/fail2ban/jail.local
fi
if [[ -d "$SCRIPT_DIR/config/fail2ban/filter.d" ]]; then
    cp "$SCRIPT_DIR/config/fail2ban/filter.d/"* /etc/fail2ban/filter.d/ 2>/dev/null || true
fi
systemctl restart fail2ban

# ssh hardening and stuff
log "Hardening SSH configuration..."
SSHD_CONFIG="/etc/ssh/sshd_config"
# backup original conf
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

declare -A SSH_SETTINGS=(
    ["PermitRootLogin"]="prohibit-password"
    ["PasswordAuthentication"]="no"
    ["X11Forwarding"]="no"
    ["MaxAuthTries"]="3"
    ["AllowAgentForwarding"]="no"
    ["AllowTcpForwarding"]="no"
)

for key in "${!SSH_SETTINGS[@]}"; do
    value="${SSH_SETTINGS[$key]}"
    if grep -q "^${key}" "$SSHD_CONFIG"; then
        sed -i "s/^${key}.*/${key} ${value}/" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
done

systemctl restart sshd

# auto security updates
log "Enabling automatic security updates..."
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# sysctl tweaks
log "Applying sysctl tweaks..."
cat > /etc/sysctl.d/99-infra.conf << 'EOF'
# Allow more connections
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Connection tracking
net.netfilter.nf_conntrack_max = 262144

# Allow IP forwarding (Docker needs this)
net.ipv4.ip_forward = 1

# Reduce swappiness for a server
vm.swappiness = 10

# File descriptors
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1

# create docker net
log "Creating shared Docker network..."
docker network create --subnet=172.20.0.0/24 net 2>/dev/null || log "Network 'net' already exists."

echo ""
log "============================================"
log "  Bootstrap complete!"
log "============================================"
echo ""
