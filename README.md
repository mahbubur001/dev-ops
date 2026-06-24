# 🛠️ DevOps Knowledge Base

> A structured collection of server setup, database management, and automation guides.

---

## 📋 Table of Contents

- [Infrastructure Overview](#-infrastructure-overview)
- [PostgreSQL Guides](#-postgresql-guides)
- [Server Management](#-server-management)
- [Quick Reference](#-quick-reference)

---

## 🏗️ Infrastructure Overview

| Resource | Details |
|---|---|
| **Hetzner Server** | `87.99.130.89` — Ubuntu 24, 4 vCPU / 16GB RAM |
| **AWS EC2** | `t3.medium` — Ubuntu 24.04, 30GB Storage |
| **Database** | PostgreSQL 17 |
| **Hetzner DB** | `bikribd` / user `bikribdu` |

---

## 🐘 PostgreSQL Guides

### Installation

| Guide | Platform | Description |
|---|---|---|
| [PostgreSQL 17 Installation](Instructions/complete-postgresql-17-installation-guide-for-aws-ec2.md) | AWS EC2 | Full install — system setup, DB creation, config, import, backup |

### Backup & Recovery

| Guide | Description |
|---|---|
| [Auto Backup Guide](Instructions/postgresql-auto-backup-guide.md) | Cron-based daily backups — local, S3, tiered retention, restore steps |

### Remote Access

| Guide | Description |
|---|---|
| [Remote Access — Hetzner](Instructions/postgresql-remote-access-hetzner.md) | IP allowlist via `pg_hba.conf` + UFW, SSH tunnel fallback, status checks |

---

## ⚙️ Server Management

| Guide | Description |
|---|---|
| [Server Management Scripts](Instructions/server-management-scripts.md) | All five `/usr/local/bin/` scripts — backup, restore, DB create, health check, security audit |

### Scripts on Server

```
/usr/local/bin/
├── pg-backup.sh       ← daily database backup with retention
├── pg-restore.sh      ← restore from backup file
├── pg-create-db.sh    ← create new database + user
├── health-check.sh    ← server resource & service report
└── security-check.sh  ← security posture audit
```

---

## ⚡ Quick Reference

```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Run health check
sudo /usr/local/bin/health-check.sh

# Manual backup
sudo /usr/local/bin/pg-backup.sh

# SSH tunnel (local port 5433 → remote 5432)
ssh -L 5433:localhost:5432 deploy@87.99.130.89 -N -C

# View firewall rules
sudo ufw status
```

---

> **Server:** Hetzner `87.99.130.89` &nbsp;|&nbsp; **DB Port:** `5432` &nbsp;|&nbsp; **Maintained by:** Mahbubur Rahman
