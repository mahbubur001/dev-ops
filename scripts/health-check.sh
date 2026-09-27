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
