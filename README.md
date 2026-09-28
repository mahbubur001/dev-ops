# 🛠️ DevOps Knowledge Base

> A structured collection of server setup, database management, and automation guides.

---

## 📋 Table of Contents

- [Infrastructure Overview](#-infrastructure-overview)
- [PostgreSQL Guides](#-postgresql-guides)
- [Caching (Redis)](#-caching-redis)
- [File Transfer](#-file-transfer)
- [Application Deployment](#-application-deployment)
- [Server Management](#-server-management)
- [Quick Reference](#-quick-reference)

---

## 🏗️ Infrastructure Overview

| Resource | Details |
|---|---|
| **Hetzner Server** | Ubuntu 24, 4 vCPU / 16GB RAM |
| **AWS EC2** | `t3.medium` — Ubuntu 24.04, 30GB Storage |
| **Database** | PostgreSQL 18 |
| **Hetzner DB** | `bikribd` / user `bikribdu` |

---

## 🐘 PostgreSQL Guides

### Installation

| Guide | Platform | Description |
|---|---|---|
| [PostgreSQL 18 Installation](Instructions/complete-postgresql-18-installation-guide-for-aws-ec2.md) | AWS EC2 | Full install — system setup, DB creation, config, import, backup |

### Migration

| Guide | Description |
|---|---|
| [Migrate Database — Server to Server](Instructions/postgresql-migrate-server-to-server.md) | Dump & restore, direct stream, full cluster migration, verification steps |
| [Migrate Database — Hetzner → AWS](Instructions/migrate-database-hetzner-to-aws.md) | Live DB move: `pg_dump -Fc` → laptop relay → `pg_restore`, re-grants, direct stream for large DBs |

### Backup & Recovery

| Guide | Description |
|---|---|
| [Auto Backup Guide](Instructions/postgresql-auto-backup-guide.md) | Cron-based daily backups — local, S3, tiered retention, restore steps |

### Remote Access

| Guide | Description |
|---|---|
| [Remote Access — Hetzner](Instructions/postgresql-remote-access-hetzner.md) | Two-layer allowlist: `pg_hba.conf` + Hetzner cloud firewall, SSH tunnel fallback, status checks |

---

## 🧰 Caching (Redis)

| Guide | Description |
|---|---|
| [Redis Setup & Hardening](Instructions/redis-setup.md) | Install, localhost-only bind, password (`requirepass`), memory cap, connection string, troubleshooting |

---

## 📁 File Transfer

| Guide | Description |
|---|---|
| [Upload Files & Folders to Server](Instructions/upload-files-to-server.md) | SCP, Rsync, SFTP — single files, folders, project deploys, excludes |

---

## 🚀 Application Deployment

| Guide | Stack | Description |
|---|---|---|
| [Deploy Node.js & Next.js Apps](Instructions/deploy-nodejs-nextjs-apps.md) | PM2 · Nginx · Certbot | Multiple Node/Next.js apps on one server — reverse proxy per domain, SSL, zero-downtime redeploys, 4GB build tuning, pnpm native-build fix |
| [Nginx Reverse Proxy + SSL Behind Cloudflare](Instructions/nginx-reverse-proxy-cloudflare.md) | Cloudflare · Nginx · Certbot | HTTP-only-first config, grey-cloud for Certbot, Full (strict), reusing a config from another server |

**Scripts:** [`scripts/health-check-aws.sh`](scripts/health-check-aws.sh) — health monitor for the AWS box (resources, services, PM2, ports, SSL). SCP to `/usr/local/bin/health-check.sh`.

---

## ⚙️ Server Management

### Initial Setup

| Guide | Platform | Description |
|---|---|---|
| [New Server Setup](Instructions/new-server-setup-aws-t3-medium.md) | AWS t3.medium | First-boot hardening — deploy user, SSH lockdown, UFW, swap, fail2ban, auto-updates, baseline tooling |

### Monitoring & Alerts

| Guide | Description |
|---|---|
| [Email Alerts via AWS SES](Instructions/aws-ses-email-alerts.md) | SES SMTP → `msmtp`/`sendmail` drop-in, `ALERT_EMAIL` env vars, wire into `security-check.sh` + cron, sandbox exit |

### Scripts

| Resource | Description |
|---|---|
| [Server Management Scripts (docs)](Instructions/server-management-scripts.md) | Full documentation + usage for all `/usr/local/bin/` scripts — interactive menu, backup, restore, DB create, DB drop, DB rename, export/download, health check, security audit |
| [`scripts/`](scripts/) | Executable copies ready to SCP to a server — see [scripts/README.md](scripts/README.md) for install steps |

### Scripts on Server

```
/usr/local/bin/
├── pg-manage.sh       ← interactive menu launcher for all scripts below
├── pg-backup.sh       ← daily database backup with retention
├── pg-restore.sh      ← restore from backup file
├── pg-create-db.sh    ← create new database + user
├── pg-drop-db.sh      ← drop a database (+ optional role) with safety backup
├── pg-rename.sh       ← rename a database and/or user with safety backup
├── pg-export.sh       ← copy/create a dump into ~/downloads for SCP off the server
├── health-check.sh    ← server resource & service report
└── security-check.sh  ← security posture audit
```

---

## ⚡ Quick Reference

```bash
# Interactive menu for all PG/server scripts
sudo /usr/local/bin/pg-manage.sh

# Check PostgreSQL status
sudo systemctl status postgresql

# Run health check
sudo /usr/local/bin/health-check.sh

# Manual backup
sudo /usr/local/bin/pg-backup.sh

# SSH tunnel (local port 5433 → remote 5432)
ssh -L 5433:localhost:5432 deploy@<hetzner-ip> -N -C

# Test remote DB access (which pg_hba path an app uses)
PGPASSWORD='<pass>' psql -h <hetzner-ip> -U <user> -d <db> -c "SELECT current_user;"
```

---

> **Server:** Hetzner `<your-server-ip>` &nbsp;|&nbsp; **DB Port:** `5432` &nbsp;|&nbsp; **Maintained by:** Mahbubur Rahman
