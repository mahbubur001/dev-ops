#!/bin/bash
#
# server-setup-menu.sh — interactive new-server provisioner
# Arrow keys move · SPACE toggles · ENTER runs · ESC cancels
# Mirrors Instructions/new-server-setup-aws-t3-medium.md + PG18 install guide.
#
set -uo pipefail

# ── Colors ────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${B}▶ $*${NC}"; }
ok()   { echo -e "${G}✔ $*${NC}"; }
warn() { echo -e "${Y}⚠ $*${NC}"; }
err()  { echo -e "${R}✘ $*${NC}"; }

# ── Preflight ─────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
if ! command -v whiptail >/dev/null 2>&1; then
  log "Installing whiptail (menu UI)…"
  $SUDO apt-get update -qq && $SUDO apt-get install -y whiptail
fi

# ── Task definitions ──────────────────────────────────────
# tag  "description"  default(ON/OFF)
CHOICES=(
  update     "System update & upgrade (apt)"                    ON
  baseline   "Baseline tooling (git, curl, vim, htop, build…)"  ON
  swap       "8GB swap file (swappiness=10)"                    ON
  ufw        "Firewall — allow 22/80/443, enable UFW"           ON
  fail2ban   "Fail2ban (SSH brute-force protection)"            ON
  autoupdate "Automatic security updates (unattended-upgrades)" ON
  postgres   "PostgreSQL 18 (PGDG repo + server + contrib)"     OFF
  node       "Node.js 24 LTS (NodeSource)"                      OFF
  pnpm       "pnpm (via corepack)"                              OFF
  bun        "Bun runtime (official installer)"                 OFF
  pm2        "PM2 process manager (global npm)"                 OFF
  nginx      "Nginx reverse proxy"                              OFF
  certbot    "Certbot + Nginx plugin (Let's Encrypt SSL)"       OFF
)

SELECTED=$(whiptail --title "Server Setup Menu" \
  --checklist "SPACE = toggle · ↑↓ = move · ENTER = run\n\nSelect what to install/configure:" \
  22 72 12 "${CHOICES[@]}" \
  3>&1 1>&2 2>&3) || { warn "Cancelled."; exit 0; }

# strip quotes whiptail wraps around tags
SELECTED=$(echo "$SELECTED" | tr -d '"')
[[ -z "$SELECTED" ]] && { warn "Nothing selected."; exit 0; }

# ── Task implementations ──────────────────────────────────
do_update() {
  log "Updating system…"
  $SUDO apt-get update && $SUDO DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  ok "System updated."
}

do_baseline() {
  log "Installing baseline tooling…"
  $SUDO apt-get install -y curl wget git vim htop build-essential \
    net-tools unzip ca-certificates gnupg pv
  ok "Baseline tooling installed."
}

do_swap() {
  if swapon --show | grep -q '/swapfile'; then
    warn "Swap already active — skipping."; return
  fi
  log "Creating 8GB swap…"
  $SUDO fallocate -l 8G /swapfile
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile
  $SUDO swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
  $SUDO sysctl -w vm.swappiness=10 >/dev/null
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | $SUDO tee -a /etc/sysctl.conf >/dev/null
  ok "8GB swap active."
}

do_ufw() {
  log "Configuring UFW…"
  $SUDO apt-get install -y ufw
  $SUDO ufw allow OpenSSH
  $SUDO ufw allow 80/tcp
  $SUDO ufw allow 443/tcp
  $SUDO ufw --force enable
  ok "Firewall enabled (22/80/443)."
}

do_fail2ban() {
  log "Installing Fail2ban…"
  $SUDO apt-get install -y fail2ban
  $SUDO systemctl enable --now fail2ban
  ok "Fail2ban running."
}

do_autoupdate() {
  log "Enabling automatic security updates…"
  $SUDO apt-get install -y unattended-upgrades
  $SUDO sh -c 'echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections'
  $SUDO DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades
  ok "Automatic security updates enabled."
}

do_postgres() {
  if command -v psql >/dev/null 2>&1; then warn "psql already installed — skipping repo add."; fi
  log "Adding PGDG repo + installing PostgreSQL 18…"
  $SUDO curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | $SUDO gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
  $SUDO sh -c "echo \"deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list"
  $SUDO apt-get update
  $SUDO apt-get install -y postgresql-18 postgresql-contrib-18
  ok "PostgreSQL 18 installed."
  psql --version 2>/dev/null || true
}

do_node() {
  log "Installing Node.js 24…"
  curl -fsSL https://deb.nodesource.com/setup_24.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
  ok "Node $(node -v) / npm $(npm -v)"
}

do_pnpm() {
  if ! command -v corepack >/dev/null 2>&1; then
    warn "corepack not found — installing Node first."; do_node
  fi
  log "Enabling pnpm via corepack…"
  $SUDO corepack enable
  corepack prepare pnpm@latest --activate
  ok "pnpm $(pnpm -v 2>/dev/null || echo ready)"
}

do_bun() {
  log "Installing Bun…"
  curl -fsSL https://bun.sh/install | bash
  ok "Bun installed (reload shell or 'source ~/.bashrc' to use)."
}

do_pm2() {
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found — installing Node first."; do_node
  fi
  log "Installing PM2…"
  $SUDO npm install -g pm2
  ok "PM2 $(pm2 -v 2>/dev/null || echo installed)"
}

do_nginx() {
  log "Installing Nginx…"
  $SUDO apt-get install -y nginx
  $SUDO systemctl enable --now nginx
  ok "Nginx running."
}

do_certbot() {
  log "Installing Certbot + Nginx plugin…"
  $SUDO apt-get install -y certbot python3-certbot-nginx
  ok "Certbot ready. Issue a cert with: sudo certbot --nginx -d <domain>"
}

# ── Run selected tasks in a sensible order ────────────────
run() { grep -qw "$1" <<<"$SELECTED" && "do_$1"; }

echo
log "Running: $SELECTED"
echo
run update
run baseline
run swap
run ufw
run fail2ban
run autoupdate
run postgres
run node
run pnpm
run bun
run pm2
run nginx
run certbot

echo
ok "All selected tasks complete."
