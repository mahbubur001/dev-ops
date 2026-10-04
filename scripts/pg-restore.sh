#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
BACKUP_DIR="/var/backups/postgresql"
LOG_FILE="/var/log/pg-backup.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Restore Tool"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-restore.sh -d DATABASE -f BACKUP_FILE"
  echo ""
  echo "Options:"
  echo "  -d    Database name to restore"
  echo "  -f    Backup file name (optional)"
  echo "  -l    List available backups"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  sudo pg-restore.sh"
  echo "  sudo pg-restore.sh -d bikribd -l"
  echo "  sudo pg-restore.sh -d bikribd"
  echo "  sudo pg-restore.sh -d bikribd -f backup_2026-04-16_02-00-00.sql.gz"
}

# ── List backups ──────────────────────────────────────────
list_backups() {
  local DB=$1
  if [ ! -d "$BACKUP_DIR/$DB" ]; then
    echo -e "${RED}❌ No backups found for: $DB${NC}"
    exit 1
  fi
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Available backups for: $DB"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  local i=1
  for FILE in $(ls -t "$BACKUP_DIR/$DB"/*.sql.gz 2>/dev/null); do
    SIZE=$(du -sh "$FILE" | cut -f1)
    FILENAME=$(basename "$FILE")
    echo -e "  ${YELLOW}[$i]${NC} $FILENAME ${GREEN}($SIZE)${NC}"
    i=$((i+1))
  done
  if [ $i -eq 1 ]; then
    echo -e "${RED}  No backup files found!${NC}"
    exit 1
  fi
  echo ""
}

# ── Restore ───────────────────────────────────────────────
restore_database() {
  local DB=$1
  local BACKUP_FILE=$2
  local FULL_PATH="$BACKUP_DIR/$DB/$BACKUP_FILE"

  if [ ! -f "$FULL_PATH" ]; then
    echo -e "${RED}❌ Backup file not found: $FULL_PATH${NC}"
    exit 1
  fi

  echo -e "${YELLOW}⚠️  WARNING: This will overwrite all data in '$DB'!${NC}"
  echo ""
  echo -e "  Database : ${GREEN}$DB${NC}"
  echo -e "  Backup   : ${GREEN}$BACKUP_FILE${NC}"
  echo -e "  Size     : ${GREEN}$(du -sh $FULL_PATH | cut -f1)${NC}"
  echo ""
  read -p "Are you sure? Type 'yes' to confirm: " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}❌ Restore cancelled.${NC}"
    exit 0
  fi

  echo -e "${BLUE}🔄 Starting restore...${NC}"
  echo "[$DATE] 🔄 Restoring $DB from $BACKUP_FILE" >> "$LOG_FILE"

  sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB';" > /dev/null 2>&1
  sudo -u postgres dropdb "$DB" 2>/dev/null
  sudo -u postgres createdb "$DB"

  gunzip -c "$FULL_PATH" | sudo -u postgres psql -d "$DB" > /dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database '$DB' restored successfully!${NC}"
    echo "[$DATE] ✅ $DB restored from $BACKUP_FILE" >> "$LOG_FILE"
  else
    echo -e "${RED}❌ Restore failed!${NC}"
    echo "[$DATE] ❌ $DB restore failed" >> "$LOG_FILE"
    exit 1
  fi
}

# ── Interactive ───────────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Restore Tool"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  echo -e "${YELLOW}Available databases with backups:${NC}"
  echo ""
  local DB_LIST=()
  local i=1
  for DIR in $(ls -d "$BACKUP_DIR"/*/ 2>/dev/null); do
    DB=$(basename "$DIR")
    COUNT=$(ls "$DIR"*.sql.gz 2>/dev/null | wc -l)
    echo -e "  ${YELLOW}[$i]${NC} $DB ${GREEN}($COUNT backups)${NC}"
    DB_LIST+=("$DB")
    i=$((i+1))
  done

  if [ ${#DB_LIST[@]} -eq 0 ]; then
    echo -e "${RED}  No backups found!${NC}"
    exit 1
  fi

  echo ""
  read -p "Enter database name: " DB
  list_backups "$DB"
  read -p "Enter backup filename (Enter for latest): " BACKUP_FILE

  if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR/$DB"/*.sql.gz 2>/dev/null | head -1 | xargs basename)
    echo -e "${YELLOW}Using latest: $BACKUP_FILE${NC}"
  fi

  restore_database "$DB" "$BACKUP_FILE"
}

# ── Parse args ────────────────────────────────────────────
DB=""
BACKUP_FILE=""
LIST_ONLY=false

while getopts "d:f:lh" opt; do
  case $opt in
    d) DB="$OPTARG" ;;
    f) BACKUP_FILE="$OPTARG" ;;
    l) LIST_ONLY=true ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$DB" ] && [ -z "$BACKUP_FILE" ]; then
  interactive_mode
elif [ "$LIST_ONLY" = true ] && [ -n "$DB" ]; then
  list_backups "$DB"
elif [ -n "$DB" ] && [ -z "$BACKUP_FILE" ]; then
  list_backups "$DB"
  echo ""
  read -p "Enter backup filename (Enter for latest): " BACKUP_FILE
  if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR/$DB"/*.sql.gz 2>/dev/null | head -1 | xargs basename)
    echo -e "${YELLOW}Using latest: $BACKUP_FILE${NC}"
  fi
  restore_database "$DB" "$BACKUP_FILE"
elif [ -n "$DB" ] && [ -n "$BACKUP_FILE" ]; then
  restore_database "$DB" "$BACKUP_FILE"
else
  show_help
  exit 1
fi
