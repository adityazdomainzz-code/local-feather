#!/usr/bin/env bash
#
# LocalNode automatic installer for Ubuntu (KVM/libvirt)
# Usage:
#   curl -sSL <url>/local.sh | bash
#   OR: bash local.sh [--token SECRET] [--port 8443] [--bridge virbr0]
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*"; exit 1; }

TOKEN=""
PORT=8443
BRIDGE="virbr0"
INSTALL_DIR="/opt/localnode"
CONFIG_DIR="/etc/localnode"
DATA_DIR="/var/lib/localnode"
LOG_DIR="/var/log/localnode"
REPO_URL="${LOCALNODE_REPO:-}"  # optional: path or git url to agent sources

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --port)  PORT="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --repo)  REPO_URL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--token SECRET] [--port 8443] [--bridge virbr0] [--repo PATH|URL]"
      exit 0
      ;;
    *) err "Unknown arg: $1" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo)"
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null && ! grep -qi debian /etc/os-release 2>/dev/null; then
  warn "This installer targets Ubuntu/Debian. Continuing anyway..."
fi

info "Updating apt and installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils \
  virtinst cpu-checker qemu-utils genisoimage \
  python3 python3-pip python3-venv python3-dev \
  libvirt-dev pkg-config gcc \
  curl openssl ca-certificates

info "Checking virtualization / KVM..."
if command -v kvm-ok >/dev/null 2>&1; then
  if kvm-ok 2>/dev/null | grep -qi "KVM acceleration can be used"; then
    info "KVM acceleration available"
  else
    warn "kvm-ok reported issues — VMs may run in software emulation"
  fi
fi

if [[ ! -e /dev/kvm ]]; then
  warn "/dev/kvm not present — ensure nested virtualization is enabled if this is a VM"
fi

info "Enabling libvirtd..."
systemctl enable --now libvirtd
systemctl enable --now virtlogd 2>/dev/null || true

# default network
if ! virsh net-info default >/dev/null 2>&1; then
  info "Defining default libvirt network..."
  virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
fi
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true

# ensure bridge exists (default NAT network uses virbr0)
if [[ "$BRIDGE" == "virbr0" ]]; then
  if ! ip link show virbr0 >/dev/null 2>&1; then
    warn "virbr0 not up yet; default network may still be starting"
  fi
fi

info "Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"/{images,instances,iso,templates} "$LOG_DIR"
mkdir -p "$CONFIG_DIR/tls"

# Install agent sources
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SRC=""
if [[ -d "$SCRIPT_DIR/../agent" ]]; then
  AGENT_SRC="$(cd "$SCRIPT_DIR/../agent" && pwd)"
elif [[ -n "$REPO_URL" && -d "$REPO_URL" ]]; then
  AGENT_SRC="$REPO_URL"
elif [[ -n "$REPO_URL" ]]; then
  info "Cloning agent from $REPO_URL..."
  git clone --depth 1 "$REPO_URL" /tmp/localnode-src
  AGENT_SRC="/tmp/localnode-src/agent"
fi

if [[ -z "$AGENT_SRC" || ! -d "$AGENT_SRC" ]]; then
  # embed minimal structure if running standalone
  info "Using embedded agent layout under $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/api" "$INSTALL_DIR/libvirt" "$INSTALL_DIR/config"
  if [[ -d "$SCRIPT_DIR/../agent" ]]; then
    cp -a "$SCRIPT_DIR/../agent/." "$INSTALL_DIR/"
  else
    err "Agent sources not found. Place this script next to the agent/ directory or pass --repo"
  fi
else
  info "Copying agent from $AGENT_SRC"
  cp -a "$AGENT_SRC/." "$INSTALL_DIR/"
fi

info "Creating Python venv and installing dependencies..."
python3 -m venv "$INSTALL_DIR/venv"
# shellcheck disable=SC1091
source "$INSTALL_DIR/venv/bin/activate"
pip install -q --upgrade pip wheel
if [[ -f "$INSTALL_DIR/requirements.txt" ]]; then
  pip install -q -r "$INSTALL_DIR/requirements.txt" || {
    warn "Full requirements failed; installing core packages"
    pip install -q fastapi uvicorn pydantic pyyaml psutil httpx python-multipart
    pip install -q libvirt-python || warn "libvirt-python failed — install system packages and retry"
  }
else
  pip install -q fastapi uvicorn pydantic pyyaml psutil httpx python-multipart
  pip install -q libvirt-python || warn "libvirt-python failed"
fi
deactivate

# Token
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  info "Generated agent token"
fi

info "Writing config to $CONFIG_DIR/config.yaml"
cat > "$CONFIG_DIR/config.yaml" <<EOF
server:
  host: "0.0.0.0"
  port: ${PORT}
  tls:
    enabled: false
    cert: "${CONFIG_DIR}/tls/cert.pem"
    key: "${CONFIG_DIR}/tls/key.pem"

auth:
  token: "${TOKEN}"
  allowed_ips: []

paths:
  data_dir: "${DATA_DIR}"
  images_dir: "${DATA_DIR}/images"
  instances_dir: "${DATA_DIR}/instances"
  iso_dir: "${DATA_DIR}/iso"
  templates_dir: "${DATA_DIR}/templates"
  logs_dir: "${LOG_DIR}"

libvirt:
  uri: "qemu:///system"
  bridge: "${BRIDGE}"
  storage_pool: "localnode"

limits:
  max_vcpus: 0
  max_memory_mb: 0
  max_disk_gb: 0
  overcommit_cpu: 2.0
  overcommit_memory: 1.2

heartbeat:
  interval_seconds: 30
  panel_url: ""
  panel_token: ""

logging:
  level: "INFO"
  file: "${LOG_DIR}/agent.log"
EOF
chmod 600 "$CONFIG_DIR/config.yaml"

# Systemd unit
info "Installing systemd service..."
cat > /etc/systemd/system/localnode-agent.service <<EOF
[Unit]
Description=LocalNode Agent (FeatherPanel KVM/libvirt VDS host)
After=network-online.target libvirtd.service
Wants=network-online.target
Requires=libvirtd.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
Environment=LOCALNODE_CONFIG=${CONFIG_DIR}/config.yaml
ExecStart=${INSTALL_DIR}/venv/bin/python -m uvicorn api.main:app --host 0.0.0.0 --port ${PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable localnode-agent
systemctl restart localnode-agent

sleep 2
if systemctl is-active --quiet localnode-agent; then
  info "localnode-agent is running"
else
  warn "Service may have failed — check: journalctl -u localnode-agent -n 50"
  systemctl status localnode-agent --no-pager || true
fi

# Firewall hint
if command -v ufw >/dev/null 2>&1; then
  warn "If UFW is active, allow the agent port: ufw allow ${PORT}/tcp"
fi

echo
info "=============================================="
info " LocalNode agent installed"
info "=============================================="
echo
echo "  Agent URL : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}"
echo "  Health    : curl http://127.0.0.1:${PORT}/health"
echo "  Token     : ${TOKEN}"
echo
echo "  In FeatherPanel Admin → VDS → Nodes:"
echo "    Type   : LocalNode"
echo "    FQDN   : <this-server-ip-or-hostname>"
echo "    Port   : ${PORT}"
echo "    Token  : (paste the token above)"
echo
echo "  Config   : ${CONFIG_DIR}/config.yaml"
echo "  Logs     : journalctl -u localnode-agent -f"
echo "  Data     : ${DATA_DIR}"
echo
info "Done."
