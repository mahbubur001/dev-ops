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
