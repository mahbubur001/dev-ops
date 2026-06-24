[← Back to Home](../README.md)

# Upload Files & Folders — Local to Server

> Transfer files from your local machine to a remote server using SCP, Rsync, or SFTP.

---

## Table of Contents

1. [SCP — Simple File Copy](#method-1-scp--simple-file-copy)
2. [Rsync — Sync Folders (Recommended)](#method-2-rsync--sync-folders-recommended)
3. [SFTP — Interactive Transfer](#method-3-sftp--interactive)
4. [Common Scenarios](#common-scenarios)
5. [Quick Reference](#quick-reference)

---

## Method 1: SCP — Simple File Copy

Best for: single files or small directories.

### Upload a single file

```bash
scp /local/path/to/file.txt ubuntu@<server-ip>:/remote/path/
```

### Upload with SSH key

```bash
scp -i ~/.ssh/your-key.pem /local/path/to/file.txt ubuntu@<server-ip>:/remote/path/
```

### Upload an entire folder

```bash
scp -r /local/path/to/folder ubuntu@<server-ip>:/remote/path/
```

### Upload with SSH key + folder

```bash
scp -i ~/.ssh/your-key.pem -r /local/path/to/folder ubuntu@<server-ip>:/remote/path/
```

### Download from server to local

```bash
scp ubuntu@<server-ip>:/remote/path/file.txt /local/destination/
```

---

## Method 2: Rsync — Sync Folders (Recommended)

Best for: large folders, repeated uploads, only transferring changed files.

### Upload a folder

```bash
rsync -avz /local/path/to/folder/ ubuntu@<server-ip>:/remote/path/folder/
```

### Upload with SSH key

```bash
rsync -avz -e "ssh -i ~/.ssh/your-key.pem" /local/path/to/folder/ ubuntu@<server-ip>:/remote/path/folder/
```

### Upload and delete files on server that no longer exist locally

```bash
rsync -avz --delete /local/path/to/folder/ ubuntu@<server-ip>:/remote/path/folder/
```

### Exclude files or folders

```bash
rsync -avz \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.git' \
  /local/path/to/project/ ubuntu@<server-ip>:/var/www/project/
```

### Dry run (preview what would be transferred)

```bash
rsync -avz --dry-run /local/path/to/folder/ ubuntu@<server-ip>:/remote/path/folder/
```

**Flags explained:**

| Flag | Meaning |
|---|---|
| `-a` | Archive mode — preserves permissions, timestamps, symlinks |
| `-v` | Verbose output |
| `-z` | Compress during transfer |
| `--delete` | Remove files on server not present locally |
| `--dry-run` | Preview only, no actual transfer |

---

## Method 3: SFTP — Interactive

Best for: browsing the server and uploading/downloading interactively.

### Connect

```bash
sftp ubuntu@<server-ip>
```

### Connect with SSH key

```bash
sftp -i ~/.ssh/your-key.pem ubuntu@<server-ip>
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

### Deploy a Next.js / Node.js project

```bash
rsync -avz \
  --exclude 'node_modules' \
  --exclude '.env' \
  --exclude '.git' \
  --exclude '.next' \
  /local/path/to/project/ ubuntu@<server-ip>:/var/www/project/
```

Then on the server:

```bash
cd /var/www/project
npm install
npm run build
sudo systemctl restart your-app
```

### Upload a SQL backup file

```bash
scp /local/backups/db-backup.sql.gz ubuntu@<server-ip>:/home/ubuntu/
```

### Upload an SSL certificate

```bash
scp -i ~/.ssh/your-key.pem /local/path/fullchain.pem ubuntu@<server-ip>:/etc/ssl/certs/
scp -i ~/.ssh/your-key.pem /local/path/privkey.pem ubuntu@<server-ip>:/etc/ssl/private/
```

### Upload a config or .env file

```bash
scp .env.production ubuntu@<server-ip>:/var/www/project/.env
```

### Sync a media/uploads folder

```bash
rsync -avz --progress /local/uploads/ ubuntu@<server-ip>:/var/www/project/public/uploads/
```

---

## Quick Reference

| Task | Command |
|---|---|
| Upload file (password) | `scp file.txt ubuntu@<ip>:/path/` |
| Upload file (SSH key) | `scp -i key.pem file.txt ubuntu@<ip>:/path/` |
| Upload folder | `scp -r folder/ ubuntu@<ip>:/path/` |
| Sync folder (rsync) | `rsync -avz folder/ ubuntu@<ip>:/path/` |
| Sync + exclude node_modules | `rsync -avz --exclude 'node_modules' folder/ ubuntu@<ip>:/path/` |
| Download file | `scp ubuntu@<ip>:/remote/file.txt ./` |
| Download folder | `scp -r ubuntu@<ip>:/remote/folder/ ./` |
| Interactive session | `sftp ubuntu@<ip>` |

---

## Tips

- Always use a **trailing slash** on the source path with rsync — `folder/` syncs the *contents*, `folder` syncs the folder itself
- Use `--dry-run` first on large transfers to verify what will change
- For large files, add `--progress` flag to rsync to see transfer speed
- Prefer rsync over scp for folders — it only transfers changed files on repeat runs

---

*Document Version: 1.0*
*Last Updated: 2026*
