[← Back to Home](../README.md)

# Upload Files & Folders — Local to Server

> Transfer files from your local machine to a remote server using SCP, Rsync, or SFTP.

---

## Table of Contents

1. [Connection Types](#connection-types)
2. [SCP — Simple File Copy](#method-1-scp--simple-file-copy)
3. [Rsync — Sync Folders (Recommended)](#method-2-rsync--sync-folders-recommended)
4. [SFTP — Interactive Transfer](#method-3-sftp--interactive)
5. [Common Scenarios](#common-scenarios)
6. [Quick Reference](#quick-reference)

---

## Connection Types

Different servers authenticate differently. Use the right form for your server:

| Server Type | Auth Method | Example |
|---|---|---|
| **Hetzner / DigitalOcean / VPS** | Password or SSH key (`~/.ssh/id_rsa`) | `deploy@<ip>` |
| **AWS EC2** | `.pem` key file | `ubuntu@<ip> -i key.pem` |
| **Any server with SSH key added** | Standard SSH key | `user@<ip>` (no `-i` needed if key is in `~/.ssh/`) |

### Hetzner / password-based servers

If your server uses a password, SSH/SCP/Rsync will prompt for it automatically — no extra flags needed:

```bash
scp file.txt deploy@<server-ip>:/remote/path/
```

### Hetzner / SSH key (no .pem)

If you added your public key to the server (`~/.ssh/authorized_keys`), it works without any flag if your key is the default (`~/.ssh/id_rsa` or `~/.ssh/id_ed25519`):

```bash
scp file.txt deploy@<server-ip>:/remote/path/
```

If your key has a custom name:

```bash
scp -i ~/.ssh/hetzner_key file.txt deploy@<server-ip>:/remote/path/
```

### AWS EC2 (.pem file)

```bash
scp -i ~/.ssh/your-key.pem file.txt ubuntu@<server-ip>:/remote/path/
```

---

## Method 1: SCP — Simple File Copy

Best for: single files or small directories.

### Upload a single file

```bash
# Hetzner / VPS (password or default SSH key)
scp /local/path/to/file.txt deploy@<server-ip>:/remote/path/

# AWS EC2 (.pem key)
scp -i ~/.ssh/your-key.pem /local/path/to/file.txt ubuntu@<server-ip>:/remote/path/

# Custom SSH key name
scp -i ~/.ssh/hetzner_key /local/path/to/file.txt deploy@<server-ip>:/remote/path/
```

### Upload an entire folder

```bash
# Hetzner / VPS
scp -r /local/path/to/folder deploy@<server-ip>:/remote/path/

# AWS EC2
scp -i ~/.ssh/your-key.pem -r /local/path/to/folder ubuntu@<server-ip>:/remote/path/
```

### Download from server to local

```bash
# Hetzner / VPS
scp deploy@<server-ip>:/remote/path/file.txt /local/destination/

# AWS EC2
scp -i ~/.ssh/your-key.pem ubuntu@<server-ip>:/remote/path/file.txt /local/destination/
```

---

## Method 2: Rsync — Sync Folders (Recommended)

Best for: large folders, repeated uploads, only transferring changed files.

### Upload a folder

```bash
# Hetzner / VPS (password or default SSH key)
rsync -avz /local/path/to/folder/ deploy@<server-ip>:/remote/path/folder/

# AWS EC2 (.pem key)
rsync -avz -e "ssh -i ~/.ssh/your-key.pem" /local/path/to/folder/ ubuntu@<server-ip>:/remote/path/folder/

# Custom SSH key
rsync -avz -e "ssh -i ~/.ssh/hetzner_key" /local/path/to/folder/ deploy@<server-ip>:/remote/path/folder/
```

### Upload and delete files no longer present locally

```bash
rsync -avz --delete /local/path/to/folder/ deploy@<server-ip>:/remote/path/folder/
```

### Exclude files or folders

```bash
rsync -avz \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.git' \
  /local/path/to/project/ deploy@<server-ip>:/var/www/project/
```

### Dry run (preview without transferring)

```bash
rsync -avz --dry-run /local/path/to/folder/ deploy@<server-ip>:/remote/path/folder/
```

**Flags explained:**

| Flag | Meaning |
|---|---|
| `-a` | Archive mode — preserves permissions, timestamps, symlinks |
| `-v` | Verbose output |
| `-z` | Compress during transfer |
| `--delete` | Remove files on server not present locally |
| `--dry-run` | Preview only, no actual transfer |
| `--progress` | Show per-file transfer speed |

---

## Method 3: SFTP — Interactive

Best for: browsing the server and uploading/downloading interactively.

### Connect

```bash
# Hetzner / VPS (password or default SSH key)
sftp deploy@<server-ip>

# AWS EC2
sftp -i ~/.ssh/your-key.pem ubuntu@<server-ip>

# Custom SSH key
sftp -i ~/.ssh/hetzner_key deploy@<server-ip>
```

### Common SFTP commands

```bash
# List remote files
ls

# Change remote directory
cd /var/www/project

# List local files
lls

# Change local directory
lcd /local/path

# Upload a file
put file.txt

# Upload a folder
put -r folder/

# Download a file
get file.txt

# Download a folder
get -r folder/

# Exit
exit
```

---

## Common Scenarios

### Deploy a Next.js / Node.js project (Hetzner)

```bash
rsync -avz \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.git' \
  --exclude '.next' \
  /local/path/to/project/ deploy@<server-ip>:/var/www/project/
```

Then on the server:

```bash
cd /var/www/project
npm install
npm run build
sudo systemctl restart your-app
```

### Deploy a Next.js / Node.js project (AWS EC2)

```bash
rsync -avz \
  -e "ssh -i ~/.ssh/your-key.pem" \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.git' \
  --exclude '.next' \
  /local/path/to/project/ ubuntu@<server-ip>:/var/www/project/
```

### Upload a SQL backup file

```bash
# Hetzner
scp /local/backups/db-backup.sql.gz deploy@<server-ip>:/home/deploy/

# AWS EC2
scp -i ~/.ssh/your-key.pem /local/backups/db-backup.sql.gz ubuntu@<server-ip>:/home/ubuntu/
```

### Upload a config or .env file

```bash
# Hetzner
scp .env.production deploy@<server-ip>:/var/www/project/.env

# AWS EC2
scp -i ~/.ssh/your-key.pem .env.production ubuntu@<server-ip>:/var/www/project/.env
```

### Sync a media/uploads folder

```bash
rsync -avz --progress /local/uploads/ deploy@<server-ip>:/var/www/project/public/uploads/
```

### Upload an SSL certificate

```bash
scp /local/path/fullchain.pem deploy@<server-ip>:/etc/ssl/certs/
scp /local/path/privkey.pem deploy@<server-ip>:/etc/ssl/private/
```

---

## Quick Reference

| Task | Hetzner / VPS | AWS EC2 |
|---|---|---|
| Upload file | `scp file.txt deploy@<ip>:/path/` | `scp -i key.pem file.txt ubuntu@<ip>:/path/` |
| Upload folder | `scp -r folder/ deploy@<ip>:/path/` | `scp -i key.pem -r folder/ ubuntu@<ip>:/path/` |
| Sync folder | `rsync -avz folder/ deploy@<ip>:/path/` | `rsync -avz -e "ssh -i key.pem" folder/ ubuntu@<ip>:/path/` |
| Download file | `scp deploy@<ip>:/file.txt ./` | `scp -i key.pem ubuntu@<ip>:/file.txt ./` |
| Interactive | `sftp deploy@<ip>` | `sftp -i key.pem ubuntu@<ip>` |

---

## Tips

- **Hetzner/VPS with default SSH key** — if `~/.ssh/id_rsa` or `~/.ssh/id_ed25519` is already added to the server, no `-i` flag is needed
- **Password auth** — SCP/Rsync/SFTP will prompt for password automatically; no extra flags
- Always use a **trailing slash** with rsync source — `folder/` syncs *contents*, `folder` syncs the folder itself
- Use `--dry-run` before large transfers to verify what will change
- Add `--progress` to rsync for per-file transfer speed

---

*Document Version: 2.0*
*Last Updated: 2026*
