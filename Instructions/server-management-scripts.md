[← Back to Home](../README.md)

# Server Management Scripts
> Hetzner Server: `87.99.130.89` | Ubuntu 24 | 4 vCPU / 16GB RAM

---

## Quick Setup

```bash
# Create all eight scripts
sudo vim /usr/local/bin/pg-backup.sh
sudo vim /usr/local/bin/pg-restore.sh
sudo vim /usr/local/bin/pg-create-db.sh
sudo vim /usr/local/bin/pg-drop-db.sh
sudo vim /usr/local/bin/pg-rename.sh
sudo vim /usr/local/bin/pg-export.sh
sudo vim /usr/local/bin/health-check.sh
sudo vim /usr/local/bin/security-check.sh

# Optional: one launcher menu for all scripts
sudo vim /usr/local/bin/pg-manage.sh

# Make all executable (one command)
sudo chmod +x /usr/local/bin/{pg-backup,pg-restore,pg-create-db,pg-drop-db,pg-rename,pg-export,health-check,security-check,pg-manage}.sh
```

---

## Bulk Deploy (no copy-paste)

Instead of pasting each script by hand, extract them all from this guide into real `.sh` files and push them to the server in one shot.

**1. Extract** — run this from the repo root; it reads every `**Location:**` marker below and writes the following ` ```bash ` block to `server-scripts/`:

```bash
python3 - <<'PY'
import re, pathlib
src = pathlib.Path("Instructions/server-management-scripts.md").read_text().splitlines()
out = pathlib.Path("server-scripts"); out.mkdir(exist_ok=True)
loc = re.compile(r'\*\*Location:\*\* `/usr/local/bin/([^`]+)`')
i = 0
while i < len(src):
    m = loc.search(src[i])
    if m:
        name = m.group(1)
        while i < len(src) and not src[i].startswith("```bash"): i += 1
        i += 1
        body = []
        while i < len(src) and not src[i].startswith("```"):
            body.append(src[i]); i += 1
        (out / name).write_text("\n".join(body) + "\n")
        print(f"  {name}")
    i += 1
PY
```

**2. Push + install** — copies to the server home, then moves into `/usr/local/bin/` with the executable bit set (one `install` call):

```bash
# Hetzner (key already in ssh-agent / ssh config)
scp server-scripts/*.sh deploy@87.99.130.89:~/
ssh deploy@87.99.130.89 'sudo install -m 755 ~/*.sh /usr/local/bin/ && rm ~/*.sh && ls -l /usr/local/bin/*.sh'

# AWS (pass the .pem explicitly with -i on both commands)
scp -i /path/to/your-key.pem server-scripts/*.sh deploy@34.229.145.66:~/
ssh -i /path/to/your-key.pem deploy@34.229.145.66 'sudo install -m 755 ~/*.sh /usr/local/bin/ && rm ~/*.sh && ls -l /usr/local/bin/*.sh'
```

The `-i /path/to/your-key.pem` flag goes right after `scp`/`ssh`, before the source and host (e.g. `~/.ssh/aws-bikribd.pem`). Omit it when the key is already loaded in your ssh-agent.

---

## 1. pg-backup.sh — Daily Database Backup

**Location:** `/usr/local/bin/pg-backup.sh`

```bash
#!/bin/bash

# ── Config ────────────────────────────────────────────────
BACKUP_DIR="/var/backups/postgresql"
RETENTION_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="/var/log/pg-backup.log"

# ── System databases to skip ──────────────────────────────
EXCLUDE_DBS="template0 template1 postgres"

# ── Get all databases automatically ──────────────────────
DATABASES=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" | tr -d ' ' | grep -v '^$')

echo "" >> "$LOG_FILE"
echo "[$DATE] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
echo "[$DATE] 🚀 Starting PostgreSQL backup..." >> "$LOG_FILE"
echo "[$DATE] 📋 Found databases: $(echo $DATABASES | tr '\n' ' ')" >> "$LOG_FILE"

# ── Backup each database ──────────────────────────────────
for DB in $DATABASES; do
  if echo "$EXCLUDE_DBS" | grep -qw "$DB"; then
    echo "[$DATE] ⏭️  Skipping system db: $DB" >> "$LOG_FILE"
    continue
  fi

  # Skip databases ending with _shadow or _test
  if [[ "$DB" =~ _shadow$ ]] || [[ "$DB" =~ _test$ ]]; then
    echo "[$DATE] ⏭️  Skipping excluded db: $DB (matches pattern)" >> "$LOG_FILE"
    continue
  fi

  mkdir -p "$BACKUP_DIR/$DB"
  echo "[$DATE] 📦 Backing up: $DB" >> "$LOG_FILE"

  sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_DIR/$DB/backup_$DATE.sql.gz"

  if [ $? -eq 0 ]; then
    SIZE=$(du -sh "$BACKUP_DIR/$DB/backup_$DATE.sql.gz" | cut -f1)
    echo "[$DATE] ✅ $DB → backup_$DATE.sql.gz ($SIZE)" >> "$LOG_FILE"
  else
    echo "[$DATE] ❌ $DB backup failed!" >> "$LOG_FILE"
  fi

  find "$BACKUP_DIR/$DB" -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
done

echo "[$DATE] 🗑️  Old backups cleaned (>$RETENTION_DAYS days)" >> "$LOG_FILE"
echo "[$DATE] ✅ All backups completed!" >> "$LOG_FILE"
echo "[$DATE] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
```

### Usage

```bash
# Run manually
sudo pg-backup.sh

# Check logs
cat /var/log/pg-backup.log

# List backups
ls -lh /var/backups/postgresql/
```

### Add to Cron (Daily at 2 AM)

```bash
sudo crontab -e
```

Add:
```
0 2 * * * /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1
```

---

## 2. pg-restore.sh — Database Restore Tool

**Location:** `/usr/local/bin/pg-restore.sh`

```bash
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
```

### Usage

```bash
# Interactive mode
sudo pg-restore.sh

# List backups for database
sudo pg-restore.sh -d bikribd -l

# Restore latest backup
sudo pg-restore.sh -d bikribd

# Restore specific date
sudo pg-restore.sh -d bikribd -f backup_2026-04-16_02-00-00.sql.gz
```

---

## 3. pg-create-db.sh — Database & User Creation Tool

**Location:** `/usr/local/bin/pg-create-db.sh`

```bash
#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/pg-create-db.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Creator"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-create-db.sh -d DATABASE -u USERNAME [-p PASSWORD] [-e]"
  echo ""
  echo "Options:"
  echo "  -d    Database name to create"
  echo "  -u    Username (create new or use existing)"
  echo "  -p    Password for NEW user (required if user doesn't exist)"
  echo "  -e    Use existing user (skip user creation)"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  # Interactive mode"
  echo "  sudo pg-create-db.sh"
  echo ""
  echo "  # Create new database + new user"
  echo "  sudo pg-create-db.sh -d myapp_db -u myapp_user -p SecurePass123"
  echo ""
  echo "  # Create database with existing user"
  echo "  sudo pg-create-db.sh -d myapp_staging -u myapp_user -e"
}

# ── Validate input ────────────────────────────────────────
validate_input() {
  local INPUT=$1
  local TYPE=$2

  # Check for empty
  if [ -z "$INPUT" ]; then
    echo -e "${RED}❌ $TYPE cannot be empty${NC}"
    return 1
  fi

  # Check for valid characters (alphanumeric, underscore, hyphen)
  if [[ ! "$INPUT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}❌ $TYPE can only contain letters, numbers, underscore, and hyphen${NC}"
    return 1
  fi

  return 0
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

# ── Create database and user ──────────────────────────────
create_database_and_user() {
  local DB=$1
  local USER=$2
  local PASS=$3
  local USE_EXISTING=$4

  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Creating Database & User"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  # Check if database already exists
  if check_database_exists "$DB"; then
    echo -e "${RED}❌ Database '$DB' already exists!${NC}"
    echo "[$DATE] ❌ Database creation failed: $DB already exists" >> "$LOG_FILE"
    exit 1
  fi

  local USER_EXISTS=false
  if check_user_exists "$USER"; then
    USER_EXISTS=true
    if [ "$USE_EXISTING" = true ]; then
      echo -e "${GREEN}✅ Using existing user: $USER${NC}"
    else
      echo -e "${RED}❌ User '$USER' already exists! Use -e flag to use existing user.${NC}"
      echo "[$DATE] ❌ User creation failed: $USER already exists" >> "$LOG_FILE"
      exit 1
    fi
  else
    if [ "$USE_EXISTING" = true ]; then
      echo -e "${RED}❌ User '$USER' does not exist! Remove -e flag to create new user.${NC}"
      exit 1
    fi
    if [ -z "$PASS" ]; then
      echo -e "${RED}❌ Password required for new user creation${NC}"
      exit 1
    fi
  fi

  echo -e "  Database : ${GREEN}$DB${NC}"
  echo -e "  User     : ${GREEN}$USER${NC}"
  if [ "$USER_EXISTS" = true ]; then
    echo -e "  Mode     : ${YELLOW}Using existing user${NC}"
  else
    echo -e "  Password : ${GREEN}${PASS:0:3}***${NC}"
    echo -e "  Mode     : ${YELLOW}Creating new user${NC}"
  fi
  echo ""
  read -p "Proceed with creation? Type 'yes' to confirm: " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}❌ Creation cancelled.${NC}"
    exit 0
  fi

  # Create user if needed
  if [ "$USER_EXISTS" = false ]; then
    echo -e "${BLUE}🔄 Creating user...${NC}"
    sudo -u postgres psql -c "CREATE USER \"$USER\" WITH PASSWORD '$PASS';" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ User '$USER' created successfully${NC}"
    else
      echo -e "${RED}❌ User creation failed${NC}"
      echo "[$DATE] ❌ User creation failed: $USER" >> "$LOG_FILE"
      exit 1
    fi
  fi

  echo -e "${BLUE}🔄 Creating database...${NC}"

  # Create database with owner
  sudo -u postgres psql -c "CREATE DATABASE \"$DB\" OWNER \"$USER\";" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database '$DB' created successfully${NC}"
  else
    echo -e "${RED}❌ Database creation failed${NC}"
    echo "[$DATE] ❌ Database creation failed: $DB" >> "$LOG_FILE"
    # Rollback: drop the user if we just created it and database creation failed
    if [ "$USER_EXISTS" = false ]; then
      sudo -u postgres psql -c "DROP USER \"$USER\";" 2>/dev/null
    fi
    exit 1
  fi

  echo -e "${BLUE}🔄 Granting privileges...${NC}"

  # Grant database-level privileges
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB\" TO \"$USER\";" 2>/dev/null

  # Grant schema-level privileges (critical for table creation)
  sudo -u postgres psql -d "$DB" <<EOF 2>/dev/null
ALTER SCHEMA public OWNER TO "$USER";
GRANT ALL ON SCHEMA public TO "$USER";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$USER";
EOF

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ All privileges granted (database, schema, tables, sequences)${NC}"
  else
    echo -e "${YELLOW}⚠️  Some privileges grant warning (database still created)${NC}"
  fi

  echo ""
  echo -e "${GREEN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo -e "  Database : ${GREEN}$DB${NC}"
  echo -e "  User     : ${GREEN}$USER${NC}"
  if [ "$USER_EXISTS" = false ]; then
    echo -e "  Password : ${GREEN}$PASS${NC}"
    echo ""
    echo -e "${YELLOW}Connection string:${NC}"
    echo -e "  postgresql://$USER:$PASS@localhost:5432/$DB"
    echo ""
    echo -e "${YELLOW}Test connection:${NC}"
    echo -e "  PGPASSWORD='$PASS' psql -U $USER -d $DB -h localhost"
  else
    echo ""
    echo -e "${YELLOW}Connection string:${NC}"
    echo -e "  postgresql://$USER:<password>@localhost:5432/$DB"
    echo ""
    echo -e "${YELLOW}Test connection:${NC}"
    echo -e "  PGPASSWORD='<password>' psql -U $USER -d $DB -h localhost"
  fi
  echo ""

  if [ "$USER_EXISTS" = true ]; then
    echo "[$DATE] ✅ Database created with existing user: $DB / $USER" >> "$LOG_FILE"
  else
    echo "[$DATE] ✅ Database and user created: $DB / $USER" >> "$LOG_FILE"
  fi
}

# ── Interactive mode ──────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Creator"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  # Get database name
  while true; do
    read -p "Enter database name: " DB
    if validate_input "$DB" "Database name"; then
      break
    fi
  done

  # Get username
  while true; do
    read -p "Enter username: " USER
    if validate_input "$USER" "Username"; then
      break
    fi
  done

  # Check if user exists
  local USE_EXISTING=false
  if check_user_exists "$USER"; then
    echo -e "${YELLOW}ℹ️  User '$USER' already exists${NC}"
    read -p "Use existing user? (yes/no): " USE_EXISTING_INPUT
    if [ "$USE_EXISTING_INPUT" = "yes" ]; then
      USE_EXISTING=true
      PASS=""
    else
      echo -e "${RED}❌ Please choose a different username${NC}"
      exit 1
    fi
  fi

  # Get password only if creating new user
  if [ "$USE_EXISTING" = false ]; then
    while true; do
      read -s -p "Enter password: " PASS
      echo ""
      if [ -z "$PASS" ]; then
        echo -e "${RED}❌ Password cannot be empty${NC}"
        continue
      fi
      if [ ${#PASS} -lt 8 ]; then
        echo -e "${YELLOW}⚠️  Warning: Password is less than 8 characters${NC}"
        read -p "Continue anyway? (yes/no): " CONTINUE
        if [ "$CONTINUE" != "yes" ]; then
          continue
        fi
      fi
      break
    done
  fi

  create_database_and_user "$DB" "$USER" "$PASS" "$USE_EXISTING"
}

# ── Parse args ────────────────────────────────────────────
DB=""
USER=""
PASS=""
USE_EXISTING=false

while getopts "d:u:p:eh" opt; do
  case $opt in
    d) DB="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    e) USE_EXISTING=true ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$DB" ] && [ -z "$USER" ] && [ -z "$PASS" ]; then
  interactive_mode
elif [ -n "$DB" ] && [ -n "$USER" ]; then
  if ! validate_input "$DB" "Database name"; then exit 1; fi
  if ! validate_input "$USER" "Username"; then exit 1; fi

  # Validate password requirement
  if [ "$USE_EXISTING" = false ] && [ -z "$PASS" ]; then
    echo -e "${RED}❌ Error: Password (-p) required when creating new user${NC}"
    echo -e "${YELLOW}💡 Use -e flag to use existing user without password${NC}"
    echo ""
    show_help
    exit 1
  fi

  create_database_and_user "$DB" "$USER" "$PASS" "$USE_EXISTING"
else
  echo -e "${RED}❌ Error: Database (-d) and user (-u) are required${NC}"
  echo ""
  show_help
  exit 1
fi
```

### Usage

```bash
# Interactive mode (recommended)
sudo pg-create-db.sh

# Create new database + new user
sudo pg-create-db.sh -d myapp_db -u myapp_user -p SecurePassword123

# Create database with existing user
sudo pg-create-db.sh -d myapp_staging -u myapp_user -e

# Example: Multiple databases for same user
sudo pg-create-db.sh -d bikri_production -u bikri_user -p MyP@ssw0rd
sudo pg-create-db.sh -d bikri_staging -u bikri_user -e
sudo pg-create-db.sh -d bikri_dev -u bikri_user -e

# Test the connection
PGPASSWORD='MyP@ssw0rd' psql -U bikri_user -d bikri_production -h localhost
PGPASSWORD='MyP@ssw0rd' psql -U bikri_user -d bikri_staging -h localhost
```

### Features

- ✅ Interactive mode with prompts
- ✅ Create new database + new user
- ✅ Create database with existing user (`-e` flag)
- ✅ Input validation (alphanumeric, underscore, hyphen only)
- ✅ Checks if database/user already exists
- ✅ Password length warning (< 8 characters)
- ✅ Automatic privilege granting (schema, tables, sequences, default privileges)
- ✅ Rollback on failure
- ✅ Connection string output
- ✅ Logging to `/var/log/pg-create-db.log`

### What it does

1. Validates database name, username, password
2. Checks if database already exists
3. Checks if user exists:
   - If `-e` flag: uses existing user (no password needed)
   - Otherwise: creates new user with password
4. Creates database with user as owner
5. Grants comprehensive privileges:
   - Database-level: `GRANT ALL PRIVILEGES ON DATABASE`
   - Schema ownership: `ALTER SCHEMA public OWNER TO user`
   - Current objects: tables, sequences
   - Future objects: default privileges for tables and sequences
6. Provides connection string for testing

---

## 4. pg-drop-db.sh — Database & User Deletion Tool

**Location:** `/usr/local/bin/pg-drop-db.sh`

> ⚠️ **Destructive.** Dropping a database is irreversible. The script forces a safety backup by default and requires you to type the database name to confirm.

```bash
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
```

### Usage

```bash
# Interactive mode (recommended)
sudo pg-drop-db.sh

# Drop a database — safety backup taken automatically
sudo pg-drop-db.sh -d myapp_staging

# Drop database + its owner role, terminating open connections
sudo pg-drop-db.sh -d myapp_staging -r myapp_user -f

# Drop without a backup (fast, unsafe)
sudo pg-drop-db.sh -d myapp_dev -n
```

### Features

- ✅ Interactive and flag-based modes
- ✅ Forces a compressed safety backup to `/var/backups/postgresql/pre-drop/` (skip with `-n`)
- ✅ Requires typing the exact database name to confirm
- ✅ Refuses to drop system databases (`postgres`, `template0`, `template1`)
- ✅ `-f` terminates active connections (fixes "database is being accessed by other users")
- ✅ Optional owner-role cleanup with `-r`
- ✅ Aborts the drop if the safety backup fails
- ✅ Logging to `/var/log/pg-drop-db.log`

### What it does

1. Validates the database name and guards against system databases
2. Confirms the database exists
3. Requires you to retype the database name
4. Takes a compressed `pg_dump` backup (unless `-n`) — aborts if it fails
5. Optionally terminates active connections (`-f`)
6. Runs `DROP DATABASE`
7. Optionally drops the owning role (`-r`)
8. Prints the restore command for the safety backup

---

## 5. pg-rename.sh — Database & User Rename Tool

**Location:** `/usr/local/bin/pg-rename.sh`

> ⚠️ Renaming a database requires **no active connections** (use `-f` to terminate them). Update every app connection string, `.env`, `.pgpass`, and cron/backup config that references the old name — nothing else follows the rename automatically.

```bash
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
```

### Usage

```bash
# Interactive mode (recommended)
sudo pg-rename.sh

# Rename a database — safety backup taken automatically
sudo pg-rename.sh -d old_app -D new_app

# Rename a database with open connections
sudo pg-rename.sh -d old_app -D new_app -f

# Rename a role/user
sudo pg-rename.sh -r old_user -R new_user

# Rename both database and role in one run
sudo pg-rename.sh -d old_app -D new_app -r old_user -R new_user -f
```

### Features

- ✅ Interactive and flag-based modes
- ✅ Renames a database (`ALTER DATABASE … RENAME TO …`) and/or a role (`ALTER ROLE … RENAME TO …`)
- ✅ Forces a compressed safety backup to `/var/backups/postgresql/pre-rename/` before a DB rename (skip with `-n`)
- ✅ Requires typing the exact current name to confirm
- ✅ Refuses to rename system databases (`postgres`, `template0`, `template1`) and the `postgres` role
- ✅ Verifies the target name is free before renaming
- ✅ `-f` terminates active connections (fixes "database is being accessed by other users")
- ✅ After a DB rename, offers to **rename or remove the old backup folder** (`/var/backups/postgresql/<DB>/`)
- ✅ Warns to reset the password if a role's MD5 hash breaks on rename
- ✅ Logging to `/var/log/pg-rename.log`

### What it does & the caveats

1. Validates names and guards system databases/roles
2. Confirms the source exists and the target name is free
3. Requires you to retype the current name
4. For a DB rename: takes a compressed `pg_dump` backup (unless `-n`), optionally terminates connections (`-f`), then runs `ALTER DATABASE … RENAME TO …`
5. After a successful DB rename, if `/var/backups/postgresql/<old_db>/` exists, prompts to **rename** it to the new name, **remove** it (type `delete` to confirm), or leave it
6. For a role rename: runs `ALTER ROLE … RENAME TO …`

> **Important caveats**
> - A database **cannot be renamed while anything is connected to it** — including your own app. Use `-f` or stop the app first.
> - PostgreSQL renames the object only. **Update every connection string, `.env`, `.pgpass`, PgBouncer config, and cron/backup reference** that points at the old name.
> - Renaming a role does **not** change its password, but an **MD5**-hashed password (the hash is salted with the username) becomes invalid after a rename — reset it. PostgreSQL 18 defaults to SCRAM, which is unaffected.

---

## 6. pg-export.sh — Export a Backup for Download

**Location:** `/usr/local/bin/pg-export.sh`

> Runs **on the server**. Puts a `.sql.gz` in your home `~/downloads/` (owned by you, not root) so you can `scp`/SFTP it to your Mac. Two modes: copy an **existing** nightly backup, or make a **fresh** dump on demand. It prints the exact `scp` command to run from your laptop.

```bash
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
```

### Usage

```bash
# Interactive (recommended)
sudo pg-export.sh

# Copy the latest existing backup of bikribd → ~/downloads
sudo pg-export.sh -m existing -d bikribd

# Copy a specific backup file
sudo pg-export.sh -m existing -d bikribd -f backup_2026-09-24_02-00-00.sql.gz

# Make a fresh dump → ~/downloads
sudo pg-export.sh -m new -d bikribd

# Custom output directory
sudo pg-export.sh -m new -d bikribd -o /tmp
```

Then, **from your Mac**, run the `scp` line the script prints. It uses the **same user + host you already SSH in with** — no public IP required:

```bash
# whatever you type after `ssh` to reach the server, use the same here:
scp develop@<your-ssh-host>:downloads/bikribd_2026-09-24_14-00-00.sql.gz .

# using an ~/.ssh/config alias instead:
scp hetzner:downloads/bikribd_2026-09-24_14-00-00.sql.gz .

# via a jump/bastion host:
scp -J bastion develop@<internal-host>:downloads/bikribd_2026-09-24_14-00-00.sql.gz .
```

**No public IP?** No problem — the script **auto-detects** the address your SSH client reached (from `SSH_CONNECTION`) and prints the matching `scp` command, even under plain `sudo`. That address is whatever you connected to (private LAN IP, VPN, or Tailscale name), so it's already reachable from your Mac.

Only override if you connect through an **SSH-config alias** or a **jump host** (where the detected internal IP isn't directly reachable):

```bash
# on the server, before running pg-export.sh:
export PG_EXPORT_SSH_USER=develop
export PG_EXPORT_SSH_HOST=hetzner        # your ~/.ssh/config alias
sudo -E pg-export.sh                      # -E keeps your env under sudo
```

### Features

- ✅ Runs on the server; drops the file in `~/downloads/` (or `-o` dir)
- ✅ `chown`s the file to **your** user (`$SUDO_USER`) so you can `scp` it without sudo
- ✅ Two modes: copy an existing nightly backup, or create a fresh dump
- ✅ Interactive pickers for database and backup file
- ✅ Prints the ready-to-paste `scp` download command
- ✅ Logging to `/var/log/pg-export.log`

### What it does

1. Resolves your real (non-sudo) user and home to pick the export dir
2. **Existing mode:** lists DB backup folders, then the `.sql.gz` files (newest first), and copies your pick
3. **New mode:** lists live databases, runs `sudo -u postgres pg_dump <db> | gzip` into the export dir
4. `chown`s the file to you and prints the `scp` command to pull it to your Mac

---

## 7. health-check.sh — Server Health Monitor

**Location:** `/usr/local/bin/health-check.sh`

```bash
#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/health-check.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Helpers ───────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }

print_header() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🏥 Server Health Check"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
}

check_system() {
  echo -e "${BLUE}📊 System Resources${NC}"
  echo "────────────────────────────────────────────"

  CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
  CPU=${CPU%.*}
  if [ "$CPU" -lt 80 ]; then ok "CPU Usage: ${CPU}%"
  elif [ "$CPU" -lt 90 ]; then warn "CPU Usage: ${CPU}% (High)"
  else fail "CPU Usage: ${CPU}% (Critical!)"; fi

  RAM_TOTAL=$(free -m | awk 'NR==2{print $2}')
  RAM_USED=$(free -m | awk 'NR==2{print $3}')
  RAM_PERCENT=$((RAM_USED * 100 / RAM_TOTAL))
  if [ "$RAM_PERCENT" -lt 80 ]; then ok "RAM: ${RAM_USED}MB / ${RAM_TOTAL}MB (${RAM_PERCENT}%)"
  elif [ "$RAM_PERCENT" -lt 90 ]; then warn "RAM: ${RAM_USED}MB / ${RAM_TOTAL}MB (${RAM_PERCENT}%)"
  else fail "RAM: ${RAM_USED}MB / ${RAM_TOTAL}MB (${RAM_PERCENT}%) - Critical!"; fi

  DISK_PERCENT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
  DISK_USED=$(df -h / | awk 'NR==2{print $3}')
  DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
  if [ "$DISK_PERCENT" -lt 80 ]; then ok "Disk: ${DISK_USED} / ${DISK_TOTAL} (${DISK_PERCENT}%)"
  elif [ "$DISK_PERCENT" -lt 90 ]; then warn "Disk: ${DISK_USED} / ${DISK_TOTAL} (${DISK_PERCENT}%)"
  else fail "Disk: ${DISK_USED} / ${DISK_TOTAL} (${DISK_PERCENT}%) - Critical!"; fi

  SWAP_TOTAL=$(free -m | awk 'NR==3{print $2}')
  SWAP_USED=$(free -m | awk 'NR==3{print $3}')
  if [ "$SWAP_TOTAL" -gt 0 ]; then
    SWAP_PERCENT=$((SWAP_USED * 100 / SWAP_TOTAL))
    if [ "$SWAP_PERCENT" -lt 50 ]; then ok "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB (${SWAP_PERCENT}%)"
    else warn "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB (${SWAP_PERCENT}%)"; fi
  else warn "Swap: Not configured"; fi

  info "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
  info "Uptime: $(uptime -p)"
  echo ""
}

check_services() {
  echo -e "${BLUE}🔧 Services${NC}"
  echo "────────────────────────────────────────────"

  if systemctl is-active --quiet nginx; then ok "Nginx: Running"
  else fail "Nginx: Not running!"; fi

  if systemctl is-active --quiet postgresql; then ok "PostgreSQL: Running"
  else fail "PostgreSQL: Not running!"; fi

  if systemctl is-active --quiet redis; then
    REDIS_PING=$(redis-cli ping 2>/dev/null)
    if [ "$REDIS_PING" = "PONG" ]; then ok "Redis: Running (PONG)"
    else warn "Redis: Running but not responding"; fi
  else fail "Redis: Not running!"; fi

  echo ""
}

check_pm2() {
  echo -e "${BLUE}⚡ PM2 Applications${NC}"
  echo "────────────────────────────────────────────"

  PM2_LIST=$(pm2 jlist 2>/dev/null)
  if [ -z "$PM2_LIST" ]; then
    fail "PM2: No processes found!"
    return
  fi

  echo "$PM2_LIST" | python3 -c "
import json, sys
apps = json.load(sys.stdin)
for app in apps:
    name = app['name']
    status = app['pm2_env']['status']
    restarts = app['pm2_env']['restart_time']
    memory = app['monit']['memory'] // 1024 // 1024
    cpu = app['monit']['cpu']
    icon = '✅' if status == 'online' else '❌'
    print(f'  {icon} {name}: {status} | RAM: {memory}MB | CPU: {cpu}% | Restarts: {restarts}')
" 2>/dev/null || pm2 list

  echo ""
}

check_ports() {
  echo -e "${BLUE}🔌 Ports${NC}"
  echo "────────────────────────────────────────────"

  PORTS=(
    "80:Nginx HTTP"
    "443:Nginx HTTPS"
    "5432:PostgreSQL"
    "6379:Redis"
    "4000:Bikribd"
    "4001:DemoRadiusDirectory"
    "4002:DevRadiusDirectory"
  )

  for PORT_INFO in "${PORTS[@]}"; do
    PORT="${PORT_INFO%%:*}"
    NAME="${PORT_INFO##*:}"
    if ss -tlnp | grep -q ":$PORT "; then ok "$NAME (port $PORT)"
    else fail "$NAME (port $PORT) - Not listening!"; fi
  done

  echo ""
}

check_nginx_sites() {
  echo -e "${BLUE}🌐 Nginx Sites${NC}"
  echo "────────────────────────────────────────────"

  SITES=(
    "bikribd.com:4000"
    "demo.radiusdirectory.com:4001"
    "dev.radiusdirectory.com:4002"
  )

  for SITE_INFO in "${SITES[@]}"; do
    DOMAIN="${SITE_INFO%%:*}"
    PORT="${SITE_INFO##*:}"
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:$PORT" 2>/dev/null)
    if [ "$RESPONSE" = "200" ] || [ "$RESPONSE" = "302" ] || [ "$RESPONSE" = "301" ]; then
      ok "$DOMAIN → port $PORT (HTTP $RESPONSE)"
    else
      fail "$DOMAIN → port $PORT (HTTP $RESPONSE)"
    fi
  done

  echo ""
}

check_databases() {
  echo -e "${BLUE}🗄️  Databases${NC}"
  echo "────────────────────────────────────────────"

  DATABASES=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | tr -d ' ' | grep -v '^$')

  for DB in $DATABASES; do
    SIZE=$(sudo -u postgres psql -t -c "SELECT pg_size_pretty(pg_database_size('$DB'));" 2>/dev/null | tr -d ' ')
    ok "$DB ($SIZE)"
  done

  echo ""
}

check_backups() {
  echo -e "${BLUE}💾 Database Backups${NC}"
  echo "────────────────────────────────────────────"

  BACKUP_DIR="/var/backups/postgresql"

  if [ ! -d "$BACKUP_DIR" ]; then
    fail "Backup directory not found: $BACKUP_DIR"
    return
  fi

  for DB_DIR in "$BACKUP_DIR"/*/; do
    DB=$(basename "$DB_DIR")
    LATEST=$(ls -t "$DB_DIR"*.sql.gz 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
      AGE=$(( ($(date +%s) - $(stat -c %Y "$LATEST")) / 3600 ))
      SIZE=$(du -sh "$LATEST" | cut -f1)
      COUNT=$(ls "$DB_DIR"*.sql.gz 2>/dev/null | wc -l)
      if [ "$AGE" -lt 25 ]; then ok "$DB → Latest: ${AGE}h ago ($SIZE) | Total: $COUNT backups"
      else warn "$DB → Latest: ${AGE}h ago - Backup might be overdue!"; fi
    else
      fail "$DB → No backups found!"
    fi
  done

  echo ""
}

check_ssl() {
  echo -e "${BLUE}🔒 SSL Certificates${NC}"
  echo "────────────────────────────────────────────"

  CERTS=("/etc/ssl/certs/radiusdirectory.com.crt")

  for CERT in "${CERTS[@]}"; do
    if [ -f "$CERT" ]; then
      EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
      NOW_EPOCH=$(date +%s)
      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
      if [ "$DAYS_LEFT" -gt 30 ]; then ok "$(basename $CERT): Valid for $DAYS_LEFT days"
      elif [ "$DAYS_LEFT" -gt 7 ]; then warn "$(basename $CERT): Expires in $DAYS_LEFT days!"
      else fail "$(basename $CERT): Expires in $DAYS_LEFT days - URGENT!"; fi
    else
      fail "Certificate not found: $CERT"
    fi
  done

  echo ""
}

# ── Main ──────────────────────────────────────────────────
print_header
check_system
check_services
check_pm2
check_ports
check_nginx_sites
check_databases
check_backups
check_ssl

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Health check completed!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "[$DATE] Health check completed" >> "$LOG_FILE"
```

### Usage

```bash
# Run health check
sudo health-check.sh

# Add to cron (every hour)
# 0 * * * * /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1
```

---

## 8. security-check.sh — Security Monitor with Email Alerts

**Location:** `/usr/local/bin/security-check.sh`

> ⚠️ Update `ALERT_EMAIL` and `RESEND_API_KEY` before running!

```bash
#!/bin/bash

# ──────────────────────────────────────────────────────────
#  Security Check Script — RadiusDirectory AWS
#  Updated version with proper Resend integration
# ──────────────────────────────────────────────────────────

# ── Load secrets from external file (recommended) ────────
# Create /etc/security-check.env with:
#   ALERT_EMAIL=mahbubur001@gmail.com
#   RESEND_API_KEY=re_your_new_key_here
#   RESEND_FROM=security@radiusdirectory.com
if [ -f /etc/security-check.env ]; then
  set -a
  # shellcheck source=/dev/null
  source /etc/security-check.env
  set +a
fi

# ── Config (defaults — override via /etc/security-check.env) ──
ALERT_EMAIL="${ALERT_EMAIL:-mahbubur001@gmail.com}"
RESEND_API_KEY="${RESEND_API_KEY:-}"
RESEND_FROM="${RESEND_FROM:-onboarding@resend.dev}"
SERVER_NAME="${SERVER_NAME:-AWS EC2}"
SERVER_IP="${SERVER_IP:-13.202.89.114}"
LOG_FILE="/var/log/security-check.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)
REPORT_FILE="/tmp/security-report-$DATE.txt"
ALERT=false

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; echo "  [OK] $1" >> "$REPORT_FILE"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; echo "  [ALERT] $1" >> "$REPORT_FILE"; ALERT=true; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; echo "  [WARN] $1" >> "$REPORT_FILE"; }
info() { echo -e "  $1"; echo "  [INFO] $1" >> "$REPORT_FILE"; }

print_header() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🔐 Security Check — $SERVER_NAME"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Security Report — $SERVER_NAME ($SERVER_IP)"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  } >> "$REPORT_FILE"
}

# ── 1. SSH Login Attempts ─────────────────────────────────
check_ssh_failures() {
  echo -e "${BLUE}🔑 SSH Login Attempts${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── SSH Login Attempts ──" >> "$REPORT_FILE"

  FAILED=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Failed password")
  INVALID=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Invalid user")
  ROOT_ATTEMPTS=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Failed password for root")

  info "Failed SSH attempts (24h): $FAILED"
  info "Invalid user attempts (24h): $INVALID"

  if [ "$ROOT_ATTEMPTS" -gt 0 ]; then
    fail "Root login attempts: $ROOT_ATTEMPTS"
  else
    ok "No root login attempts"
  fi

  if [ "$FAILED" -gt 100 ]; then
    fail "High failed SSH attempts: $FAILED (possible brute force!)"
  elif [ "$FAILED" -gt 20 ]; then
    warn "Elevated failed SSH attempts: $FAILED"
  else
    ok "Failed SSH attempts normal: $FAILED"
  fi

  TOP_IPS=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null \
    | grep "Failed password" \
    | awk '{print $(NF-3)}' \
    | sort | uniq -c | sort -rn | head -5)

  if [ -n "$TOP_IPS" ]; then
    echo "$TOP_IPS" | while read -r line; do
      warn "  Attack IP: $line"
    done
  fi
  echo ""
}

# ── 2. Unauthorized Users ─────────────────────────────────
check_users() {
  echo -e "${BLUE}👥 User Accounts${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── User Accounts ──" >> "$REPORT_FILE"

  ALLOWED_USERS="root ubuntu deploy postgres www-data"

  SHELL_USERS=$(grep -E "(/bin/bash|/bin/sh|/bin/zsh)" /etc/passwd | cut -d: -f1)
  for USER in $SHELL_USERS; do
    if echo "$ALLOWED_USERS" | grep -qw "$USER"; then
      ok "User: $USER (authorized)"
    else
      fail "Unknown user with shell: $USER (investigate!)"
    fi
  done

  SUDO_USERS=$(getent group sudo | cut -d: -f4 | tr ',' '\n')
  for USER in $SUDO_USERS; do
    [ -z "$USER" ] && continue
    if echo "$ALLOWED_USERS" | grep -qw "$USER"; then
      ok "Sudo user: $USER (authorized)"
    else
      fail "Unknown sudo user: $USER (investigate!)"
    fi
  done

  EMPTY_PASS=$(sudo awk -F: '($2 == "" ) {print $1}' /etc/shadow 2>/dev/null)
  if [ -n "$EMPTY_PASS" ]; then
    fail "Users with empty password: $EMPTY_PASS"
  else
    ok "No users with empty passwords"
  fi
  echo ""
}

# ── 3. Open Ports ─────────────────────────────────────────
check_ports() {
  echo -e "${BLUE}🔌 Open Ports${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Open Ports ──" >> "$REPORT_FILE"

  # Adjusted to your actual setup: Next.js apps on 3000/3001/5000, Postgres 5432
  ALLOWED_PORTS="22 80 443 3000 3001 5000 5432 6379"

  OPEN_PORTS=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | awk -F: '{print $NF}' | sort -un)

  for PORT in $OPEN_PORTS; do
    if echo "$ALLOWED_PORTS" | grep -qw "$PORT"; then
      ok "Port $PORT (expected)"
    else
      fail "Unexpected open port: $PORT (investigate!)"
    fi
  done
  echo ""
}

# ── 4. Suspicious Processes ───────────────────────────────
check_processes() {
  echo -e "${BLUE}⚙️  Suspicious Processes${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Suspicious Processes ──" >> "$REPORT_FILE"

  MALICIOUS_PROCS="cryptominer xmrig minerd cgminer bfgminer ccminer ncrack hydra masscan nc.traditional"
  FOUND_MALICIOUS=false
  for PROC in $MALICIOUS_PROCS; do
    if pgrep -x "$PROC" > /dev/null 2>&1; then
      fail "Malicious process detected: $PROC (CRITICAL!)"
      FOUND_MALICIOUS=true
    fi
  done
  [ "$FOUND_MALICIOUS" = false ] && ok "No known malicious processes"

  HIGH_CPU=$(ps aux --sort=-%cpu | awk 'NR>1 && $3>80 {print $11, $3"%"}' | head -5)
  if [ -n "$HIGH_CPU" ]; then
    warn "High CPU processes:"
    echo "$HIGH_CPU" | while read -r line; do
      warn "  → $line"
    done
  else
    ok "No suspicious high CPU processes"
  fi

  PROC_COUNT_PS=$(ps aux | wc -l)
  PROC_COUNT_PROC=$(find /proc -maxdepth 1 -regex '/proc/[0-9]+' | wc -l)
  DIFF=$((PROC_COUNT_PROC - PROC_COUNT_PS))
  if [ "$DIFF" -gt 10 ]; then
    fail "Possible hidden processes! (diff: $DIFF)"
  else
    ok "No hidden processes detected"
  fi
  echo ""
}

# ── 5. File Integrity ─────────────────────────────────────
check_file_integrity() {
  echo -e "${BLUE}📁 File Integrity${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── File Integrity ──" >> "$REPORT_FILE"

  MODIFIED=$(find /etc /usr/bin /usr/sbin -newer /etc/passwd -type f 2>/dev/null | head -10)
  if [ -n "$MODIFIED" ]; then
    warn "Recently modified system files:"
    echo "$MODIFIED" | while read -r FILE; do
      warn "  → $FILE"
    done
  else
    ok "No suspicious system file modifications"
  fi

  SUID=$(find / -perm -4000 -type f 2>/dev/null \
    | grep -v -E "(^/usr/bin|^/usr/sbin|^/bin|^/sbin|^/usr/lib)" | head -5)
  if [ -n "$SUID" ]; then
    fail "Suspicious SUID files found:"
    echo "$SUID" | while read -r FILE; do
      fail "  → $FILE"
    done
  else
    ok "No suspicious SUID files"
  fi

  ENV_FILES=$(find /var/www -name ".env" -perm /o+r 2>/dev/null)
  if [ -n "$ENV_FILES" ]; then
    fail ".env files are world-readable:"
    echo "$ENV_FILES" | while read -r FILE; do
      fail "  → $FILE"
    done
  else
    ok ".env files permissions are secure"
  fi
  echo ""
}

# ── 6. Firewall ───────────────────────────────────────────
check_firewall() {
  echo -e "${BLUE}🛡️  Firewall${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Firewall ──" >> "$REPORT_FILE"

  UFW_STATUS=$(sudo ufw status 2>/dev/null | head -1)
  if echo "$UFW_STATUS" | grep -q "active"; then
    ok "UFW is active"
  else
    info "UFW inactive (relying on AWS Security Groups)"
  fi

  if command -v fail2ban-client &>/dev/null; then
    if systemctl is-active --quiet fail2ban; then
      BANNED=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
      ok "Fail2ban active | Banned IPs: ${BANNED:-0}"
    else
      warn "Fail2ban installed but not running"
    fi
  else
    warn "Fail2ban not installed (recommended for SSH protection)"
  fi
  echo ""
}

# ── 7. System Updates ─────────────────────────────────────
check_updates() {
  echo -e "${BLUE}🔄 System Updates${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── System Updates ──" >> "$REPORT_FILE"

  UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
  SECURITY=$(apt list --upgradable 2>/dev/null | grep -ci security)

  if [ "$SECURITY" -gt 0 ]; then
    fail "Security updates available: $SECURITY (apply immediately!)"
  else
    ok "No security updates pending"
  fi

  if [ "$UPDATES" -gt 20 ]; then
    warn "System updates available: $UPDATES"
  elif [ "$UPDATES" -gt 0 ]; then
    info "System updates available: $UPDATES"
  else
    ok "System is up to date"
  fi
  echo ""
}

# ── 8. Nginx Security ─────────────────────────────────────
check_nginx_security() {
  echo -e "${BLUE}🌐 Nginx Security${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Nginx Security ──" >> "$REPORT_FILE"

  if [ -f "/var/log/nginx/error.log" ]; then
    SQL_INJECTION=$(grep -ciE "(select|union|insert|drop|delete|update)" /var/log/nginx/error.log 2>/dev/null)
    if [ "$SQL_INJECTION" -gt 10 ]; then
      warn "Possible SQL injection attempts: $SQL_INJECTION"
    else
      ok "No significant SQL injection attempts"
    fi
  fi

  if [ -f "/var/log/nginx/access.log" ]; then
    ERRORS=$(awk '$9 ~ /^[45]/' /var/log/nginx/access.log 2>/dev/null | wc -l)
    if [ "$ERRORS" -gt 1000 ]; then
      warn "High error rate: $ERRORS 4xx/5xx responses"
    else
      ok "Nginx error rate normal: $ERRORS"
    fi
  fi

  if sudo nginx -T 2>/dev/null | grep -q "deny all"; then
    ok "Nginx denying sensitive file access"
  else
    warn "Check Nginx config for .env and .git protection"
  fi
  echo ""
}

# ── 9. Disk Anomaly ───────────────────────────────────────
check_disk_anomaly() {
  echo -e "${BLUE}💾 Disk Anomaly${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Disk Anomaly ──" >> "$REPORT_FILE"

  # Check overall disk usage
  DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
  if [ "$DISK_USAGE" -gt 90 ]; then
    fail "Disk usage critical: ${DISK_USAGE}% on /"
  elif [ "$DISK_USAGE" -gt 80 ]; then
    warn "Disk usage high: ${DISK_USAGE}% on /"
  else
    ok "Disk usage healthy: ${DISK_USAGE}% on /"
  fi

  LARGE_FILES=$(find /tmp /var/tmp /dev/shm -size +50M -type f 2>/dev/null)
  if [ -n "$LARGE_FILES" ]; then
    fail "Large files in temp directories:"
    echo "$LARGE_FILES" | while read -r FILE; do
      SIZE=$(du -sh "$FILE" 2>/dev/null | cut -f1)
      fail "  → $FILE ($SIZE)"
    done
  else
    ok "No suspicious large files in temp directories"
  fi

  TMP_EXEC=$(find /tmp /var/tmp -type f -executable 2>/dev/null)
  if [ -n "$TMP_EXEC" ]; then
    fail "Executable files in /tmp:"
    echo "$TMP_EXEC" | while read -r FILE; do
      fail "  → $FILE"
    done
  else
    ok "No executables in /tmp"
  fi
  echo ""
}

# ── 10. Cron Jobs ─────────────────────────────────────────
check_cron() {
  echo -e "${BLUE}⏰ Cron Jobs${NC}"
  echo "────────────────────────────────────────────"
  echo "" >> "$REPORT_FILE"
  echo "── Cron Jobs ──" >> "$REPORT_FILE"

  USER_CRON=$(crontab -l 2>/dev/null)
  ROOT_CRON=$(sudo crontab -l 2>/dev/null)
  CRON_D=$(ls /etc/cron.d/ 2>/dev/null)

  TOTAL_LINES=$(echo -e "$USER_CRON\n$ROOT_CRON\n$CRON_D" | grep -cv '^$')
  info "Cron entries found: $TOTAL_LINES"

  SUSPICIOUS=$(echo -e "$USER_CRON\n$ROOT_CRON" \
    | grep -E "(wget|curl|bash|sh|python)" \
    | grep -v "pg-backup\|health-check\|security-check\|bundle-scheduler\|data-pruning\|cron-runner")

  if [ -n "$SUSPICIOUS" ]; then
    fail "Suspicious cron jobs detected:"
    echo "$SUSPICIOUS" | while read -r line; do
      [ -n "$line" ] && fail "  → $line"
    done
  else
    ok "No suspicious cron jobs found"
  fi
  echo ""
}

# ── Send Alert Email ──────────────────────────────────────
send_alert() {
  if [ "$ALERT" != true ]; then
    echo -e "${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ No security issues detected!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    echo "[$DATE] ✅ Security check passed" >> "$LOG_FILE"
    return 0
  fi

  echo -e "${RED}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🚨 SECURITY ALERTS DETECTED!"
  echo "  Sending email to: $ALERT_EMAIL"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  # Prefer Resend (more reliable than sendmail on cloud servers)
  if [ -n "$RESEND_API_KEY" ]; then
    send_via_resend
  elif command -v sendmail &>/dev/null; then
    send_via_sendmail
  else
    echo "  ⚠️  No mail service configured — alert not sent!"
    echo "[$DATE] ⚠️  Mail not sent (no service configured)" >> "$LOG_FILE"
  fi
}

# ── Send via Resend API (recommended) ─────────────────────
send_via_resend() {
  # Build JSON payload safely using jq if available
  if command -v jq &>/dev/null; then
    JSON_PAYLOAD=$(jq -n \
      --arg from "$RESEND_FROM" \
      --arg to "$ALERT_EMAIL" \
      --arg subject "🚨 Security Alert — $SERVER_NAME ($SERVER_IP)" \
      --arg text "$(cat "$REPORT_FILE")" \
      '{from: $from, to: [$to], subject: $subject, text: $text}')
  elif command -v python3 &>/dev/null; then
    JSON_PAYLOAD=$(python3 -c "
import json, sys
with open('$REPORT_FILE') as f:
    body = f.read()
print(json.dumps({
    'from': '$RESEND_FROM',
    'to': ['$ALERT_EMAIL'],
    'subject': '🚨 Security Alert — $SERVER_NAME ($SERVER_IP)',
    'text': body
}))")
  else
    echo "  ⚠️  Neither jq nor python3 found — cannot encode JSON safely"
    echo "  Install jq:  sudo apt install jq -y"
    return 1
  fi

  # Send and capture HTTP code
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://api.resend.com/emails" \
    -H "Authorization: Bearer $RESEND_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✅ Email sent successfully via Resend"
    echo "[$DATE] 🚨 Alert sent via Resend to $ALERT_EMAIL" >> "$LOG_FILE"
  else
    echo "  ❌ Resend failed (HTTP $HTTP_CODE)"
    echo "  Response: $BODY_RESPONSE"
    echo "[$DATE] ❌ Resend failed (HTTP $HTTP_CODE): $BODY_RESPONSE" >> "$LOG_FILE"
  fi
}

# ── Send via sendmail (fallback) ──────────────────────────
send_via_sendmail() {
  {
    echo "To: $ALERT_EMAIL"
    echo "Subject: 🚨 Security Alert — $SERVER_NAME ($SERVER_IP)"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo ""
    echo "Security issues detected on your server!"
    echo ""
    cat "$REPORT_FILE"
    echo ""
    echo "Server: $SERVER_NAME | IP: $SERVER_IP | Time: $(date)"
  } | sendmail "$ALERT_EMAIL"
  echo "  ✅ Email sent via sendmail"
  echo "[$DATE] 🚨 Alert sent via sendmail to $ALERT_EMAIL" >> "$LOG_FILE"
}

# ── Main ──────────────────────────────────────────────────
main() {
  print_header
  check_ssh_failures
  check_users
  check_ports
  check_processes
  check_file_integrity
  check_firewall
  check_updates
  check_nginx_security
  check_disk_anomaly
  check_cron
  send_alert
  rm -f "$REPORT_FILE"
  echo "[$DATE] Security check completed (alert=$ALERT)" >> "$LOG_FILE"
}

main "$@"
```

### What it checks

| Check | Detects |
|-------|---------|
| SSH failures | Brute force attacks |
| Unauthorized users | Unknown accounts |
| Open ports | Unexpected services |
| Suspicious processes | Cryptominers, port scanners |
| File integrity | Modified system files |
| Firewall | UFW / Fail2ban status |
| System updates | Security patches needed |
| Nginx security | SQL injection, high errors |
| Disk anomaly | Malware payloads in /tmp |
| Cron jobs | Malicious scheduled tasks |

### Usage

```bash
# Run security check
sudo security-check.sh

# View security log
tail -50 /var/log/security-check.log
```

---

## 9. pg-manage.sh — Interactive Menu Launcher

**Location:** `/usr/local/bin/pg-manage.sh`

One entry point for every script above. Run `sudo pg-manage.sh` and pick an action from a colored menu — no need to remember individual script names or flags. Pure bash (no extra packages), so it works over any SSH session.

```bash
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
```

### Usage

```bash
# Launch the menu
sudo pg-manage.sh

# Then type a number and press Enter:
#   1  → runs pg-backup.sh
#   4  → runs pg-drop-db.sh   (drop, with its own safety prompts)
#   0  → exit
```

Each option simply calls the underlying script, so all existing prompts, confirmations, and safety backups still apply — the menu is just a friendlier front door. After an action finishes, press **Enter** to return to the menu.

### Features

- ✅ Single entry point for all six scripts
- ✅ Colored, boxed menu with live PostgreSQL status in the header
- ✅ Extra shortcuts: list databases (`\l+`), list backups
- ✅ Requires `sudo` (checks `EUID`) and warns if run as a normal user
- ✅ Pure bash — no `dialog`/`whiptail`/extra packages
- ✅ Delegates to each script unchanged, so all safety prompts remain

---

## Cron Schedule Summary

```bash
sudo crontab -e
```

```
# Daily DB backup at 2 AM
0 2 * * * /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1

# Health check every hour
0 * * * * /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1

# Security check every 6 hours
0 */6 * * * /usr/local/bin/security-check.sh >> /var/log/security-check.log 2>&1
```

---

```bash
sudo bash -c 'cat > /etc/security-check.env <<EOF
ALERT_EMAIL=mahbubur001@gmail.com
RESEND_API_KEY=re_your_NEW_key_here
RESEND_FROM=onboarding@resend.dev
SERVER_NAME=AWS EC2
SERVER_IP=13.202.89.114
EOF'

sudo chmod 600 /etc/security-check.env
sudo chown root:root /etc/security-check.env

sudo cat -A /etc/security-check.env
```

## Log Files

| Log | Location |
|-----|---------|
| Backup logs | `/var/log/pg-backup.log` |
| Database creation logs | `/var/log/pg-create-db.log` |
| Database drop logs | `/var/log/pg-drop-db.log` |
| Database rename logs | `/var/log/pg-rename.log` |
| Backup export logs | `/var/log/pg-export.log` |
| Health check logs | `/var/log/health-check.log` |
| Security check logs | `/var/log/security-check.log` |
| Backup files | `/var/backups/postgresql/` |

---

## Quick Reference

```bash
# Interactive menu for everything below
sudo pg-manage.sh

# Run backup now
sudo pg-backup.sh

# Restore database interactively
sudo pg-restore.sh

# Create new database & user
sudo pg-create-db.sh

# Drop a database (safety backup taken first)
sudo pg-drop-db.sh

# Rename a database and/or user (safety backup taken first)
sudo pg-rename.sh

# Export a backup to ~/downloads for SCP off the server
sudo pg-export.sh

# Check server health
sudo health-check.sh

# Run security check
sudo security-check.sh

# View logs
tail -50 /var/log/pg-backup.log
tail -50 /var/log/pg-create-db.log
tail -50 /var/log/pg-drop-db.log
tail -50 /var/log/pg-rename.log
tail -50 /var/log/pg-export.log
tail -50 /var/log/health-check.log
tail -50 /var/log/security-check.log

# List all backups
ls -lh /var/backups/postgresql/*/
```
