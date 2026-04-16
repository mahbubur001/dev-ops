# Server Management Scripts
> Hetzner Server: `87.99.130.89` | Ubuntu 24 | 4 vCPU / 16GB RAM

---

## Quick Setup

```bash
# Create all four scripts
sudo nano /usr/local/bin/pg-backup.sh
sudo nano /usr/local/bin/pg-restore.sh
sudo nano /usr/local/bin/health-check.sh
sudo nano /usr/local/bin/security-check.sh

# Make all executable
sudo chmod +x /usr/local/bin/pg-backup.sh
sudo chmod +x /usr/local/bin/pg-restore.sh
sudo chmod +x /usr/local/bin/health-check.sh
sudo chmod +x /usr/local/bin/security-check.sh
```

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

## 3. health-check.sh — Server Health Monitor

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

## 4. security-check.sh — Security Monitor with Email Alerts

**Location:** `/usr/local/bin/security-check.sh`

> ⚠️ Update `ALERT_EMAIL` and `RESEND_API_KEY` before running!

```bash
#!/bin/bash

# ── Config ────────────────────────────────────────────────
ALERT_EMAIL="your@email.com"          # ← update this
RESEND_API_KEY="re_xxxxxxxxxxxx"      # ← update this
SERVER_NAME="rd-16gb-us-va-1"
SERVER_IP="87.99.130.89"
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
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "  Security Report — $SERVER_NAME ($SERVER_IP)" >> "$REPORT_FILE"
  echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# ── 1. SSH Login Attempts ─────────────────────────────────
check_ssh_failures() {
  echo -e "${BLUE}🔑 SSH Login Attempts${NC}"
  echo "────────────────────────────────────────────"
  FAILED=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep "Failed password" | wc -l)
  INVALID=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep "Invalid user" | wc -l)
  ROOT_ATTEMPTS=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep "Failed password for root" | wc -l)
  info "Failed SSH attempts (24h): $FAILED"
  info "Invalid user attempts (24h): $INVALID"
  if [ "$ROOT_ATTEMPTS" -gt 0 ]; then fail "Root login attempts: $ROOT_ATTEMPTS"
  else ok "No root login attempts"; fi
  if [ "$FAILED" -gt 100 ]; then fail "High failed SSH attempts: $FAILED (possible brute force!)"
  elif [ "$FAILED" -gt 20 ]; then warn "Elevated failed SSH attempts: $FAILED"
  else ok "Failed SSH attempts normal: $FAILED"; fi
  TOP_IPS=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep "Failed password" | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -5)
  if [ -n "$TOP_IPS" ]; then
    echo "$TOP_IPS" | while read line; do warn "  Attack IP: $line"; done
  fi
  echo ""
}

# ── 2. Unauthorized Users ─────────────────────────────────
check_users() {
  echo -e "${BLUE}👥 User Accounts${NC}"
  echo "────────────────────────────────────────────"
  ALLOWED_USERS="root deploy postgres www-data"
  SHELL_USERS=$(cat /etc/passwd | grep -E "(/bin/bash|/bin/sh|/bin/zsh)" | cut -d: -f1)
  for USER in $SHELL_USERS; do
    if echo "$ALLOWED_USERS" | grep -qw "$USER"; then ok "User: $USER (authorized)"
    else fail "Unknown user with shell: $USER (investigate!)"; fi
  done
  SUDO_USERS=$(getent group sudo | cut -d: -f4 | tr ',' '\n')
  for USER in $SUDO_USERS; do
    if echo "$ALLOWED_USERS" | grep -qw "$USER"; then ok "Sudo user: $USER (authorized)"
    else fail "Unknown sudo user: $USER (investigate!)"; fi
  done
  EMPTY_PASS=$(sudo awk -F: '($2 == "" ) {print $1}' /etc/shadow 2>/dev/null)
  if [ -n "$EMPTY_PASS" ]; then fail "Users with empty password: $EMPTY_PASS"
  else ok "No users with empty passwords"; fi
  echo ""
}

# ── 3. Open Ports ─────────────────────────────────────────
check_ports() {
  echo -e "${BLUE}🔌 Open Ports${NC}"
  echo "────────────────────────────────────────────"
  ALLOWED_PORTS="22 80 443 5432 6379 4000 4001 4002 4003 4004 4005"
  OPEN_PORTS=$(ss -tlnp | awk 'NR>1 {print $4}' | awk -F: '{print $NF}' | sort -u)
  for PORT in $OPEN_PORTS; do
    if echo "$ALLOWED_PORTS" | grep -qw "$PORT"; then ok "Port $PORT (expected)"
    else fail "Unexpected open port: $PORT (investigate!)"; fi
  done
  echo ""
}

# ── 4. Suspicious Processes ───────────────────────────────
check_processes() {
  echo -e "${BLUE}⚙️  Suspicious Processes${NC}"
  echo "────────────────────────────────────────────"
  MALICIOUS_PROCS="cryptominer xmrig minerd cgminer bfgminer ccminer ncrack hydra masscan nc.traditional"
  for PROC in $MALICIOUS_PROCS; do
    if pgrep -x "$PROC" > /dev/null 2>&1; then fail "Malicious process detected: $PROC (CRITICAL!)"; fi
  done
  HIGH_CPU=$(ps aux --sort=-%cpu | awk 'NR>1 && $3>80 {print $11, $3"%"}' | head -5)
  if [ -n "$HIGH_CPU" ]; then
    warn "High CPU processes:"
    echo "$HIGH_CPU" | while read line; do warn "  → $line"; done
  else ok "No suspicious high CPU processes"; fi
  PROC_COUNT_PS=$(ps aux | wc -l)
  PROC_COUNT_PROC=$(ls /proc | grep -E '^[0-9]+$' | wc -l)
  DIFF=$((PROC_COUNT_PROC - PROC_COUNT_PS))
  if [ "$DIFF" -gt 10 ]; then fail "Possible hidden processes! (diff: $DIFF)"
  else ok "No hidden processes detected"; fi
  echo ""
}

# ── 5. File Integrity ─────────────────────────────────────
check_file_integrity() {
  echo -e "${BLUE}📁 File Integrity${NC}"
  echo "────────────────────────────────────────────"
  MODIFIED=$(find /etc /usr/bin /usr/sbin -newer /etc/passwd -type f 2>/dev/null | head -10)
  if [ -n "$MODIFIED" ]; then
    warn "Recently modified system files:"
    echo "$MODIFIED" | while read FILE; do warn "  → $FILE"; done
  else ok "No suspicious system file modifications"; fi
  SUID=$(find / -perm -4000 -type f 2>/dev/null | grep -v -E "(/usr/bin|/usr/sbin|/bin|/sbin)" | head -5)
  if [ -n "$SUID" ]; then
    fail "Suspicious SUID files found:"
    echo "$SUID" | while read FILE; do fail "  → $FILE"; done
  else ok "No suspicious SUID files"; fi
  ENV_FILES=$(find /var/www -name ".env" -perm /o+r 2>/dev/null)
  if [ -n "$ENV_FILES" ]; then
    fail ".env files are world-readable:"
    echo "$ENV_FILES" | while read FILE; do fail "  → $FILE"; done
  else ok ".env files permissions are secure"; fi
  echo ""
}

# ── 6. Firewall ───────────────────────────────────────────
check_firewall() {
  echo -e "${BLUE}🛡️  Firewall${NC}"
  echo "────────────────────────────────────────────"
  UFW_STATUS=$(sudo ufw status 2>/dev/null | head -1)
  if echo "$UFW_STATUS" | grep -q "active"; then warn "UFW is active (use Hetzner firewall instead)"
  else ok "UFW inactive (using Hetzner cloud firewall)"; fi
  if command -v fail2ban-client &>/dev/null; then
    if systemctl is-active --quiet fail2ban; then
      BANNED=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
      ok "Fail2ban active | Banned IPs: $BANNED"
    else warn "Fail2ban installed but not running"; fi
  else warn "Fail2ban not installed (recommended)"; fi
  echo ""
}

# ── 7. System Updates ─────────────────────────────────────
check_updates() {
  echo -e "${BLUE}🔄 System Updates${NC}"
  echo "────────────────────────────────────────────"
  UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
  SECURITY=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
  if [ "$SECURITY" -gt 0 ]; then fail "Security updates available: $SECURITY (apply immediately!)"
  else ok "No security updates pending"; fi
  if [ "$UPDATES" -gt 20 ]; then warn "System updates available: $UPDATES"
  elif [ "$UPDATES" -gt 0 ]; then info "System updates available: $UPDATES"
  else ok "System is up to date"; fi
  echo ""
}

# ── 8. Nginx Security ─────────────────────────────────────
check_nginx_security() {
  echo -e "${BLUE}🌐 Nginx Security${NC}"
  echo "────────────────────────────────────────────"
  if [ -f "/var/log/nginx/error.log" ]; then
    SQL_INJECTION=$(grep -c "select\|union\|insert\|drop\|delete\|update" /var/log/nginx/error.log 2>/dev/null)
    if [ "$SQL_INJECTION" -gt 10 ]; then warn "Possible SQL injection attempts: $SQL_INJECTION"
    else ok "No significant SQL injection attempts"; fi
    if [ -f "/var/log/nginx/access.log" ]; then
      ERRORS=$(awk '$9 ~ /^[45]/' /var/log/nginx/access.log 2>/dev/null | wc -l)
      if [ "$ERRORS" -gt 1000 ]; then warn "High error rate: $ERRORS errors"
      else ok "Nginx error rate normal: $ERRORS errors"; fi
    fi
  fi
  if nginx -T 2>/dev/null | grep -q "deny all"; then ok "Nginx denying sensitive file access"
  else warn "Check Nginx config for .env and .git protection"; fi
  echo ""
}

# ── 9. Disk Anomaly ───────────────────────────────────────
check_disk_anomaly() {
  echo -e "${BLUE}💾 Disk Anomaly${NC}"
  echo "────────────────────────────────────────────"
  LARGE_FILES=$(find /tmp /var/tmp /dev/shm -size +50M -type f 2>/dev/null)
  if [ -n "$LARGE_FILES" ]; then
    fail "Large files in temp directories:"
    echo "$LARGE_FILES" | while read FILE; do fail "  → $FILE ($(du -sh $FILE | cut -f1))"; done
  else ok "No suspicious large files in temp directories"; fi
  TMP_EXEC=$(find /tmp /var/tmp -type f -executable 2>/dev/null)
  if [ -n "$TMP_EXEC" ]; then
    fail "Executable files in /tmp:"
    echo "$TMP_EXEC" | while read FILE; do fail "  → $FILE"; done
  else ok "No executables in /tmp"; fi
  echo ""
}

# ── 10. Cron Jobs ─────────────────────────────────────────
check_cron() {
  echo -e "${BLUE}⏰ Cron Jobs${NC}"
  echo "────────────────────────────────────────────"
  ALL_CRONS=$(crontab -l 2>/dev/null; sudo crontab -l 2>/dev/null; ls /etc/cron.d/ 2>/dev/null)
  info "Cron jobs found: $(echo "$ALL_CRONS" | wc -l)"
  SUSPICIOUS=$(crontab -l 2>/dev/null | grep -E "(wget|curl|bash|sh|python)" | grep -v "pg-backup\|health-check\|security-check")
  if [ -n "$SUSPICIOUS" ]; then
    fail "Suspicious cron jobs detected:"
    echo "$SUSPICIOUS" | while read line; do fail "  → $line"; done
  else ok "No suspicious cron jobs found"; fi
  echo ""
}

# ── Send Alert Email ──────────────────────────────────────
send_alert() {
  if [ "$ALERT" = true ]; then
    echo -e "${RED}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🚨 SECURITY ALERTS DETECTED!"
    echo "  Sending email to: $ALERT_EMAIL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"

    if command -v sendmail &>/dev/null; then
      {
        echo "To: $ALERT_EMAIL"
        echo "Subject: 🚨 Security Alert — $SERVER_NAME ($SERVER_IP)"
        echo "Content-Type: text/plain"
        echo ""
        echo "Security issues detected on your server!"
        echo ""
        cat "$REPORT_FILE"
        echo ""
        echo "Server: $SERVER_NAME | IP: $SERVER_IP | Time: $(date)"
      } | sendmail "$ALERT_EMAIL"
      echo "[$DATE] 🚨 Alert sent to $ALERT_EMAIL" >> "$LOG_FILE"

    elif [ -n "$RESEND_API_KEY" ]; then
      BODY=$(cat "$REPORT_FILE" | sed 's/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "https://api.resend.com/emails" \
        -H "Authorization: Bearer $RESEND_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
          \"from\": \"security@yourdomain.com\",
          \"to\": [\"$ALERT_EMAIL\"],
          \"subject\": \"🚨 Security Alert — $SERVER_NAME\",
          \"text\": \"$BODY\"
        }" > /dev/null
      echo "[$DATE] 🚨 Alert sent via Resend to $ALERT_EMAIL" >> "$LOG_FILE"
    else
      warn "No mail service configured — alert not sent!"
      warn "Set RESEND_API_KEY or install sendmail"
    fi
  else
    echo -e "${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ No security issues detected!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    echo "[$DATE] ✅ Security check passed" >> "$LOG_FILE"
  fi
}

# ── Main ──────────────────────────────────────────────────
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
echo "[$DATE] Security check completed" >> "$LOG_FILE"
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

## Log Files

| Log | Location |
|-----|---------|
| Backup logs | `/var/log/pg-backup.log` |
| Health check logs | `/var/log/health-check.log` |
| Security check logs | `/var/log/security-check.log` |
| Backup files | `/var/backups/postgresql/` |

---

## Quick Reference

```bash
# Run backup now
sudo pg-backup.sh

# Restore database interactively
sudo pg-restore.sh

# Check server health
sudo health-check.sh

# Run security check
sudo security-check.sh

# View logs
tail -50 /var/log/pg-backup.log
tail -50 /var/log/health-check.log
tail -50 /var/log/security-check.log

# List all backups
ls -lh /var/backups/postgresql/*/
```