#!/bin/bash
#####################################################################
# health-check-aws.sh — Server Health Monitor (AWS t4g.medium)
#
# Adapted from the Hetzner health-check.sh for a fresh AWS box
# running: radiustask + 3 Next.js apps (ports 3000-3003).
#
# Install on server:
#   scp scripts/health-check-aws.sh deploy@<ip>:/tmp/
#   sudo mv /tmp/health-check-aws.sh /usr/local/bin/health-check.sh
#   sudo chmod +x /usr/local/bin/health-check.sh
#   sudo /usr/local/bin/health-check.sh
#
# Edit the PORTS array below as you add/rename apps.
#####################################################################

# ── Colors ────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/health-check.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# App/service ports to check — "port:label"
PORTS=(
  "80:Nginx HTTP"
  "443:Nginx HTTPS"
  "5432:PostgreSQL"
  "6379:Redis"
  "3000:radiustask"
  "3001:nextjs-app-1"
  "3002:nextjs-app-2"
  "3003:nextjs-app-3"
)

# ── Helpers ───────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }

print_header() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🏥 Server Health Check  ($(hostname))"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
}

check_system() {
  echo -e "${BLUE}📊 System Resources${NC}"
  echo "────────────────────────────────────────────"

  CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
  CPU=${CPU%.*}
  if [ "${CPU:-0}" -lt 80 ]; then ok "CPU Usage: ${CPU}%"
  elif [ "${CPU:-0}" -lt 90 ]; then warn "CPU Usage: ${CPU}% (High)"
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

  info "Load Average:$(uptime | awk -F'load average:' '{print $2}')"
  info "Uptime: $(uptime -p)"
  echo ""
}

check_services() {
  echo -e "${BLUE}🔧 Services${NC}"
  echo "────────────────────────────────────────────"

  if systemctl is-active --quiet nginx; then ok "Nginx: Running"
  else fail "Nginx: Not running!"; fi

  if systemctl is-active --quiet postgresql; then ok "PostgreSQL: Running"
  else warn "PostgreSQL: Not running (not installed yet?)"; fi

  if systemctl is-active --quiet redis-server; then ok "Redis: Running"
  else warn "Redis: Not running (not installed yet?)"; fi

  echo ""
}

check_pm2() {
  echo -e "${BLUE}⚡ PM2 Applications${NC}"
  echo "────────────────────────────────────────────"

  if ! command -v pm2 >/dev/null 2>&1; then
    warn "PM2 not installed"
    echo ""; return
  fi

  PM2_LIST=$(pm2 jlist 2>/dev/null)
  if [ -z "$PM2_LIST" ] || [ "$PM2_LIST" = "[]" ]; then
    warn "PM2: No processes running"
    echo ""; return
  fi

  echo "$PM2_LIST" | python3 -c "
import json, sys
try:
    apps = json.load(sys.stdin)
except Exception:
    sys.exit(1)
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

  for PORT_INFO in "${PORTS[@]}"; do
    PORT="${PORT_INFO%%:*}"
    NAME="${PORT_INFO##*:}"
    if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then ok "$NAME (port $PORT)"
    else fail "$NAME (port $PORT) - Not listening!"; fi
  done

  echo ""
}

check_ssl() {
  echo -e "${BLUE}🔒 SSL Certificates (Let's Encrypt)${NC}"
  echo "────────────────────────────────────────────"

  LE_DIR="/etc/letsencrypt/live"
  if [ ! -d "$LE_DIR" ]; then
    warn "No Certbot certificates yet"
    echo ""; return
  fi

  for CERT_DIR in "$LE_DIR"/*/; do
    CERT="$CERT_DIR/cert.pem"
    [ -f "$CERT" ] || continue
    DOMAIN=$(basename "$CERT_DIR")
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -gt 30 ]; then ok "$DOMAIN: valid $DAYS_LEFT days"
    elif [ "$DAYS_LEFT" -gt 7 ]; then warn "$DOMAIN: expires in $DAYS_LEFT days"
    else fail "$DOMAIN: expires in $DAYS_LEFT days - URGENT!"; fi
  done

  echo ""
}

# ── Main ──────────────────────────────────────────────────
print_header
check_system
check_services
check_pm2
check_ports
check_ssl

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Health check completed!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "[$DATE] Health check completed" >> "$LOG_FILE" 2>/dev/null
