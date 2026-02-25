# Complete PostgreSQL Installation Guide for AWS EC2

> **Instance:** t3.medium | **OS:** Ubuntu Server 24.04 | **Storage:** 30GB

---

## Table of Contents

1. [Connect to EC2 Instance](#step-1-connect-to-your-ec2-instance)
2. [Update System](#step-2-update-system)
3. [Install PostgreSQL 16](#step-3-install-postgresql-16)
4. [Verify Installation](#step-4-verify-postgresql-is-running)
5. [Create Database and User](#step-5-create-database-and-user)
6. [Configure PostgreSQL](#step-6-configure-postgresql)
7. [Test Connection](#step-7-test-connection)
8. [Create Backup Script](#step-8-create-backup-script)
9. [Connection String](#step-9-your-connection-string)
10. [Quick Reference Commands](#step-10-quick-reference-commands)
11. [Verification Checklist](#verification-checklist)

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

## Step 3: Install PostgreSQL 16

```bash
# Add PostgreSQL official repository
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'

# Import repository signing key
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/pgdg.asc > /dev/null

# Update package list
sudo apt update

# Install PostgreSQL 16
sudo apt install -y postgresql-16 postgresql-contrib-16

# Verify installation
psql --version
```

**Expected output:**

```
psql (PostgreSQL) 16.x
```

---

## Step 4: Verify PostgreSQL is Running

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

## Step 5: Create Database and User

### 5.1 Switch to postgres user and access psql

```bash
# Switch to postgres user
sudo -i -u postgres

# Access PostgreSQL
psql
```

### 5.2 Run SQL Commands

```sql
-- Create application user (change password!)
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

### 5.3 Exit postgres user

```bash
exit
```

---

## Step 6: Configure PostgreSQL

### 6.1 Edit Main Configuration

```bash
sudo nano /etc/postgresql/16/main/postgresql.conf
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

### 6.2 Edit Authentication Configuration

```bash
sudo nano /etc/postgresql/16/main/pg_hba.conf
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

### 6.3 Restart PostgreSQL

```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql
```

---

## Step 7: Test Connection

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

## Step 8: Create Backup Script

### 8.1 Create the Script

```bash
sudo nano /usr/local/bin/backup-postgres.sh
```

**Paste this content:**

```bash
#!/bin/bash

BACKUP_DIR="/var/backups/postgresql"
DB_NAME="directory_db"
DB_USER="appuser"
DB_PASSWORD="YourStrongPassword123"
RETENTION_DAYS=7
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

PGPASSWORD=$DB_PASSWORD pg_dump -U $DB_USER -h localhost $DB_NAME | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup completed: ${DB_NAME}_${DATE}.sql.gz"
```

**Save:** `Ctrl + O` → `Enter` → `Ctrl + X`

### 8.2 Make Script Executable

```bash
sudo chmod +x /usr/local/bin/backup-postgres.sh
```

### 8.3 Test Backup

```bash
sudo /usr/local/bin/backup-postgres.sh
```

### 8.4 Schedule Daily Backup

```bash
sudo crontab -e
```

**Add this line:**

```bash
0 2 * * * /usr/local/bin/backup-postgres.sh >> /var/log/postgres-backup.log 2>&1
```

**Save and exit.**

---

## Step 9: Your Connection String

Use this in your `.env` file:

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public"
```

### With Connection Pooling (Recommended for Production)

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public&connection_limit=20&pool_timeout=30"
```

---

## Step 10: Quick Reference Commands

| Task | Command |
|------|---------|
| Start PostgreSQL | `sudo systemctl start postgresql` |
| Stop PostgreSQL | `sudo systemctl stop postgresql` |
| Restart PostgreSQL | `sudo systemctl restart postgresql` |
| Check Status | `sudo systemctl status postgresql` |
| Access as superuser | `sudo -u postgres psql` |
| Access as appuser | `psql -U appuser -d directory_db -h localhost` |
| List databases | `\l` |
| List tables | `\dt` |
| Describe table | `\d table_name` |
| Exit psql | `\q` |
| Manual backup | `sudo /usr/local/bin/backup-postgres.sh` |
| View logs | `sudo tail -f /var/log/postgresql/postgresql-16-main.log` |
| Check DB size | `psql -U appuser -d directory_db -h localhost -c "SELECT pg_size_pretty(pg_database_size('directory_db'));"` |

---

## Verification Checklist

Run these commands to verify everything works:

```bash
# 1. Check PostgreSQL version
psql --version

# 2. Check service status
sudo systemctl status postgresql

# 3. Test connection
psql -U appuser -d directory_db -h localhost -c "SELECT 'Connection successful!' AS status;"

# 4. Check database size
psql -U appuser -d directory_db -h localhost -c "SELECT pg_size_pretty(pg_database_size('directory_db'));"

# 5. Test backup
sudo /usr/local/bin/backup-postgres.sh
ls -la /var/backups/postgresql/
```

---

## Next Steps: Deploy Your Application

### 1. Run Prisma Migrations

```bash
cd /var/www/your-app
npx prisma generate
npx prisma migrate deploy
```

### 2. Verify Tables Created

```bash
psql -U appuser -d directory_db -h localhost -c "\dt"
```

---

## Troubleshooting

### Cannot Connect to Database

```bash
# Check if PostgreSQL is running
sudo systemctl status postgresql

# Check logs
sudo tail -50 /var/log/postgresql/postgresql-16-main.log

# Verify pg_hba.conf settings
sudo cat /etc/postgresql/16/main/pg_hba.conf | grep -v "^#" | grep -v "^$"
```

### Permission Denied Errors

```bash
# Reconnect as postgres and grant permissions
sudo -u postgres psql -d directory_db

GRANT ALL ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
\q
```

### Reset User Password

```bash
sudo -u postgres psql

ALTER USER appuser WITH PASSWORD 'NewPassword123';
\q
```

### Check Active Connections

```bash
sudo -u postgres psql -c "SELECT * FROM pg_stat_activity WHERE datname = 'directory_db';"
```

---

## Security Recommendations

1. **Use strong passwords** - Generate with: `openssl rand -base64 32`
2. **Keep PostgreSQL local** - Don't expose port 5432 to internet
3. **Regular backups** - Daily automated backups configured above
4. **Update regularly** - `sudo apt update && sudo apt upgrade`
5. **Monitor logs** - Check for suspicious activity

---

## Memory Settings Reference

| VPS RAM | shared_buffers | effective_cache_size | work_mem |
|---------|----------------|----------------------|----------|
| 2GB | 512MB | 1.5GB | 16MB |
| 4GB | 1GB | 3GB | 32MB |
| 8GB | 2GB | 6GB | 64MB |
| 16GB | 4GB | 12GB | 128MB |

---

## Done! ✅

Your PostgreSQL database is now installed and configured on your AWS EC2 instance.

**Connection String:**

```env
DATABASE_URL="postgresql://appuser:YourStrongPassword123@localhost:5432/directory_db?schema=public"
```

---

*Document created: 2024*
*PostgreSQL Version: 16*
*Ubuntu Version: 24.04 LTS*
