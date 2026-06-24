[← Back to Home](../README.md)

# PostgreSQL Database Migration — Server to Server

> Move a PostgreSQL database from one server to another with zero data loss.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Method 1: Direct Dump & Restore (Recommended)](#method-1-direct-dump--restore-recommended)
4. [Method 2: Dump File via Local Machine](#method-2-dump-file-via-local-machine)
5. [Method 3: pg_basebackup (Full Cluster)](#method-3-pg_basebackup-full-cluster)
6. [Verify Migration](#verify-migration)
7. [Update Application Config](#update-application-config)
8. [Troubleshooting](#troubleshooting)

---

## Overview

| Term | Meaning |
|---|---|
| **Source server** | Old server — where data currently lives |
| **Target server** | New server — where data is being moved to |

---

## Prerequisites

- PostgreSQL installed on **target server** (same or newer version than source)
- SSH access to both servers
- Database credentials on source server

Check versions:

```bash
# On source server
psql --version

# On target server
psql --version
```

> Target PostgreSQL version must be **equal to or newer** than source.

---

## Method 1: Direct Dump & Restore (Recommended)

Streams the dump directly from source to target — no intermediate file needed.

### Step 1: Test SSH from target to source

Run this on the **target server**:

```bash
ssh ubuntu@<source-server-ip> "echo connected"
```

### Step 2: Stream dump from source and restore on target

Run this on the **target server**:

```bash
ssh ubuntu@<source-server-ip> \
  "PGPASSWORD=<source-db-password> pg_dump -U <source-db-user> -h localhost -Fc <source-db-name>" \
  | PGPASSWORD=<target-db-password> pg_restore -U <target-db-user> -h localhost -d <target-db-name> --no-owner --role=<target-db-user> -v
```

**Replace:**
- `<source-server-ip>` — IP of old server
- `<source-db-user>` — DB user on old server (e.g. `appuser`)
- `<source-db-password>` — password on old server
- `<source-db-name>` — database name on old server (e.g. `directory_db`)
- `<target-db-user>` — DB user on new server
- `<target-db-password>` — password on new server
- `<target-db-name>` — database name on new server

---

## Method 2: Dump File via Local Machine

Use this when direct SSH between servers is not possible.

### Step 1: Dump on source server

```bash
PGPASSWORD=<source-db-password> pg_dump \
  -U <source-db-user> \
  -h localhost \
  -Fc \
  <source-db-name> > /tmp/db-migration.dump
```

### Step 2: Download dump to local machine

```bash
scp ubuntu@<source-server-ip>:/tmp/db-migration.dump ./db-migration.dump
```

### Step 3: Upload dump to target server

```bash
scp ./db-migration.dump ubuntu@<target-server-ip>:/tmp/db-migration.dump
```

### Step 4: Restore on target server

```bash
# SSH into target server
ssh ubuntu@<target-server-ip>

# Restore
PGPASSWORD=<target-db-password> pg_restore \
  -U <target-db-user> \
  -h localhost \
  -d <target-db-name> \
  --no-owner \
  --role=<target-db-user> \
  -v \
  /tmp/db-migration.dump

# Clean up
rm /tmp/db-migration.dump
```

---

## Method 3: pg_basebackup (Full Cluster)

Use this to migrate the **entire PostgreSQL cluster** (all databases, users, roles).

> Requires stopping the source server during the final sync. Use only for full server migrations.

### Step 1: On target server — stop PostgreSQL and clear data dir

```bash
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/18/main/*
```

### Step 2: Run pg_basebackup from target pointing at source

```bash
sudo -u postgres pg_basebackup \
  -h <source-server-ip> \
  -U postgres \
  -D /var/lib/postgresql/18/main \
  -P -Xs -R
```

Enter source postgres password when prompted.

### Step 3: Start PostgreSQL on target

```bash
sudo systemctl start postgresql
sudo systemctl status postgresql
```

---

## Verify Migration

Run on **target server** after restore:

```bash
psql -U <target-db-user> -h localhost -d <target-db-name>
```

```sql
-- Count tables
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';

-- Check row counts (replace with your key tables)
SELECT COUNT(*) FROM users;
SELECT COUNT(*) FROM listings;

-- Check database size
SELECT pg_size_pretty(pg_database_size('<target-db-name>'));

\q
```

Compare counts against source server to confirm data integrity.

---

## Update Application Config

Update your `.env` on the application server:

```env
DATABASE_URL="postgresql://<target-db-user>:<target-db-password>@localhost:5432/<target-db-name>?schema=public"
```

Then run Prisma migrations if needed:

```bash
npx prisma generate
npx prisma migrate deploy
```

Restart your application:

```bash
sudo systemctl restart your-app
```

---

## Troubleshooting

### Error: role does not exist

```bash
sudo -u postgres psql -c "CREATE USER <target-db-user> WITH PASSWORD '<password>';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE <target-db-name> TO <target-db-user>;"
```

### Error: database does not exist

```bash
sudo -u postgres psql -c "CREATE DATABASE <target-db-name>;"
```

### Error: permission denied for schema public

```bash
sudo -u postgres psql -d <target-db-name> -c "GRANT ALL ON SCHEMA public TO <target-db-user>;"
sudo -u postgres psql -d <target-db-name> -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO <target-db-user>;"
sudo -u postgres psql -d <target-db-name> -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO <target-db-user>;"
```

### Error: pg_restore version mismatch

```bash
# Check versions
pg_dump --version
pg_restore --version

# Use source server's pg_dump binary explicitly
/usr/lib/postgresql/18/bin/pg_dump ...
```

### Check active connections before drop

```bash
sudo -u postgres psql -c "SELECT pid, usename, client_addr FROM pg_stat_activity WHERE datname = '<db-name>';"

# Terminate all connections
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '<db-name>' AND pid <> pg_backend_pid();"
```

---

*Document Version: 1.0*
*PostgreSQL Version: 18*
*Ubuntu Version: 24.04 LTS*
*Last Updated: 2026*
