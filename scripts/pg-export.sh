#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
BACKUP_DIR="/var/backups/postgresql"
LOG_FILE="/var/log/pg-export.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Land the file in the REAL user's home (not root's), so it's downloadable without sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"
EXPORT_DIR="${PG_EXPORT_DIR:-$REAL_HOME/downloads}"

# ── Auto-detect the address you connected to ──────────────
# SSH_CONNECTION = "<client_ip> <client_port> <server_ip> <server_port>".
# server_ip is exactly what your client reached (private IP, VPN, or Tailscale
# name all work) — the perfect scp target. sudo strips this var, but since we
# run as root we can read it back from the login shell up the process tree.
find_ssh_connection() {
  [ -n "$SSH_CONNECTION" ] && { echo "$SSH_CONNECTION"; return; }
  local pid=$PPID depth=0 val
  while [ "${pid:-0}" -gt 1 ] && [ "$depth" -lt 8 ]; do
    val=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p')
    [ -n "$val" ] && { echo "$val"; return; }
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
    depth=$((depth+1))
  done
}
SSH_CONN=$(find_ssh_connection)
DET_HOST=$(echo "$SSH_CONN" | awk '{print $3}')
DET_PORT=$(echo "$SSH_CONN" | awk '{print $4}')

# Download hint uses the SAME user + host you SSH in with (no public IP needed).
# Override any of these via env if you go through an alias / jump host.
SSH_USER="${PG_EXPORT_SSH_USER:-$REAL_USER}"
SSH_HOST="${PG_EXPORT_SSH_HOST:-${DET_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
SSH_PORT="${PG_EXPORT_SSH_PORT:-${DET_PORT:-22}}"

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Backup Exporter"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-export.sh [-m existing|new] [-d DB] [-f FILE] [-o OUTDIR]"
  echo ""
  echo "Options:"
  echo "  -m    Mode: existing | new"
  echo "  -d    Database name"
  echo "  -f    Backup filename (existing mode; blank = latest)"
  echo "  -o    Output dir (default $EXPORT_DIR)"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  # Interactive"
  echo "  sudo pg-export.sh"
  echo ""
  echo "  # Copy the latest existing backup of 'bikribd' to ~/downloads"
  echo "  sudo pg-export.sh -m existing -d bikribd"
  echo ""
  echo "  # Make a fresh dump of 'bikribd' into ~/downloads"
  echo "  sudo pg-export.sh -m new -d bikribd"
}

# ── Pick from a list (items on stdin) ─────────────────────
pick_from() {
  local PROMPT=$1
  local -a ITEMS=()
  while IFS= read -r line; do [ -n "$line" ] && ITEMS+=("$line"); done
  if [ ${#ITEMS[@]} -eq 0 ]; then
    echo -e "${RED}❌ Nothing to choose from${NC}" >&2
    return 1
  fi
  local i=1
  for it in "${ITEMS[@]}"; do
    echo -e "  ${YELLOW}[$i]${NC} $(basename "$it")" >&2
    i=$((i+1))
  done
  local SEL
  read -p "$PROMPT " SEL </dev/tty
  if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt ${#ITEMS[@]} ]; then
    echo -e "${RED}❌ Invalid selection${NC}" >&2
    return 1
  fi
  echo "${ITEMS[$((SEL-1))]}"
}

# ── Finalize: chown to the real user + print download hint ─
finish() {
  local OUT=$1
  chown "$REAL_USER":"$REAL_USER" "$OUT" 2>/dev/null
  local SIZE=$(du -h "$OUT" | cut -f1)
  echo -e "${GREEN}✅ Ready: $OUT ($SIZE)${NC}"
  echo "[$DATE] ✅ Exported: $OUT ($SIZE)" >> "$LOG_FILE"
  local FNAME=$(basename "$OUT")
  local RELDIR=${EXPORT_DIR#"$REAL_HOME/"}   # path relative to home for the scp hint
  echo ""
  echo -e "${CYAN}Download it from your Mac — use the SAME user + host you SSH in with:${NC}"
  echo -e "  scp -P $SSH_PORT ${SSH_USER}@${SSH_HOST:-<your-ssh-host>}:$RELDIR/$FNAME ."
  echo ""
  echo -e "${YELLOW}If you connect via an SSH config alias, VPN, Tailscale, or jump host,${NC}"
  echo -e "${YELLOW}use that instead — no public IP required. Examples:${NC}"
  echo -e "  ${YELLOW}# using your ~/.ssh/config alias (e.g. 'Host hetzner')${NC}"
  echo -e "  scp hetzner:$RELDIR/$FNAME ."
  echo -e "  ${YELLOW}# via a jump/bastion host${NC}"
  echo -e "  scp -J bastion ${SSH_USER}@${SSH_HOST:-<internal-host>}:$RELDIR/$FNAME ."
}

# ── Export an existing backup file ────────────────────────
export_existing() {
  local DB=$1
  local FILE=$2

  if [ -z "$DB" ]; then
    echo -e "${CYAN}Databases with backups:${NC}"
    DB=$(ls -1 "$BACKUP_DIR" 2>/dev/null | pick_from "Select database number:") || exit 1
    DB=$(basename "$DB")
  fi

  local SRC
  if [ -n "$FILE" ]; then
    SRC="$BACKUP_DIR/$DB/$FILE"
  else
    echo -e "${CYAN}Backups for '$DB' (newest first):${NC}"
    SRC=$(ls -1t "$BACKUP_DIR/$DB"/*.sql.gz 2>/dev/null | pick_from "Select backup number:") || exit 1
  fi

  if [ ! -f "$SRC" ]; then
    echo -e "${RED}❌ Backup file not found: $SRC${NC}"
    exit 1
  fi

  mkdir -p "$EXPORT_DIR"
  local OUT="$EXPORT_DIR/$(basename "$SRC")"
  echo -e "${BLUE}🔄 Copying to $EXPORT_DIR ...${NC}"
  cp "$SRC" "$OUT" || { echo -e "${RED}❌ Copy failed${NC}"; exit 1; }
  finish "$OUT"
}

# ── Create a fresh dump ───────────────────────────────────
export_new() {
  local DB=$1

  if [ -z "$DB" ]; then
    echo -e "${CYAN}Live databases:${NC}"
    local DBS
    DBS=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres';" 2>/dev/null | tr -d ' ' | grep -v '^$')
    DB=$(echo "$DBS" | pick_from "Select database number:") || exit 1
  fi

  mkdir -p "$EXPORT_DIR"
  local OUT="$EXPORT_DIR/${DB}_${DATE}.sql.gz"
  echo -e "${BLUE}🔄 Dumping '$DB' → $OUT ...${NC}"
  sudo -u postgres pg_dump "$DB" 2>/dev/null | gzip > "$OUT"
  if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$OUT" ]; then
    finish "$OUT"
  else
    echo -e "${RED}❌ Dump failed (does '$DB' exist?)${NC}"
    rm -f "$OUT"
    exit 1
  fi
}

# ── Interactive mode ──────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Backup Exporter"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo -e "  Export dir: ${CYAN}$EXPORT_DIR${NC}"
  echo ""
  echo -e "  ${YELLOW}1${NC}) Copy an existing backup file"
  echo -e "  ${YELLOW}2${NC}) Create a new dump"
  echo ""
  read -p "Select (1/2): " CHOICE </dev/tty
  case "$CHOICE" in
    1) export_existing "" "" ;;
    2) export_new "" ;;
    *) echo -e "${RED}❌ Invalid choice${NC}"; exit 1 ;;
  esac
}

# ── Parse args ────────────────────────────────────────────
MODE=""
DB=""
FILE=""

while getopts "m:d:f:o:h" opt; do
  case $opt in
    m) MODE="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    f) FILE="$OPTARG" ;;
    o) EXPORT_DIR="$OPTARG" ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$MODE" ]; then
  interactive_mode
  exit 0
fi

case "$MODE" in
  existing) export_existing "$DB" "$FILE" ;;
  new)      export_new "$DB" ;;
  *) echo -e "${RED}❌ Invalid mode: $MODE (use existing|new)${NC}"; exit 1 ;;
esac
