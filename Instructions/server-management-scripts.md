# Server Management Scripts

---

## Quick Setup

```bash
# Create all three scripts at once
sudo nano /usr/local/bin/pg-backup.sh
sudo nano /usr/local/bin/pg-restore.sh
sudo nano /usr/local/bin/health-check.sh

# Make all executable
sudo chmod +x /usr/local/bin/pg-backup.sh
sudo chmod +x /usr/local/bin/pg-restore.sh
sudo chmod +x /usr/local/bin/health-check.sh
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
  # Skip system databases
  if echo "$EXCLUDE_DBS" | grep -qw "$DB"; then
    echo "[$DATE] ⏭️  Skipping system db: $DB" >> "$LOG_FILE"
    continue
  fi

  # Create directory for this database
  mkdir -p "$BACKUP_DIR/$DB"

  echo "[$DATE] 📦 Backing up: $DB" >> "$LOG_FILE"

  sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_DIR/$DB/backup_$DATE.sql.gz"

  if [ $? -eq 0 ]; then
    SIZE=$(du -sh "$BACKUP_DIR/$DB/backup_$DATE.sql.gz" | cut -f1)
    echo "[$DATE] ✅ $DB → backup_$DATE.sql.gz ($SIZE)" >> "$LOG_FILE"
  else
    echo "[$DATE] ❌ $DB backup failed!" >> "$LOG_FILE"
  fi

  # Delete backups older than retention days
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

  # Drop and recreate
  sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB';" > /dev/null 2>&1
  sudo -u postgres dropdb "$DB" 2>/dev/null
  sudo -u postgres createdb "$DB"

  # Restore
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

# ── Header ────────────────────────────────────────────────
print_header() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🏥 Server Health Check"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
}

# ── System Resources ──────────────────────────────────────
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

# ── Services ──────────────────────────────────────────────
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

# ── PM2 Apps ──────────────────────────────────────────────
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

# ── Ports ─────────────────────────────────────────────────
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

# ── Nginx Sites ───────────────────────────────────────────
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

# ── Databases ─────────────────────────────────────────────
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

# ── Backups ───────────────────────────────────────────────
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

# ── SSL ───────────────────────────────────────────────────
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
sudo crontab -e
# Add: 0 * * * * /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1
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
```

---

## Log Files

| Log | Location |
|-----|---------|
| Backup logs | `/var/log/pg-backup.log` |
| Health check logs | `/var/log/health-check.log` |
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

# View backup log
tail -50 /var/log/pg-backup.log

# View health log
tail -50 /var/log/health-check.log

# List all backups
ls -lh /var/backups/postgresql/*/
```