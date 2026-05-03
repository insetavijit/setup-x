#!/usr/bin/env bash
# =============================================================================
#  setup-ec2-ubuntu.sh — Docker + Docker Compose v2 + Zsh (Oh My Zsh)
#  Target  : Ubuntu 20.04, 22.04, 24.04 on AWS EC2
#  User    : ubuntu (default EC2 Ubuntu user)
#  Usage   : chmod +x setup-ec2-ubuntu.sh && ./setup-ec2-ubuntu.sh
#  Idempotent: safe to run more than once
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { printf "${GREEN}[+]${NC} %s\n"        "$1"; }
info() { printf "${CYAN}[i]${NC} %s\n"          "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n"        "$1"; }
die()  { printf "${RED}[x] ERROR:${NC} %s\n"    "$1" >&2; exit 1; }
step() { printf "\n${CYAN}━━━ %s ━━━${NC}\n"   "$1"; }

# ── Resolve the real user (works under sudo too) ──────────────────────────────
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -z "$REAL_HOME" ] && REAL_HOME="/home/$REAL_USER"

# ── Must NOT be run as root directly (sudo is fine) ──────────────────────────
if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
  die "Run this script as ubuntu, not as root. (sudo will be used internally)"
fi

# ── Verify this is Ubuntu ─────────────────────────────────────────────────────
step "Detecting OS"
if [ ! -f /etc/os-release ]; then
  die "/etc/os-release not found. Cannot detect OS."
fi
# shellcheck source=/dev/null
. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  die "This script is for Ubuntu only. Detected: $ID. Use setup-ec2.sh for Amazon Linux."
fi
log "Ubuntu ${VERSION_ID} (${VERSION_CODENAME}) detected."

# ── 1. Remove any conflicting/unofficial Docker packages ─────────────────────
step "Removing conflicting packages"
CONFLICTS="docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc"
# shellcheck disable=SC2046
INSTALLED=$(dpkg -l $CONFLICTS 2>/dev/null | awk '/^ii/{print $2}' || true)
if [ -n "$INSTALLED" ]; then
  warn "Removing unofficial Docker packages: $INSTALLED"
  # shellcheck disable=SC2086
  sudo apt-get remove -y $INSTALLED
else
  info "No conflicting packages found."
fi

# ── 2. System update + prerequisites ─────────────────────────────────────────
step "System update & prerequisites"
sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release
log "Prerequisites installed."

# ── 3. Docker official apt repository ────────────────────────────────────────
step "Docker"
KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"

if command -v docker &>/dev/null; then
  info "Docker already installed — $(docker --version). Skipping repo setup."
else
  log "Adding Docker's official GPG key..."
  sudo install -m 0755 -d "$KEYRING_DIR"
  curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
    | sudo gpg --dearmor --yes -o "$KEYRING_FILE"
  sudo chmod a+r "$KEYRING_FILE"

  log "Adding Docker apt repository..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING_FILE}] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    | sudo tee "$DOCKER_LIST" > /dev/null

  sudo apt-get update -y

  log "Installing Docker CE + Compose plugin..."
  sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  log "Docker installed."
fi

log "Enabling and starting Docker service..."
sudo systemctl enable --now docker

# Verify daemon is up
for i in 1 2 3 4 5; do
  sudo docker info &>/dev/null && break
  warn "Waiting for Docker daemon... (attempt $i/5)"
  sleep 2
done
sudo docker info &>/dev/null || die "Docker daemon failed to start. Check: sudo systemctl status docker"
log "Docker daemon is running."

# Add real user to the docker group (idempotent)
DOCKER_GROUP_ADDED=false
if id -nG "$REAL_USER" | grep -qw docker; then
  info "$REAL_USER is already in the docker group."
else
  sudo usermod -aG docker "$REAL_USER"
  log "Added $REAL_USER to the docker group."
  DOCKER_GROUP_ADDED=true
fi

# ── Activate docker group in the CURRENT session ──────────────────────────────
# usermod only takes effect on the NEXT login. This block re-executes the
# remainder of the script inside a `newgrp docker` subshell so that all
# subsequent docker/compose calls work immediately — no logout needed.
# SETUP_DOCKER_GROUP_DONE guards against infinite re-exec loops.
if [ "$DOCKER_GROUP_ADDED" = true ] && [ -z "${SETUP_DOCKER_GROUP_DONE:-}" ]; then
  log "Activating docker group in current session (no re-login needed)..."
  export SETUP_DOCKER_GROUP_DONE=1
  SCRIPT_PATH="$(realpath "$0")"
  exec newgrp docker <<NEWGRP_EOF
export SETUP_DOCKER_GROUP_DONE=1
exec bash "$SCRIPT_PATH"
NEWGRP_EOF
fi

# ── 4. Docker Compose v2 legacy symlink ──────────────────────────────────────
step "Docker Compose v2"
COMPOSE_PLUGIN="/usr/libexec/docker/cli-plugins/docker-compose"
# The apt package installs the plugin to a different path on Ubuntu
if [ ! -f "$COMPOSE_PLUGIN" ]; then
  COMPOSE_PLUGIN=$(find /usr -name docker-compose -type f 2>/dev/null | head -1 || true)
fi
COMPOSE_LEGACY="/usr/local/bin/docker-compose"

if sudo docker compose version &>/dev/null; then
  info "Docker Compose plugin active — $(sudo docker compose version)."
else
  die "Docker Compose plugin not found after install. Check Docker CE package."
fi

# Legacy symlink for scripts that still call `docker-compose`
if [ -n "$COMPOSE_PLUGIN" ] && [ -f "$COMPOSE_PLUGIN" ]; then
  sudo ln -sf "$COMPOSE_PLUGIN" "$COMPOSE_LEGACY"
  info "Legacy symlink: /usr/local/bin/docker-compose -> $COMPOSE_PLUGIN"
else
  # Fallback: find where apt placed the compose binary
  APT_COMPOSE=$(dpkg -L docker-compose-plugin 2>/dev/null | grep -m1 'docker-compose$' || true)
  if [ -n "$APT_COMPOSE" ]; then
    sudo ln -sf "$APT_COMPOSE" "$COMPOSE_LEGACY"
    info "Legacy symlink: /usr/local/bin/docker-compose -> $APT_COMPOSE"
  else
    warn "Could not find compose binary path for legacy symlink. 'docker compose' (no hyphen) still works."
  fi
fi

# ── 5. Zsh ────────────────────────────────────────────────────────────────────
step "Zsh"
if command -v zsh &>/dev/null; then
  info "zsh already installed — $(zsh --version). Skipping."
else
  log "Installing zsh and git..."
  sudo apt-get install -y zsh git
  log "zsh installed."
fi

# Change default shell for the real user
CURRENT_SHELL=$(getent passwd "$REAL_USER" | cut -d: -f7)
ZSH_BIN="$(command -v zsh)"
if [ "$CURRENT_SHELL" = "$ZSH_BIN" ]; then
  info "Default shell for $REAL_USER is already zsh."
else
  sudo usermod --shell "$ZSH_BIN" "$REAL_USER"
  log "Default shell for $REAL_USER set to $ZSH_BIN."
fi

# ── 6. Oh My Zsh ─────────────────────────────────────────────────────────────
step "Oh My Zsh"
OMZ_DIR="${REAL_HOME}/.oh-my-zsh"
ZSHRC="${REAL_HOME}/.zshrc"

if [ -d "$OMZ_DIR" ]; then
  info "Oh My Zsh already installed at $OMZ_DIR. Skipping."
else
  log "Installing Oh My Zsh (unattended)..."
  sudo -u "$REAL_USER" env \
    HOME="$REAL_HOME" \
    RUNZSH=no CHSH=no KEEP_ZSHRC=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    || warn "Oh My Zsh installer returned non-zero — continuing anyway."
  log "Oh My Zsh installed."
fi

# ── 7. Zsh plugins ───────────────────────────────────────────────────────────
step "Zsh plugins"
ZSH_CUSTOM="${REAL_HOME}/.oh-my-zsh/custom"

clone_plugin() {
  local name="$1" url="$2" dest="${ZSH_CUSTOM}/plugins/$1"
  if [ -d "$dest/.git" ]; then
    info "Plugin '$name' already present. Pulling latest..."
    sudo -u "$REAL_USER" git -C "$dest" pull --ff-only --quiet || true
  else
    log "Cloning plugin: $name"
    sudo -u "$REAL_USER" git clone --depth=1 "$url" "$dest"
  fi
}

clone_plugin zsh-syntax-highlighting \
  https://github.com/zsh-users/zsh-syntax-highlighting.git

clone_plugin zsh-autosuggestions \
  https://github.com/zsh-users/zsh-autosuggestions.git

# ── 8. Configure .zshrc ───────────────────────────────────────────────────────
step "Configuring .zshrc"

[ -f "$ZSHRC" ] || sudo -u "$REAL_USER" cp "${OMZ_DIR}/templates/zshrc.zsh-template" "$ZSHRC"

PLUGINS="git zsh-syntax-highlighting zsh-autosuggestions docker docker-compose"

if grep -q "zsh-autosuggestions" "$ZSHRC" 2>/dev/null; then
  info ".zshrc already contains plugin config. Skipping."
else
  sudo -u "$REAL_USER" sed -i \
    "s|^plugins=.*|plugins=(${PLUGINS})|" \
    "$ZSHRC"
  log "plugins line updated in .zshrc."
fi

if ! grep -q "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE" "$ZSHRC"; then
  sudo -u "$REAL_USER" tee -a "$ZSHRC" >/dev/null <<'EOF'

# --- zsh-autosuggestions config ---
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=244"
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
EOF
  log "Autosuggestions config appended to .zshrc."
fi

# ── 9. Summary ────────────────────────────────────────────────────────────────
printf "\n"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log " Setup complete! Installed versions:"
log "  Ubuntu         : ${PRETTY_NAME}"
log "  Docker         : $(docker --version 2>/dev/null)"
log "  Docker Compose : $(sudo docker compose version 2>/dev/null)"
log "  Zsh            : $(zsh --version 2>/dev/null)"
log "  Oh My Zsh      : $(cat "${OMZ_DIR}/VERSION" 2>/dev/null || echo 'installed')"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "\n"
warn "Next steps:"
warn "  1. docker group is already active in this session."
warn "     For zsh to become the default shell, log out and back in:"
warn "       logout / ssh back in  (or right now: exec zsh)"
warn "  2. Verify:  docker run --rm hello-world"
warn "  3. Verify:  docker compose version"
printf "\n"
