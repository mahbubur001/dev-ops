[← Back to Home](../README.md)

# Migrate a Live Database — Hetzner → AWS

> **Source:** Hetzner (`87.99.130.89`) · DB `bikribd` | **Target:** AWS t4g.medium (`13.201.18.86`) · new DB

Move a live PostgreSQL database from the Hetzner server to the newly-provisioned AWS box using `pg_dump` (custom format) → transfer → `pg_restore`. The two servers use different SSH keys, so the dump is relayed through your laptop.

> **Prerequisite:** PostgreSQL 18 installed on AWS and the target database + app user already created (see [PostgreSQL Installation](complete-postgresql-18-installation-guide-for-aws-ec2.md)).

---

## Table of Contents

1. [Check the Source Size](#step-1-check-the-source-size)
2. [Dump on Hetzner](#step-2-dump-on-hetzner)
3. [Transfer Hetzner → AWS](#step-3-transfer-hetzner--aws)
4. [Restore on AWS](#step-4-restore-on-aws)
5. [Verify the Import](#step-5-verify-the-import)
6. [Large Databases (Direct Stream)](#large-databases-direct-stream)
7. [Troubleshooting](#troubleshooting)

---

## Why custom format (`-Fc`)?

`pg_dump -Fc` produces a **compressed, non-text archive** restored with `pg_restore`. Advantages over a plain `.sql` dump:

- Smaller on disk (built-in compression)
- Parallel restore with `-j N` (much faster on multi-core)
- Selective restore (single table/schema) if ever needed
- `pg_restore` flags let you strip the source's ownership/privileges cleanly

---

## Step 1: Check the Source Size

On **Hetzner**, so you can pick the right method (file relay vs direct stream):

```bash
ssh -i ~/dev/hetzner-key deploy@87.99.130.89
sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('bikribd'));"
exit
```

- **< ~1 GB** → use the file-relay method below (Steps 2–4).
- **> ~1 GB** → jump to [Direct Stream](#large-databases-direct-stream).

---

## Step 2: Dump on Hetzner

```bash
ssh -i ~/dev/hetzner-key deploy@87.99.130.89
sudo -u postgres pg_dump -Fc -d bikribd -f /tmp/bikribd.dump

# Confirm the file
ls -lh /tmp/bikribd.dump
exit
```

> `pg_dump` on a live DB is safe — it runs in a consistent snapshot without locking writes.

---

## Step 3: Transfer Hetzner → AWS

The servers use **different keys**, so relay the file through your **local machine**:

```bash
# 1) Pull down from Hetzner
scp -i ~/dev/hetzner-key deploy@87.99.130.89:/tmp/bikribd.dump ~/Downloads/

# 2) Push up to AWS
scp -i ~/dev/internal.pem ~/Downloads/bikribd.dump deploy@13.201.18.86:/tmp/
```

---

## Step 4: Restore on AWS

```bash
ssh -i ~/dev/internal.pem deploy@13.201.18.86

sudo -u postgres pg_restore \
  -d <newdb> \
  --no-owner --no-privileges \
  --clean --if-exists \
  /tmp/bikribd.dump
```

Replace `<newdb>` with the database you created on AWS.

**Flags explained:**

| Flag | Purpose |
|---|---|
| `--no-owner` | Ignore the source owner (`bikribdu`); objects go to the restoring role |
| `--no-privileges` | Skip the source's GRANTs (re-grant to your AWS app user after) |
| `--clean --if-exists` | Drop existing objects first — makes re-runs safe, no "already exists" errors |
| `-j 4` *(optional)* | Restore with 4 parallel jobs — faster on the 2-vCPU box for larger DBs |

### Re-grant privileges to your app user

Since `--no-privileges` stripped GRANTs, give your AWS app user access:

```bash
sudo -u postgres psql -d <newdb> <<'SQL'
GRANT ALL ON SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO appuser;
ALTER SCHEMA public OWNER TO appuser;
SQL
```

Replace `appuser` with your AWS app user.

---

## Step 5: Verify the Import

```bash
# Tables present?
sudo -u postgres psql -d <newdb> -c "\dt"

# Table count
sudo -u postgres psql -d <newdb> -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"

# DB size (compare against Hetzner's from Step 1)
sudo -u postgres psql -d <newdb> -c "SELECT pg_size_pretty(pg_database_size('<newdb>'));"

# Spot-check a known table's row count
sudo -u postgres psql -d <newdb> -c "SELECT COUNT(*) FROM users;"
```

Sizes and row counts should match the source. Clean up the dump when satisfied:

```bash
rm /tmp/bikribd.dump          # on AWS
# and ~/Downloads/bikribd.dump on your laptop
```

---

## Large Databases (Direct Stream)

For DBs over ~1 GB, skip the intermediate file — stream the dump straight from Hetzner into the AWS restore. Run this **from your laptop** (it bridges both SSH connections):

```bash
ssh -i ~/dev/hetzner-key deploy@87.99.130.89 \
  "sudo -u postgres pg_dump -Fc -d bikribd" \
| ssh -i ~/dev/internal.pem deploy@13.201.18.86 \
  "sudo -u postgres pg_restore -d <newdb> --no-owner --no-privileges --clean --if-exists"
```

Add a progress bar (install `pv` on your laptop first — `brew install pv`):

```bash
ssh -i ~/dev/hetzner-key deploy@87.99.130.89 "sudo -u postgres pg_dump -Fc -d bikribd" \
| pv \
| ssh -i ~/dev/internal.pem deploy@13.201.18.86 "sudo -u postgres pg_restore -d <newdb> --no-owner --no-privileges --clean --if-exists"
```

> Trade-off: no disk space needed on either server, but the transfer can't resume if the connection drops. For unstable links, prefer the file-relay method.

---

## Troubleshooting

### `role "bikribdu" does not exist`

The dump references the Hetzner role. `--no-owner --no-privileges` should prevent this — confirm both flags are on the `pg_restore` command.

### `permission denied for schema public`

Run the [re-grant block](#re-grant-privileges-to-your-app-user) so your AWS app user owns/can access the schema.

### Restore is slow

Add parallel jobs (2 vCPU box handles `-j 4` fine on I/O-bound restores):

```bash
sudo -u postgres pg_restore -j 4 -d <newdb> --no-owner --no-privileges --clean --if-exists /tmp/bikribd.dump
```

### `pg_restore: error: could not execute query ... already exists`

You didn't use `--clean --if-exists`, or the DB had partial data. Either add those flags, or drop and recreate the target DB first.

### Version mismatch warning

Restoring a dump from an older PostgreSQL into 18 is fine (forward-compatible). Going backwards (18 → 16) is not supported.

### Verify data actually matches

Compare row counts of your biggest tables on both servers — not just DB size (which includes bloat/indexes that can differ):

```bash
# On each server
sudo -u postgres psql -d <db> -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"
```

---

## Migration Checklist

- [ ] Target DB + app user created on AWS
- [ ] Source size checked → method chosen
- [ ] Dump created on Hetzner (`-Fc`)
- [ ] Dump relayed to AWS (or streamed directly)
- [ ] Restored with `--no-owner --no-privileges --clean --if-exists`
- [ ] Privileges re-granted to AWS app user
- [ ] Table count + row counts verified against source
- [ ] Dump files removed from `/tmp` and laptop
- [ ] App `.env` updated to point at the new AWS database

---

*Document Version: 1.0*
*Source: Hetzner PostgreSQL 18 · Target: AWS t4g.medium PostgreSQL 18*
*Last Updated: 2026*
