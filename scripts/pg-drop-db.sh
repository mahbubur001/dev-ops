#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/pg-drop-db.log"
BACKUP_DIR="/var/backups/postgresql/pre-drop"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Dropper"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-drop-db.sh -d DATABASE [-r USERNAME] [-n] [-f]"
  echo ""
  echo "Options:"
  echo "  -d    Database name to drop"
  echo "  -r    Also drop this role/user after dropping the database"
  echo "  -n    No backup (skip the safety dump — not recommended)"
  echo "  -f    Force: terminate active connections before dropping"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  # Interactive mode"
  echo "  sudo pg-drop-db.sh"
  echo ""
  echo "  # Drop a database (safety backup taken first)"
  echo "  sudo pg-drop-db.sh -d myapp_staging"
  echo ""
  echo "  # Drop database + its owner, terminating open connections"
  echo "  sudo pg-drop-db.sh -d myapp_staging -r myapp_user -f"
}

# ── Validate input ────────────────────────────────────────
validate_input() {
  local INPUT=$1
  local TYPE=$2

  if [ -z "$INPUT" ]; then
    echo -e "${RED}❌ $TYPE cannot be empty${NC}"
    return 1
  fi

  if [[ ! "$INPUT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}❌ $TYPE can only contain letters, numbers, underscore, and hyphen${NC}"
    return 1
  fi

  return 0
}

# ── Guard against system databases ────────────────────────
is_protected_db() {
  case "$1" in
    postgres|template0|template1) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Check if database exists ──────────────────────────────
check_database_exists() {
  local DB=$1
  sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB"
  return $?
}

# ── Check if user exists ──────────────────────────────────
check_user_exists() {
  local USER=$1
  sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$USER'" 2>/dev/null | grep -q 1
  return $?
}

# ── Drop database (and optionally the role) ───────────────
drop_database_and_user() {
  local DB=$1
  local ROLE=$2
  local NO_BACKUP=$3
  local FORCE=$4

  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Dropping Database"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  if is_protected_db "$DB"; then
    echo -e "${RED}❌ '$DB' is a system database and cannot be dropped${NC}"
    echo "[$DATE] ❌ Refused to drop protected database: $DB" >> "$LOG_FILE"
    exit 1
  fi

  if ! check_database_exists "$DB"; then
    echo -e "${RED}❌ Database '$DB' does not exist${NC}"
    echo "[$DATE] ❌ Drop failed: $DB does not exist" >> "$LOG_FILE"
    exit 1
  fi

  echo -e "  Database : ${RED}$DB${NC}"
  [ -n "$ROLE" ] && echo -e "  Role     : ${RED}$ROLE${NC} (will also be dropped)"
  if [ "$NO_BACKUP" = true ]; then
    echo -e "  Backup   : ${RED}SKIPPED${NC}"
  else
    echo -e "  Backup   : ${GREEN}$BACKUP_DIR/${DB}_${DATE}.sql.gz${NC}"
  fi
  echo ""
  echo -e "${YELLOW}This action is IRREVERSIBLE.${NC}"
  read -p "Type the database name '$DB' to confirm: " CONFIRM

  if [ "$CONFIRM" != "$DB" ]; then
    echo -e "${YELLOW}❌ Name did not match. Drop cancelled.${NC}"
    exit 0
  fi

  # Safety backup
  if [ "$NO_BACKUP" != true ]; then
    echo -e "${BLUE}🔄 Backing up before drop...${NC}"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump "$DB" 2>/dev/null | gzip > "$BACKUP_DIR/${DB}_${DATE}.sql.gz"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
      echo -e "${GREEN}✅ Backup saved: $BACKUP_DIR/${DB}_${DATE}.sql.gz${NC}"
    else
      echo -e "${RED}❌ Backup failed — aborting drop${NC}"
      echo "[$DATE] ❌ Pre-drop backup failed: $DB" >> "$LOG_FILE"
      rm -f "$BACKUP_DIR/${DB}_${DATE}.sql.gz"
      exit 1
    fi
  fi

  # Terminate active connections if forced
  if [ "$FORCE" = true ]; then
    echo -e "${BLUE}🔄 Terminating active connections...${NC}"
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  fi

  echo -e "${BLUE}🔄 Dropping database...${NC}"
  sudo -u postgres psql -c "DROP DATABASE \"$DB\";" 2>/tmp/pg-drop-err
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database '$DB' dropped${NC}"
    echo "[$DATE] ✅ Database dropped: $DB" >> "$LOG_FILE"
  else
    echo -e "${RED}❌ Drop failed:${NC}"
    cat /tmp/pg-drop-err
    if grep -q "being accessed by other users" /tmp/pg-drop-err; then
      echo -e "${YELLOW}💡 Active connections exist. Re-run with -f to terminate them.${NC}"
    fi
    echo "[$DATE] ❌ Drop failed: $DB" >> "$LOG_FILE"
    rm -f /tmp/pg-drop-err
    exit 1
  fi
  rm -f /tmp/pg-drop-err

  # Drop role if requested
  if [ -n "$ROLE" ]; then
    if check_user_exists "$ROLE"; then
      echo -e "${BLUE}🔄 Dropping role '$ROLE'...${NC}"
      sudo -u postgres psql -c "DROP ROLE \"$ROLE\";" 2>/tmp/pg-drop-err
      if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Role '$ROLE' dropped${NC}"
        echo "[$DATE] ✅ Role dropped: $ROLE" >> "$LOG_FILE"
      else
        echo -e "${YELLOW}⚠️  Could not drop role '$ROLE' (it may own objects in other databases):${NC}"
        cat /tmp/pg-drop-err
        echo "[$DATE] ⚠️ Role drop failed: $ROLE" >> "$LOG_FILE"
      fi
      rm -f /tmp/pg-drop-err
    else
      echo -e "${YELLOW}ℹ️  Role '$ROLE' does not exist — nothing to drop${NC}"
    fi
  fi

  echo ""
  echo -e "${GREEN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Done"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  [ "$NO_BACKUP" != true ] && echo -e "  Restore with: ${YELLOW}gunzip -c $BACKUP_DIR/${DB}_${DATE}.sql.gz | sudo -u postgres psql -d NEWDB${NC}"
}

# ── Interactive mode ──────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Dropper"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  while true; do
    read -p "Enter database name to drop: " DB
    if validate_input "$DB" "Database name"; then
      break
    fi
  done

  read -p "Also drop the owning role/user? Enter name (blank to skip): " ROLE
  if [ -n "$ROLE" ] && ! validate_input "$ROLE" "Username"; then
    exit 1
  fi

  read -p "Terminate active connections if needed? (yes/no): " F
  [ "$F" = "yes" ] && FORCE=true || FORCE=false

  drop_database_and_user "$DB" "$ROLE" false "$FORCE"
}

# ── Parse args ────────────────────────────────────────────
DB=""
ROLE=""
NO_BACKUP=false
FORCE=false

while getopts "d:r:nfh" opt; do
  case $opt in
    d) DB="$OPTARG" ;;
    r) ROLE="$OPTARG" ;;
    n) NO_BACKUP=true ;;
    f) FORCE=true ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$DB" ] && [ -z "$ROLE" ]; then
  interactive_mode
elif [ -n "$DB" ]; then
  if ! validate_input "$DB" "Database name"; then exit 1; fi
  if [ -n "$ROLE" ] && ! validate_input "$ROLE" "Username"; then exit 1; fi
  drop_database_and_user "$DB" "$ROLE" "$NO_BACKUP" "$FORCE"
else
  echo -e "${RED}❌ Error: Database (-d) is required${NC}"
  echo ""
  show_help
  exit 1
fi
