[← Back to Home](../README.md)

# Migrate a Database — AWS → AWS (PG17 → PG18)

> **Source:** old AWS box (`13.202.89.114`) · PostgreSQL 17 · peer auth | **Target:** new AWS t4g.medium (`34.229.145.66`) · PostgreSQL 18 · peer auth

Move one or more PostgreSQL databases from an old AWS server to a freshly-provisioned one using a **gzipped plain-SQL dump** relayed through your laptop. Restoring a PG17 dump into PG18 is fully supported (logical dumps are forward-compatible).

Both servers use peer auth, so no DB passwords are needed — `sudo -u postgres` authenticates locally. Each server has its own `.pem`, so the dump is relayed through your laptop rather than streamed server-to-server.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Method: Gzip Dump via Laptop (Easy)](#method-gzip-dump-via-laptop-easy)
- [One-Command Script](#one-command-script)
- [Verify](#verify)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- SSH access to both servers (their respective `.pem` files on your laptop)
- PostgreSQL 18 installed on the target ([install guide](complete-postgresql-18-installation-guide-for-aws-ec2.md))
- Target database **and** role already created:

```bash
# on target, as postgres
sudo -u postgres createuser bundles_radiusapps_user --pwprompt
sudo -u postgres createdb -O bundles_radiusapps_user bundles_radiusapps
```

> ⚠️ **Do not** copy the raw data directory (`/var/lib/postgresql/17/`) — the physical format differs across majors and won't start on 18. Use a logical dump (below).

---

## Method: Gzip Dump via Laptop (Easy)

### Step 1 — List databases on the source

```bash
# on SOURCE
sudo -u postgres psql -l
```

### Step 2 — Dump + gzip on the source

```bash
# on SOURCE (no password — peer auth)
sudo -u postgres pg_dump bundles_radiusapps | gzip > /tmp/bundles_radiusapps_db.sql.gz
```

### Step 3 — Download to laptop

```bash
# on LAPTOP
scp -i ~/dev/source-key.pem ubuntu@13.202.89.114:/tmp/bundles_radiusapps_db.sql.gz ~/
```

### Step 4 — Upload to target

```bash
# on LAPTOP
scp -i ~/dev/shopify.pem ~/bundles_radiusapps_db.sql.gz ubuntu@34.229.145.66:/tmp/
```

### Step 5 — Restore on the target

```bash
# on TARGET (DB must already exist)
gunzip -c /tmp/bundles_radiusapps_db.sql.gz | sudo -u postgres psql -d bundles_radiusapps
```

Repeat for each database (e.g. a `_staging_` counterpart).

---

## One-Command Script

[`scripts/migrate-db-interactive.sh`](../scripts/migrate-db-interactive.sh) runs the whole flow from your **laptop** and prompts for every value (source/target IP, SSH user, `.pem` path, DB name). It dumps → downloads → uploads → restores → prints `\dt` → cleans up all temp files.

```bash
./scripts/migrate-db-interactive.sh
```

- Uses `sudo -u postgres` on both servers — no DB passwords (needs passwordless sudo for the SSH user, default on AWS Ubuntu)
- Target DB must already exist
- One database per run — run again for prod + staging

---

## Verify

```bash
# on TARGET
sudo -u postgres psql -d bundles_radiusapps -c "\dt"
sudo -u postgres psql -d bundles_radiusapps -c "SELECT count(*) FROM <a_known_table>;"
```

Tables listed and row counts matching the source → migration succeeded.

---

## Cleanup

```bash
rm /tmp/bundles_radiusapps_db.sql.gz   # on source, target, and laptop
```

---

## Troubleshooting

### `Permission denied (publickey)`
The `ssh`/`scp` call is missing `-i <key>.pem`, or the key isn't on the machine running the command. The `.pem` must live on the box you're typing from (laptop for the relay steps).

### `input file is too short (read 0, expected 5)`
The dump step produced an empty file — usually the upstream `ssh`/`pg_dump` failed (often a missing `-i` key). Fix the dump step and re-run; don't restore a 0-byte dump.

### `role "<name>" does not exist`
Create the role on the target before restoring, or add `--no-owner` so objects are owned by the restoring user:

```bash
gunzip -c dump.sql.gz | sudo -u postgres psql -d <db> -v ON_ERROR_STOP=0
```

### Version mismatch
Not an issue for 17 → 18 — newer tools restore older dumps. The reverse (dumping on 18, restoring on 17) is what breaks.

### `pg_basebackup` won't work
Physical clone tools are same-major-version only. Use the logical dump method above for 17 → 18.
