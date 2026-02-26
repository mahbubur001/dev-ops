# Auto Backup PostgreSQL on AWS EC2 (Daily)

> Complete guide to set up automatic daily backups for your PostgreSQL database on AWS EC2.

---

## Table of Contents

1. [Method 1: Local Backup with Cron](#method-1-local-backup-with-cron-simple)
2. [Method 2: Backup to AWS S3](#method-2-backup-to-aws-s3-recommended)
3. [Method 3: Advanced Backup Strategy](#method-3-advanced-backup-dailyweeklymonthly)
4. [Verify Backups](#verify-backups)
5. [Restore from Backup](#restore-from-backup)
6. [Email Notifications](#email-notification-optional)
7. [Quick Setup](#quick-setup-copy-paste)
8. [Troubleshooting](#troubleshooting)

---

## Method 1: Local Backup with Cron (Simple)

### Step 1: Create Backup Directory

```bash
sudo mkdir -p /var/backups/postgresql
sudo chown ubuntu:ubuntu /var/backups/postgresql
```

### Step 2: Create Backup Script

```bash
sudo nano /usr/local/bin/backup-postgres.sh
```

**Paste this content:**

```bash
#!/bin/bash

#####################################
# PostgreSQL Daily Backup Script
#####################################

# Configuration - UPDATE THESE VALUES
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

# Create backup directory if not exists
mkdir -p $BACKUP_DIR

# Backup filename
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"

# Create backup
echo "$(date): Starting backup of $DB_NAME..."
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_FILE"

# Check if backup was successful
if [ $? -eq 0 ]; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "$(date): ✅ Backup successful: $BACKUP_FILE ($SIZE)"
else
    echo "$(date): ❌ Backup failed!"
    exit 1
fi

# Delete old backups
echo "$(date): Cleaning up backups older than $RETENTION_DAYS days..."
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "$(date): Backup process completed."
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### Step 3: Make Script Executable

```bash
sudo chmod +x /usr/local/bin/backup-postgres.sh
```

### Step 4: Test the Script

```bash
sudo /usr/local/bin/backup-postgres.sh
```

**Expected output:**

```
Tue Jan 15 02:00:01 UTC 2025: Starting backup of directory_db...
Tue Jan 15 02:00:05 UTC 2025: ✅ Backup successful: /var/backups/postgresql/directory_db_20250115_020001.sql.gz (2.5M)
Tue Jan 15 02:00:05 UTC 2025: Cleaning up backups older than 7 days...
Tue Jan 15 02:00:05 UTC 2025: Backup process completed.
```

### Step 5: Schedule Daily Backup with Cron

```bash
sudo crontab -e
```

**Add this line (runs at 2:00 AM every day):**

```bash
0 2 * * * /usr/local/bin/backup-postgres.sh >> /var/log/postgres-backup.log 2>&1
```

**Save and exit.**

### Step 6: Verify Cron Job

```bash
sudo crontab -l
```

---

## Method 2: Backup to AWS S3 (Recommended)

### Step 1: Install AWS CLI

```bash
sudo apt install awscli -y
```

### Step 2: Configure AWS CLI

```bash
aws configure
```

**Enter:**

| Prompt | Value |
|--------|-------|
| AWS Access Key ID | Your access key |
| AWS Secret Access Key | Your secret key |
| Default region | `ap-south-1` (or your region) |
| Output format | `json` |

### Step 3: Create S3 Bucket

```bash
aws s3 mb s3://your-app-db-backups
```

### Step 4: Create Backup Script with S3 Upload

```bash
sudo nano /usr/local/bin/backup-postgres-s3.sh
```

**Paste this content:**

```bash
#!/bin/bash

#####################################
# PostgreSQL Backup to S3
#####################################

# Configuration - UPDATE THESE VALUES
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
BACKUP_DIR="/var/backups/postgresql"
S3_BUCKET="s3://your-app-db-backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS_LOCAL=7
RETENTION_DAYS_S3=30

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup filename
BACKUP_FILE="${DB_NAME}_${DATE}.sql.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"

# Create backup
echo "$(date): Starting backup..."
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_PATH"

if [ $? -ne 0 ]; then
    echo "$(date): ❌ Backup failed!"
    exit 1
fi

SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
echo "$(date): ✅ Local backup created: $BACKUP_FILE ($SIZE)"

# Upload to S3
echo "$(date): Uploading to S3..."
aws s3 cp "$BACKUP_PATH" "${S3_BUCKET}/daily/${BACKUP_FILE}"

if [ $? -eq 0 ]; then
    echo "$(date): ✅ Uploaded to S3: ${S3_BUCKET}/daily/${BACKUP_FILE}"
else
    echo "$(date): ❌ S3 upload failed!"
    exit 1
fi

# Delete old local backups
echo "$(date): Cleaning up old local backups..."
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS_LOCAL -delete

# Delete old S3 backups (older than 30 days)
echo "$(date): Cleaning up old S3 backups..."
CUTOFF_DATE=$(date -d "-${RETENTION_DAYS_S3} days" +%Y-%m-%d)
aws s3 ls "${S3_BUCKET}/daily/" | while read -r line; do
    FILE_DATE=$(echo $line | awk '{print $1}')
    FILE_NAME=$(echo $line | awk '{print $4}')
    
    if [ ! -z "$FILE_NAME" ] && [ "$FILE_DATE" \< "$CUTOFF_DATE" ]; then
        aws s3 rm "${S3_BUCKET}/daily/${FILE_NAME}"
        echo "$(date): Deleted old S3 backup: $FILE_NAME"
    fi
done

echo "$(date): ✅ Backup process completed."
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### Step 5: Make Executable and Test

```bash
sudo chmod +x /usr/local/bin/backup-postgres-s3.sh

# Test
sudo /usr/local/bin/backup-postgres-s3.sh
```

### Step 6: Schedule Daily Backup

```bash
sudo crontab -e
```

**Add:**

```bash
0 2 * * * /usr/local/bin/backup-postgres-s3.sh >> /var/log/postgres-backup.log 2>&1
```

---

## Method 3: Advanced Backup (Daily/Weekly/Monthly)

### Create Advanced Backup Script

```bash
sudo nano /usr/local/bin/backup-postgres-advanced.sh
```

**Paste this content:**

```bash
#!/bin/bash

#####################################
# Advanced PostgreSQL Backup
# - Daily: Keep 7 days
# - Weekly: Keep 4 weeks
# - Monthly: Keep 12 months
#####################################

# Configuration - UPDATE THESE VALUES
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
DAY_OF_WEEK=$(date +%u)
DAY_OF_MONTH=$(date +%d)

# Create backup directories
mkdir -p $BACKUP_DIR/daily
mkdir -p $BACKUP_DIR/weekly
mkdir -p $BACKUP_DIR/monthly

echo "$(date): Starting advanced backup..."

# Daily backup
DAILY_FILE="${BACKUP_DIR}/daily/${DB_NAME}_daily_${DATE}.sql.gz"
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$DAILY_FILE"

if [ $? -eq 0 ]; then
    SIZE=$(du -h "$DAILY_FILE" | cut -f1)
    echo "$(date): ✅ Daily backup created: $DAILY_FILE ($SIZE)"
else
    echo "$(date): ❌ Daily backup failed!"
    exit 1
fi

# Weekly backup (on Sunday - day 7)
if [ "$DAY_OF_WEEK" -eq 7 ]; then
    WEEKLY_FILE="${BACKUP_DIR}/weekly/${DB_NAME}_weekly_${DATE}.sql.gz"
    cp "$DAILY_FILE" "$WEEKLY_FILE"
    echo "$(date): ✅ Weekly backup created: $WEEKLY_FILE"
fi

# Monthly backup (on 1st of month)
if [ "$DAY_OF_MONTH" -eq "01" ]; then
    MONTHLY_FILE="${BACKUP_DIR}/monthly/${DB_NAME}_monthly_${DATE}.sql.gz"
    cp "$DAILY_FILE" "$MONTHLY_FILE"
    echo "$(date): ✅ Monthly backup created: $MONTHLY_FILE"
fi

# Cleanup old backups
echo "$(date): Cleaning up old backups..."
find $BACKUP_DIR/daily -name "*.sql.gz" -mtime +7 -delete      # Keep 7 days
find $BACKUP_DIR/weekly -name "*.sql.gz" -mtime +30 -delete    # Keep 30 days
find $BACKUP_DIR/monthly -name "*.sql.gz" -mtime +365 -delete  # Keep 365 days

echo "$(date): ✅ Advanced backup completed."
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### Make Executable and Schedule

```bash
sudo chmod +x /usr/local/bin/backup-postgres-advanced.sh

# Test
sudo /usr/local/bin/backup-postgres-advanced.sh

# Schedule
sudo crontab -e
```

**Add:**

```bash
0 2 * * * /usr/local/bin/backup-postgres-advanced.sh >> /var/log/postgres-backup.log 2>&1
```

---

## Verify Backups

### Check Backup Files

```bash
ls -lah /var/backups/postgresql/
```

### Check Backup Log

```bash
tail -50 /var/log/postgres-backup.log
```

### Check Cron is Running

```bash
# View cron logs
grep CRON /var/log/syslog | tail -20
```

### Check S3 Backups (if using S3)

```bash
aws s3 ls s3://your-app-db-backups/daily/
```

---

## Restore from Backup

### Restore from .sql.gz File

```bash
# Stop your application first (optional but recommended)

# Restore to existing database
gunzip -c /var/backups/postgresql/directory_db_20250115_020001.sql.gz | psql -U appuser -h localhost -d directory_db
```

### Restore to New Database

```bash
# Create new database
sudo -u postgres psql -c "CREATE DATABASE directory_db_restored;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE directory_db_restored TO appuser;"

# Restore
gunzip -c /var/backups/postgresql/directory_db_20250115_020001.sql.gz | psql -U appuser -h localhost -d directory_db_restored

# Verify
psql -U appuser -h localhost -d directory_db_restored -c "\dt"
```

### Restore from S3

```bash
# Download from S3
aws s3 cp s3://your-app-db-backups/daily/directory_db_20250115_020001.sql.gz /tmp/

# Restore
gunzip -c /tmp/directory_db_20250115_020001.sql.gz | psql -U appuser -h localhost -d directory_db
```

### Test Restore (Recommended Practice)

```bash
# Create test database
sudo -u postgres psql -c "CREATE DATABASE test_restore;"

# Restore backup to test database
gunzip -c /var/backups/postgresql/directory_db_XXXXXX.sql.gz | psql -U appuser -h localhost -d test_restore

# Verify tables exist
psql -U appuser -h localhost -d test_restore -c "\dt"

# Check row counts
psql -U appuser -h localhost -d test_restore -c "SELECT COUNT(*) FROM users;"

# Drop test database when done
sudo -u postgres psql -c "DROP DATABASE test_restore;"
```

---

## Email Notification (Optional)

### Step 1: Install Mail Utility

```bash
sudo apt install mailutils -y
```

### Step 2: Create Backup Script with Email

```bash
sudo nano /usr/local/bin/backup-postgres-email.sh
```

**Paste this content:**

```bash
#!/bin/bash

#####################################
# PostgreSQL Backup with Email Alert
#####################################

# Configuration - UPDATE THESE VALUES
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
BACKUP_DIR="/var/backups/postgresql"
EMAIL="your-email@example.com"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup filename
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"

# Create backup
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_FILE"

# Check result and send email
if [ $? -eq 0 ]; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "PostgreSQL backup completed successfully.

Database: $DB_NAME
File: $BACKUP_FILE
Size: $SIZE
Date: $(date)

This is an automated message." | mail -s "✅ DB Backup Success - $DB_NAME" $EMAIL

    echo "$(date): ✅ Backup successful, email sent."
else
    echo "PostgreSQL backup FAILED!

Database: $DB_NAME
Date: $(date)

Please check the server immediately.

This is an automated message." | mail -s "❌ DB Backup FAILED - $DB_NAME" $EMAIL

    echo "$(date): ❌ Backup failed, alert email sent."
    exit 1
fi

# Cleanup
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "$(date): Backup process completed."
```

---

## Quick Setup (Copy-Paste)

Run these commands to set up basic daily backup:

```bash
# 1. Create backup directory
sudo mkdir -p /var/backups/postgresql
sudo chown ubuntu:ubuntu /var/backups/postgresql

# 2. Create backup script
cat << 'EOF' | sudo tee /usr/local/bin/backup-postgres.sh
#!/bin/bash
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

mkdir -p $BACKUP_DIR
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"

echo "$(date): Starting backup..."
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "$(date): ✅ Backup successful: $BACKUP_FILE ($SIZE)"
else
    echo "$(date): ❌ Backup failed!"
    exit 1
fi

find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
echo "$(date): Backup completed."
EOF

# 3. Make executable
sudo chmod +x /usr/local/bin/backup-postgres.sh

# 4. Test backup
sudo /usr/local/bin/backup-postgres.sh

# 5. Schedule daily at 2 AM
(sudo crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-postgres.sh >> /var/log/postgres-backup.log 2>&1") | sudo crontab -

# 6. Verify cron job
sudo crontab -l

echo "✅ Daily backup configured! Runs at 2:00 AM every day."
```

---

## Troubleshooting

### Backup Script Not Running

```bash
# Check cron service is running
sudo systemctl status cron

# Check cron logs
grep CRON /var/log/syslog | tail -20

# Run script manually to see errors
sudo /usr/local/bin/backup-postgres.sh
```

### Permission Denied Error

```bash
# Fix script permissions
sudo chmod +x /usr/local/bin/backup-postgres.sh

# Fix backup directory permissions
sudo chown -R ubuntu:ubuntu /var/backups/postgresql
```

### Database Connection Error

```bash
# Test database connection
psql -U appuser -h localhost -d directory_db -c "SELECT 1;"

# Check PostgreSQL is running
sudo systemctl status postgresql
```

### Disk Space Full

```bash
# Check disk space
df -h

# Remove old backups manually
ls -la /var/backups/postgresql/
rm /var/backups/postgresql/old_backup.sql.gz
```

### S3 Upload Failed

```bash
# Test AWS CLI
aws s3 ls

# Check credentials
aws configure list

# Test upload manually
aws s3 cp /var/backups/postgresql/test.sql.gz s3://your-bucket/
```

---

## Cron Schedule Reference

| Schedule | Cron Expression | Description |
|----------|-----------------|-------------|
| Every day at 2 AM | `0 2 * * *` | Daily backup |
| Every 6 hours | `0 */6 * * *` | 4 times a day |
| Every Sunday at 3 AM | `0 3 * * 0` | Weekly backup |
| 1st of month at 4 AM | `0 4 1 * *` | Monthly backup |
| Every hour | `0 * * * *` | Hourly backup |

---

## Summary

| Method | Storage | Retention | Complexity | Best For |
|--------|---------|-----------|------------|----------|
| Local Only | EC2 Disk | 7 days | Simple | Development |
| Local + S3 | EC2 + S3 | 30 days | Medium | Production |
| Advanced | Daily/Weekly/Monthly | 1 year | Complex | Enterprise |

---

## Quick Reference Commands

| Task | Command |
|------|---------|
| Run backup manually | `sudo /usr/local/bin/backup-postgres.sh` |
| View backup files | `ls -lah /var/backups/postgresql/` |
| View backup log | `tail -50 /var/log/postgres-backup.log` |
| View cron jobs | `sudo crontab -l` |
| Edit cron jobs | `sudo crontab -e` |
| Check cron service | `sudo systemctl status cron` |
| Restore backup | `gunzip -c backup.sql.gz \| psql -U appuser -d directory_db` |

---

## Done! ✅

Your PostgreSQL database will now be backed up automatically every day at 2:00 AM.

**Backup Location:** `/var/backups/postgresql/`

**Log File:** `/var/log/postgres-backup.log`

---

*Document Version: 1.0*
*PostgreSQL Version: 17*
*Ubuntu Version: 24.04 LTS*
*Last Updated: 2024*
