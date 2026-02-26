# Complete PostgreSQL 17 Installation Guide for AWS EC2

> **Instance:** t3.medium | **OS:** Ubuntu Server 24.04 | **Storage:** 30GB

---

## Table of Contents

1. [Connect to EC2 Instance](#step-1-connect-to-your-ec2-instance)
2. [Update System](#step-2-update-system)
3. [Remove Old PostgreSQL (If Exists)](#step-3-remove-old-postgresql-if-exists)
4. [Install PostgreSQL 17](#step-4-install-postgresql-17)
5. [Verify Installation](#step-5-verify-postgresql-is-running)
6. [Create Database and User](#step-6-create-database-and-user)
7. [Configure PostgreSQL](#step-7-configure-postgresql)
8. [Test Connection](#step-8-test-connection)
9. [Upload SQL File](#step-9-upload-sql-file-to-ec2)
10. [Import SQL File](#step-10-import-sql-file)
11. [Verify Import](#step-11-verify-import)
12. [Create Backup Script](#step-12-create-backup-script)
13. [Connection String](#step-13-your-connection-string)
14. [Quick Reference Commands](#step-14-quick-reference-commands)
15. [Troubleshooting](#troubleshooting)

---

## Step 1: Connect to Your EC2 Instance

```bash
ssh -i "your-key.pem" ubuntu@your-ec2-public-ip
```

---

## Step 2: Update System

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Step 3: Remove Old PostgreSQL (If Exists)

Skip this step if PostgreSQL is not installed.

```bash
# Check if PostgreSQL is installed
psql --version

# If installed, remove it
sudo systemctl stop postgresql
sudo apt remove --purge postgresql* -y
sudo apt autoremove -y

# Remove old data (WARNING: Deletes all data!)
sudo rm -rf /var/lib/postgresql/
sudo rm -rf /etc/postgresql/
```

---

## Step 4: Install PostgreSQL 17

```bash
# Add PostgreSQL official repository
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'

# Import repository signing key
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/pgdg.asc > /dev/null

# Update package list
sudo apt update

# Check available versions
apt-cache search postgresql | grep postgresql-17

# Install PostgreSQL 17
sudo apt install -y postgresql-17 postgresql-contrib-17

# Verify installation
psql --version
```

**Expected output:**

```
psql (PostgreSQL) 17.x
```

---

## Step 5: Verify PostgreSQL is Running

```bash
sudo systemctl status postgresql
```

**Expected output:**

```
● postgresql.service - PostgreSQL RDBMS
     Loaded: loaded
     Active: active (exited)
```

---

## Step 6: Create Database and User

### 6.1 Switch to postgres user

```bash
sudo -i -u postgres
psql
```

### 6.2 Run SQL Commands

```sql
-- Create application user (CHANGE PASSWORD!)
CREATE USER appuser WITH PASSWORD 'YourStrongPassword123';

-- Create database
CREATE DATABASE directory_db;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE directory_db TO appuser;

-- Connect to database
\c directory_db

-- Grant schema privileges
GRANT ALL ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
ALTER SCHEMA public OWNER TO appuser;

-- Set default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO appuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO appuser;

-- Verify user created
\du

-- Verify database created
\l

-- Exit psql
\q
```

### 6.3 Exit postgres user

```bash
exit
```

---

## Step 7: Configure PostgreSQL

### 7.1 Edit Main Configuration

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```

**Find and update these settings:**

```conf
# CONNECTIONS
listen_addresses = 'localhost'
port = 5432
max_connections = 100

# MEMORY (Optimized for 4GB RAM - t3.medium)
shared_buffers = 1GB
effective_cache_size = 3GB
maintenance_work_mem = 256MB
work_mem = 32MB

# WAL
wal_buffers = 64MB
min_wal_size = 512MB
max_wal_size = 2GB

# CHECKPOINTS
checkpoint_completion_target = 0.9

# PLANNER (For SSD/EBS)
random_page_cost = 1.1
effective_io_concurrency = 200

# LOGGING
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_min_duration_statement = 1000
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### 7.2 Edit Authentication Configuration

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```

**Find and update to match:**

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             postgres                                peer
local   all             all                                     md5

# IPv4 local connections
host    all             all             127.0.0.1/32            md5

# IPv6 local connections
host    all             all             ::1/128                 md5
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### 7.3 Restart PostgreSQL

```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql
```

---

## Step 8: Test Connection

```bash
psql -U appuser -d directory_db -h localhost
```

Enter your password when prompted. You should see:

```
directory_db=>
```

**Test a query:**

```sql
SELECT version();
\q
```

---

## Step 9: Upload SQL File to EC2

From your **local machine**, upload the SQL file:

### For .sql file:

```bash
scp -i "your-key.pem" /path/to/your-backup.sql ubuntu@your-ec2-ip:/home/ubuntu/
```

### For .sql.gz file (compressed):

```bash
scp -i "your-key.pem" /path/to/your-backup.sql.gz ubuntu@your-ec2-ip:/home/ubuntu/
```

### Verify file uploaded:

```bash
# Connect to EC2
ssh -i "your-key.pem" ubuntu@your-ec2-ip

# Check file exists
ls -la /home/ubuntu/*.sql
```

---

## Step 10: Import SQL File

### For regular .sql file:

```bash
psql -U appuser -d directory_db -h localhost -f /home/ubuntu/your-backup.sql
```

### For compressed .sql.gz file:

```bash
gunzip -c /home/ubuntu/your-backup.sql.gz | psql -U appuser -d directory_db -h localhost
```

### For .dump file (custom format):

```bash
pg_restore -U appuser -d directory_db -h localhost /home/ubuntu/your-backup.dump
```

### Import with progress (for large files):

```bash
# Install pv first
sudo apt install pv -y

# Import with progress bar
pv /home/ubuntu/your-backup.sql | psql -U appuser -d directory_db -h localhost
```

---

## Step 11: Verify Import

```bash
psql -U appuser -d directory_db -h localhost
```

```sql
-- List all tables
\dt

-- Count total tables
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';

-- Check specific tables (replace with your table names)
SELECT COUNT(*) FROM users;
SELECT COUNT(*) FROM listings;

-- Check database size
SELECT pg_size_pretty(pg_database_size('directory_db'));

-- Exit
\q
```

---

## Step 12: Create Backup Script

### 12.1 Create the Script

```bash
sudo nano /usr/local/bin/backup-postgres.sh
```

**Paste this content:**

```bash
#!/bin/bash

#####################################
# PostgreSQL 17 Backup Script
#####################################

BACKUP_DIR="/var/backups/postgresql"
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
RETENTION_DAYS=7
DATE=$(date +%Y%m%d_%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR

# Create backup
echo "Starting backup of $DB_NAME..."
PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

# Check if successful
if [ $? -eq 0 ]; then
    SIZE=$(du -h "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz" | cut -f1)
    echo "✅ Backup completed: ${DB_NAME}_${DATE}.sql.gz ($SIZE)"
else
    echo "❌ Backup failed!"
    exit 1
fi

# Delete old backups
find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
echo "Old backups cleaned up (keeping last $RETENTION_DAYS days)"
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### 12.2 Make Script Executable

```bash
sudo chmod +x /usr/local/bin/backup-postgres.sh
```

### 12.3 Test Backup

```bash
sudo /usr/local/bin/backup-postgres.sh
```

### 12.4 Schedule Daily Backup

```bash
sudo crontab -e
```

**Add this line:**

```bash
0 2 * * * /usr/local/bin/backup-postgres.sh >> /var/log/postgres-backup.log 2>&1
```

**Save and exit.**

---

## Step 13: Your Connection String

Use this in your `.env` file:

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public"
```

### With Connection Pooling (Recommended):

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public&connection_limit=20&pool_timeout=30"
```

---

## Step 14: Quick Reference Commands

### Service Management

| Task | Command |
|------|---------|
| Start PostgreSQL | `sudo systemctl start postgresql` |
| Stop PostgreSQL | `sudo systemctl stop postgresql` |
| Restart PostgreSQL | `sudo systemctl restart postgresql` |
| Check Status | `sudo systemctl status postgresql` |
| Enable on Boot | `sudo systemctl enable postgresql` |

### Database Access

| Task | Command |
|------|---------|
| Access as superuser | `sudo -u postgres psql` |
| Access as appuser | `psql -U appuser -d directory_db -h localhost` |
| Access specific DB | `psql -U appuser -d database_name -h localhost` |

### Inside psql

| Task | Command |
|------|---------|
| List databases | `\l` |
| List tables | `\dt` |
| Describe table | `\d table_name` |
| List users | `\du` |
| Current database | `SELECT current_database();` |
| Database size | `SELECT pg_size_pretty(pg_database_size('directory_db'));` |
| Exit psql | `\q` |

### Backup & Restore

| Task | Command |
|------|---------|
| Backup database | `pg_dump -U appuser -h localhost directory_db > backup.sql` |
| Backup compressed | `pg_dump -U appuser -h localhost directory_db \| gzip > backup.sql.gz` |
| Restore .sql | `psql -U appuser -d directory_db -h localhost -f backup.sql` |
| Restore .sql.gz | `gunzip -c backup.sql.gz \| psql -U appuser -d directory_db -h localhost` |
| Manual backup | `sudo /usr/local/bin/backup-postgres.sh` |

### Logs

| Task | Command |
|------|---------|
| View logs | `sudo tail -f /var/log/postgresql/postgresql-17-main.log` |
| View backup log | `sudo tail -f /var/log/postgres-backup.log` |

---

## Troubleshooting

### Error: Connection Refused

```bash
# Check if PostgreSQL is running
sudo systemctl status postgresql

# Start if not running
sudo systemctl start postgresql

# Check if listening on port
sudo netstat -tlnp | grep 5432
```

### Error: Password Authentication Failed

```bash
# Reset password
sudo -u postgres psql
ALTER USER appuser WITH PASSWORD 'NewPassword123';
\q
```

### Error: Permission Denied

```bash
# Grant permissions
sudo -u postgres psql -d directory_db

GRANT ALL ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
\q
```

### Error: Database Does Not Exist

```bash
sudo -u postgres psql -c "CREATE DATABASE directory_db;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE directory_db TO appuser;"
```

### Error: Role Does Not Exist

```bash
sudo -u postgres psql -c "CREATE USER appuser WITH PASSWORD 'YourPassword';"
```

### Import Error: Unrecognized Parameter

If importing from older PostgreSQL version:

```bash
# Remove problematic lines
sed -i '/transaction_timeout/d' /home/ubuntu/backup.sql
sed -i '/idle_session_timeout/d' /home/ubuntu/backup.sql

# Then import again
psql -U appuser -d directory_db -h localhost -f /home/ubuntu/backup.sql
```

### Import Error: Table Already Exists

```bash
# Option 1: Drop and recreate database
sudo -u postgres psql -c "DROP DATABASE directory_db;"
sudo -u postgres psql -c "CREATE DATABASE directory_db;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE directory_db TO appuser;"

# Then import
psql -U appuser -d directory_db -h localhost -f /home/ubuntu/backup.sql
```

```bash
# Option 2: Skip errors and continue
psql -U appuser -d directory_db -h localhost --set ON_ERROR_STOP=off -f /home/ubuntu/backup.sql
```

### Check Active Connections

```bash
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE datname = 'directory_db';"
```

### Kill All Connections (Before Drop)

```bash
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'directory_db' AND pid <> pg_backend_pid();"
```

---

## PostgreSQL 17 File Paths

| Item | Path |
|------|------|
| Main config | `/etc/postgresql/17/main/postgresql.conf` |
| Auth config | `/etc/postgresql/17/main/pg_hba.conf` |
| Data directory | `/var/lib/postgresql/17/main/` |
| Log directory | `/var/log/postgresql/` |
| Binary files | `/usr/lib/postgresql/17/bin/` |
| Backup directory | `/var/backups/postgresql/` |

---

## Memory Settings Reference

| VPS RAM | shared_buffers | effective_cache_size | work_mem | max_connections |
|---------|----------------|----------------------|----------|-----------------|
| 2GB | 512MB | 1.5GB | 16MB | 50 |
| 4GB | 1GB | 3GB | 32MB | 100 |
| 8GB | 2GB | 6GB | 64MB | 150 |
| 16GB | 4GB | 12GB | 128MB | 200 |

---

## Security Recommendations

1. **Use strong passwords**
   ```bash
   # Generate strong password
   openssl rand -base64 32
   ```

2. **Keep PostgreSQL local only**
    - Don't expose port 5432 to internet
    - Use SSH tunnel for remote access

3. **Regular backups**
    - Daily automated backups (configured above)
    - Test restore periodically

4. **Update regularly**
   ```bash
   sudo apt update && sudo apt upgrade
   ```

5. **Monitor logs**
   ```bash
   sudo tail -f /var/log/postgresql/postgresql-17-main.log
   ```

---

## Deploy Your Application

### 1. Update .env file

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public"
```

### 2. Run Prisma Migrations

```bash
cd /var/www/your-app
npx prisma generate
npx prisma migrate deploy
```

### 3. Verify Tables

```bash
psql -U appuser -d directory_db -h localhost -c "\dt"
```

---

## Quick Start Checklist

- [ ] Connected to EC2 instance
- [ ] System updated
- [ ] PostgreSQL 17 installed
- [ ] Database created
- [ ] User created with password
- [ ] Permissions granted
- [ ] Configuration optimized
- [ ] SQL file uploaded
- [ ] SQL file imported
- [ ] Import verified
- [ ] Backup script created
- [ ] Daily backup scheduled
- [ ] Connection string configured
- [ ] Application deployed

---

## Done! ✅

Your PostgreSQL 17 database is now installed, configured, and your data is imported.

**Connection String:**

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public"
```
---
## For Local Development (Via SSH Tunnel)
If running Next.js on your local machine, first create SSH tunnel:
```bash
bashssh -i "your-key.pem" -L 5433:localhost:5432 ubuntu@13.203.106.129 -N
```
Then use:
env# .env.local (on your local machine)

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5433/directory_db?schema=public"
# or
DATABASE_URL="postgresql://appuser:YourStrongPassword123@27.0.0.1:5433/directory_db?schema=public"
```
---

## Note: Port is 5433 (tunnel port), not 5432

### With Connection Pooling (Recommended for Production)

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public&connection_limit=20&pool_timeout=30"
```
---

*Document Version: 1.0*
*PostgreSQL Version: 17*
*Ubuntu Version: 24.04 LTS*
*Last Updated: 2024*