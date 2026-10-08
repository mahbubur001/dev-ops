[← Back to Home](../README.md)

# Server Management Scripts

Executable copies of the `/usr/local/bin/` scripts documented in
[`Instructions/server-management-scripts.md`](../Instructions/server-management-scripts.md).
SCP these to a server instead of copy-pasting from the guide.

| Script | Purpose |
|---|---|
| `pg-manage.sh` | Interactive colored-menu launcher for all scripts below |
| `pg-backup.sh` | Daily automated PostgreSQL backup with retention |
| `pg-restore.sh` | Restore from a backup file |
| `pg-create-db.sh` | Create a new database and user |
| `pg-drop-db.sh` | Drop a database (+ optional role) with a forced safety backup |
| `pg-rename.sh` | Rename a database and/or user with a forced safety backup |
| `pg-export.sh` | Copy/create a dump into `~/downloads/` for SCP off the server |
| `health-check.sh` | Server resource & service health report (Hetzner-tuned) |
| `health-check-aws.sh` | Health report adapted for the AWS box (ports 3000–3003, graceful when services absent) |
| `security-check.sh` | Security posture audit with optional email alerts |
| `server-setup-menu.sh` | Interactive new-server provisioner (mirrors the AWS setup + PG18 install guides) |
| `migrate-db-interactive.sh` | DB migration between servers — **run from your laptop**, not installed on a server |

> **Note:** `health-check.sh`, `security-check.sh`, and the port/domain lists inside
> several scripts are tuned for the **Hetzner** server (ports 4000–4002, `bikribd.com`,
> radiusdirectory certs). Edit those constants before running on the AWS box, or use
> `health-check-aws.sh` which is already adapted.

## Install on a server

```bash
# From your local machine (repo root) — copy the server scripts up
# (migrate-db-interactive.sh is excluded; it runs from your laptop)
scp $(ls scripts/*.sh | grep -v migrate-db-interactive) deploy@<server-ip>:/tmp/
# AWS EC2 with a .pem key: scp -i ~/.ssh/your-key.pem ... ubuntu@<server-ip>:/tmp/

# On the server — move into place and make executable
# (deploy must be in the sudo group: sudo usermod -aG sudo deploy, then re-login)
ssh deploy@<server-ip>
sudo mv /tmp/pg-*.sh /tmp/health-check*.sh /tmp/security-check.sh /tmp/server-setup-menu.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/{pg-*,health-check*,security-check,server-setup-menu}.sh

# Launch the interactive menu
sudo /usr/local/bin/pg-manage.sh
```

Full documentation, usage, and cron setup for each script:
[`Instructions/server-management-scripts.md`](../Instructions/server-management-scripts.md)
