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
