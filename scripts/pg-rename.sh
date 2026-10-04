#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/pg-rename.log"
BACKUP_DIR="/var/backups/postgresql/pre-rename"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Renamer"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-rename.sh [-d OLD_DB -D NEW_DB] [-r OLD_ROLE -R NEW_ROLE] [-n] [-f]"
  echo ""
  echo "Options:"
  echo "  -d    Current database name"
  echo "  -D    New database name"
  echo "  -r    Current role/user name"
  echo "  -R    New role/user name"
  echo "  -n    No backup (skip the safety dump before a DB rename)"
  echo "  -f    Force: terminate active connections before renaming the DB"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  # Interactive mode"
  echo "  sudo pg-rename.sh"
  echo ""
  echo "  # Rename a database (safety backup taken first)"
  echo "  sudo pg-rename.sh -d old_app -D new_app"
  echo ""
  echo "  # Rename a role/user"
  echo "  sudo pg-rename.sh -r old_user -R new_user"
  echo ""
  echo "  # Rename both, terminating open connections"
  echo "  sudo pg-rename.sh -d old_app -D new_app -r old_user -R new_user -f"
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

# ── Guard against system databases/roles ──────────────────
is_protected_db() {
  case "$1" in
    postgres|template0|template1) return 0 ;;
    *) return 1 ;;
  esac
}

is_protected_role() {
  case "$1" in
    postgres) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Existence checks ──────────────────────────────────────
check_database_exists() {
  local DB=$1
  sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB"
  return $?
}

check_user_exists() {
  local USER=$1
  sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$USER'" 2>/dev/null | grep -q 1
  return $?
}

# ── Rename a database ─────────────────────────────────────
rename_database() {
  local OLD=$1
  local NEW=$2
  local NO_BACKUP=$3
  local FORCE=$4

  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Renaming Database"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  if is_protected_db "$OLD"; then
    echo -e "${RED}❌ '$OLD' is a system database and cannot be renamed${NC}"
    echo "[$DATE] ❌ Refused to rename protected database: $OLD" >> "$LOG_FILE"
    exit 1
  fi

  if ! check_database_exists "$OLD"; then
    echo -e "${RED}❌ Database '$OLD' does not exist${NC}"
    echo "[$DATE] ❌ Rename failed: $OLD does not exist" >> "$LOG_FILE"
    exit 1
  fi

  if check_database_exists "$NEW"; then
    echo -e "${RED}❌ Target database '$NEW' already exists${NC}"
    echo "[$DATE] ❌ Rename failed: $NEW already exists" >> "$LOG_FILE"
    exit 1
  fi

  echo -e "  Database : ${YELLOW}$OLD${NC} → ${GREEN}$NEW${NC}"
  if [ "$NO_BACKUP" = true ]; then
    echo -e "  Backup   : ${RED}SKIPPED${NC}"
  else
    echo -e "  Backup   : ${GREEN}$BACKUP_DIR/${OLD}_${DATE}.sql.gz${NC}"
  fi
  echo ""
  read -p "Type the current name '$OLD' to confirm: " CONFIRM

  if [ "$CONFIRM" != "$OLD" ]; then
    echo -e "${YELLOW}❌ Name did not match. Rename cancelled.${NC}"
    exit 0
  fi

  # Safety backup
  if [ "$NO_BACKUP" != true ]; then
    echo -e "${BLUE}🔄 Backing up before rename...${NC}"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump "$OLD" 2>/dev/null | gzip > "$BACKUP_DIR/${OLD}_${DATE}.sql.gz"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
      echo -e "${GREEN}✅ Backup saved: $BACKUP_DIR/${OLD}_${DATE}.sql.gz${NC}"
    else
      echo -e "${RED}❌ Backup failed — aborting rename${NC}"
      echo "[$DATE] ❌ Pre-rename backup failed: $OLD" >> "$LOG_FILE"
      rm -f "$BACKUP_DIR/${OLD}_${DATE}.sql.gz"
      exit 1
    fi
  fi

  # Terminate active connections if forced
  if [ "$FORCE" = true ]; then
    echo -e "${BLUE}🔄 Terminating active connections...${NC}"
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$OLD' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  fi

  echo -e "${BLUE}🔄 Renaming database...${NC}"
  sudo -u postgres psql -c "ALTER DATABASE \"$OLD\" RENAME TO \"$NEW\";" 2>/tmp/pg-rename-err
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database renamed: $OLD → $NEW${NC}"
    echo "[$DATE] ✅ Database renamed: $OLD → $NEW" >> "$LOG_FILE"
  else
    echo -e "${RED}❌ Rename failed:${NC}"
    cat /tmp/pg-rename-err
    if grep -q "being accessed by other users" /tmp/pg-rename-err; then
      echo -e "${YELLOW}💡 Active connections exist. Re-run with -f to terminate them.${NC}"
    fi
    echo "[$DATE] ❌ Database rename failed: $OLD → $NEW" >> "$LOG_FILE"
    rm -f /tmp/pg-rename-err
    exit 1
  fi
  rm -f /tmp/pg-rename-err

  # ── Handle the old database's backup folder ─────────────
  # pg-backup.sh stores daily dumps under /var/backups/postgresql/<DB>/.
  # That folder still carries the OLD name — offer to rename or remove it.
  local OLD_BK="/var/backups/postgresql/$OLD"
  local NEW_BK="/var/backups/postgresql/$NEW"
  if [ -d "$OLD_BK" ]; then
    echo ""
    echo -e "${YELLOW}A backup folder still uses the old name:${NC} $OLD_BK"
    echo -e "  ${YELLOW}1${NC}) Rename it to match the new database  (→ $NEW_BK)"
    echo -e "  ${YELLOW}2${NC}) Remove it"
    echo -e "  ${YELLOW}3${NC}) Leave it as is"
    read -p "Select (1/2/3): " BK_CHOICE
    case "$BK_CHOICE" in
      1)
        if [ -d "$NEW_BK" ]; then
          echo -e "${RED}❌ $NEW_BK already exists — old folder left untouched${NC}"
          echo "[$DATE] ⚠️ Backup rename skipped, target exists: $NEW_BK" >> "$LOG_FILE"
        else
          mv "$OLD_BK" "$NEW_BK"
          echo -e "${GREEN}✅ Backup folder renamed → $NEW_BK${NC}"
          echo "[$DATE] ✅ Backup folder renamed: $OLD_BK → $NEW_BK" >> "$LOG_FILE"
        fi
        ;;
      2)
        read -p "Type 'delete' to confirm removing $OLD_BK: " DEL
        if [ "$DEL" = "delete" ]; then
          rm -rf "$OLD_BK"
          echo -e "${GREEN}✅ Backup folder removed: $OLD_BK${NC}"
          echo "[$DATE] ✅ Backup folder removed: $OLD_BK" >> "$LOG_FILE"
        else
          echo -e "${YELLOW}Confirmation failed — backup folder left in place${NC}"
        fi
        ;;
      *)
        echo -e "${YELLOW}Backup folder left in place${NC}"
        ;;
    esac
  fi
}

# ── Rename a role/user ────────────────────────────────────
rename_role() {
  local OLD=$1
  local NEW=$2

  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Renaming Role"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  if is_protected_role "$OLD"; then
    echo -e "${RED}❌ '$OLD' is a system role and cannot be renamed${NC}"
    echo "[$DATE] ❌ Refused to rename protected role: $OLD" >> "$LOG_FILE"
    exit 1
  fi

  if ! check_user_exists "$OLD"; then
    echo -e "${RED}❌ Role '$OLD' does not exist${NC}"
    echo "[$DATE] ❌ Rename failed: role $OLD does not exist" >> "$LOG_FILE"
    exit 1
  fi

  if check_user_exists "$NEW"; then
    echo -e "${RED}❌ Target role '$NEW' already exists${NC}"
    echo "[$DATE] ❌ Rename failed: role $NEW already exists" >> "$LOG_FILE"
    exit 1
  fi

  echo -e "  Role : ${YELLOW}$OLD${NC} → ${GREEN}$NEW${NC}"
  echo ""
  read -p "Type the current role name '$OLD' to confirm: " CONFIRM

  if [ "$CONFIRM" != "$OLD" ]; then
    echo -e "${YELLOW}❌ Name did not match. Rename cancelled.${NC}"
    exit 0
  fi

  echo -e "${BLUE}🔄 Renaming role...${NC}"
  sudo -u postgres psql -c "ALTER ROLE \"$OLD\" RENAME TO \"$NEW\";" 2>/tmp/pg-rename-err
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Role renamed: $OLD → $NEW${NC}"
    echo "[$DATE] ✅ Role renamed: $OLD → $NEW" >> "$LOG_FILE"
    if grep -q "MD5" /tmp/pg-rename-err; then
      echo -e "${YELLOW}⚠️  Warning: MD5-hashed password no longer valid after rename — reset it:${NC}"
      echo -e "     ${YELLOW}sudo -u postgres psql -c \"ALTER ROLE \\\"$NEW\\\" WITH PASSWORD 'new_pass';\"${NC}"
    fi
  else
    echo -e "${RED}❌ Role rename failed:${NC}"
    cat /tmp/pg-rename-err
    echo "[$DATE] ❌ Role rename failed: $OLD → $NEW" >> "$LOG_FILE"
    rm -f /tmp/pg-rename-err
    exit 1
  fi
  rm -f /tmp/pg-rename-err
}

# ── Interactive mode ──────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Renamer"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo -e "  ${YELLOW}1${NC}) Rename a database"
  echo -e "  ${YELLOW}2${NC}) Rename a role/user"
  echo -e "  ${YELLOW}3${NC}) Rename both"
  echo ""
  read -p "Select (1/2/3): " CHOICE

  local DO_DB=false DO_ROLE=false
  case "$CHOICE" in
    1) DO_DB=true ;;
    2) DO_ROLE=true ;;
    3) DO_DB=true; DO_ROLE=true ;;
    *) echo -e "${RED}❌ Invalid choice${NC}"; exit 1 ;;
  esac

  if [ "$DO_DB" = true ]; then
    while true; do
      read -p "Current database name: " OLD_DB
      validate_input "$OLD_DB" "Database name" && break
    done
    while true; do
      read -p "New database name: " NEW_DB
      validate_input "$NEW_DB" "Database name" && break
    done
    read -p "Terminate active connections if needed? (yes/no): " F
    [ "$F" = "yes" ] && FORCE=true || FORCE=false
    rename_database "$OLD_DB" "$NEW_DB" false "$FORCE"
  fi

  if [ "$DO_ROLE" = true ]; then
    while true; do
      read -p "Current role name: " OLD_ROLE
      validate_input "$OLD_ROLE" "Role name" && break
    done
    while true; do
      read -p "New role name: " NEW_ROLE
      validate_input "$NEW_ROLE" "Role name" && break
    done
    rename_role "$OLD_ROLE" "$NEW_ROLE"
  fi
}

# ── Parse args ────────────────────────────────────────────
OLD_DB=""
NEW_DB=""
OLD_ROLE=""
NEW_ROLE=""
NO_BACKUP=false
FORCE=false

while getopts "d:D:r:R:nfh" opt; do
  case $opt in
    d) OLD_DB="$OPTARG" ;;
    D) NEW_DB="$OPTARG" ;;
    r) OLD_ROLE="$OPTARG" ;;
    R) NEW_ROLE="$OPTARG" ;;
    n) NO_BACKUP=true ;;
    f) FORCE=true ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$OLD_DB" ] && [ -z "$NEW_DB" ] && [ -z "$OLD_ROLE" ] && [ -z "$NEW_ROLE" ]; then
  interactive_mode
  exit 0
fi

DID_SOMETHING=false

# Database rename
if [ -n "$OLD_DB" ] || [ -n "$NEW_DB" ]; then
  if [ -z "$OLD_DB" ] || [ -z "$NEW_DB" ]; then
    echo -e "${RED}❌ Both -d (current) and -D (new) are required to rename a database${NC}"
    exit 1
  fi
  validate_input "$OLD_DB" "Database name" || exit 1
  validate_input "$NEW_DB" "Database name" || exit 1
  rename_database "$OLD_DB" "$NEW_DB" "$NO_BACKUP" "$FORCE"
  DID_SOMETHING=true
fi

# Role rename
if [ -n "$OLD_ROLE" ] || [ -n "$NEW_ROLE" ]; then
  if [ -z "$OLD_ROLE" ] || [ -z "$NEW_ROLE" ]; then
    echo -e "${RED}❌ Both -r (current) and -R (new) are required to rename a role${NC}"
    exit 1
  fi
  validate_input "$OLD_ROLE" "Role name" || exit 1
  validate_input "$NEW_ROLE" "Role name" || exit 1
  rename_role "$OLD_ROLE" "$NEW_ROLE"
  DID_SOMETHING=true
fi

if [ "$DID_SOMETHING" != true ]; then
  show_help
  exit 1
fi
