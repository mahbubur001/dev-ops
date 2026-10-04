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

> **Note:** `health-check.sh`, `security-check.sh`, and the port/domain lists inside
> several scripts are tuned for the **Hetzner** server (ports 4000–4002, `bikribd.com`,
> radiusdirectory certs). Edit those constants before running on the AWS box, or use
> `health-check-aws.sh` which is already adapted.

## Install on a server

```bash
# From your local machine — copy all scripts up
scp scripts/*.sh deploy@<server-ip>:/tmp/

# On the server — move into place and make executable
ssh deploy@<server-ip>
sudo mv /tmp/pg-*.sh /tmp/health-check*.sh /tmp/security-check.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/{pg-backup,pg-restore,pg-create-db,pg-drop-db,pg-rename,pg-export,health-check,security-check,pg-manage}.sh

# Launch the interactive menu
sudo /usr/local/bin/pg-manage.sh
```

Full documentation, usage, and cron setup for each script:
[`Instructions/server-management-scripts.md`](../Instructions/server-management-scripts.md)
