#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

BIN="/usr/local/bin"

# ── Require root ──────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Please run with sudo:${NC} sudo pg-manage.sh"
  exit 1
fi

# ── Status line (shown in the header) ─────────────────────
pg_status() {
  if systemctl is-active --quiet postgresql; then
    echo -e "${GREEN}● running${NC}"
  else
    echo -e "${RED}● stopped${NC}"
  fi
}

# ── Draw the menu ─────────────────────────────────────────
draw_menu() {
  clear
  echo -e "${BLUE}${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║              PostgreSQL Manager              ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Host: ${CYAN}$(hostname -s)${NC}    PostgreSQL: $(pg_status)"
  echo -e "${DIM}  ────────────────────────────────────────────${NC}${BOLD}"
  echo -e "   ${GREEN}1${NC})  Backup a database"
  echo -e "   ${GREEN}2${NC})  Restore a database"
  echo -e "   ${GREEN}3${NC})  Create database + user"
  echo -e "   ${RED}4${NC})  Drop a database"
  echo -e "   ${YELLOW}5${NC})  Rename database / user"
  echo -e "   ${GREEN}6${NC})  Export / download a backup"
  echo -e "   ${CYAN}7${NC})  Health check"
  echo -e "   ${CYAN}8${NC})  Security check"
  echo -e "   ${YELLOW}9${NC})  List databases"
  echo -e "   ${YELLOW}10${NC}) List backups"
  echo -e "   ${DIM}0${NC})  Exit"
  echo -e "${DIM}  ────────────────────────────────────────────${NC}"
}

# ── Run a script and pause ────────────────────────────────
run_and_pause() {
  echo ""
  "$@"
  echo ""
  echo -e "${DIM}── Press Enter to return to the menu ──${NC}"
  read -r
}

# ── Main loop ─────────────────────────────────────────────
while true; do
  draw_menu
  read -p "$(echo -e "${BOLD} Select> ${NC}")" CHOICE

  case "$CHOICE" in
    1) run_and_pause "$BIN/pg-backup.sh" ;;
    2) run_and_pause "$BIN/pg-restore.sh" ;;
    3) run_and_pause "$BIN/pg-create-db.sh" ;;
    4) run_and_pause "$BIN/pg-drop-db.sh" ;;
    5) run_and_pause "$BIN/pg-rename.sh" ;;
    6) run_and_pause "$BIN/pg-export.sh" ;;
    7) run_and_pause "$BIN/health-check.sh" ;;
    8) run_and_pause "$BIN/security-check.sh" ;;
    9) run_and_pause sudo -u postgres psql -c "\l+" ;;
    10) run_and_pause ls -lh /var/backups/postgresql/ ;;
    0) echo -e "${GREEN}Bye 👋${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
  esac
done
