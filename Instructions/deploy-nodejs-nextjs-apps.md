[← Back to Home](../README.md)

# Deploy Node.js & Next.js Apps (PM2 + Nginx + SSL)

> **Server:** AWS t4g.medium (Arm64) | **OS:** Ubuntu 24.04 LTS | **Stack:** Node 22 · PM2 · Nginx · Certbot

How to run multiple Node/Next.js apps on one server — a process manager to keep them alive, Nginx as a reverse proxy to route each domain to the right app, and free SSL certificates. Written for **radiustask + 3 Next.js apps** on a single box.

> **Prerequisite:** Server already hardened per [New Server Setup](new-server-setup-aws-t3-medium.md) (deploy user, UFW allowing 80/443, swap enabled).

---

## Table of Contents

1. [Architecture Overview](#step-1-architecture-overview)
2. [Install Node.js 22](#step-2-install-nodejs-22)
3. [Install PM2](#step-3-install-pm2)
4. [Install Nginx](#step-4-install-nginx)
5. [Deploy Your App Code](#step-5-deploy-your-app-code)
6. [Build & Start Each App with PM2](#step-6-build--start-each-app-with-pm2)
7. [Configure Nginx Reverse Proxy](#step-7-configure-nginx-reverse-proxy)
8. [Point Domains to the Server](#step-8-point-domains-to-the-server)
9. [Enable HTTPS with Certbot](#step-9-enable-https-with-certbot)
10. [Persist PM2 Across Reboots](#step-10-persist-pm2-across-reboots)
11. [Updating an App (Redeploy)](#step-11-updating-an-app-redeploy)
12. [Quick Reference](#step-12-quick-reference)
13. [Troubleshooting](#troubleshooting)

---

## Step 1: Architecture Overview

One server, four apps. Each app runs on its **own local port**; Nginx routes each **domain** to the matching port.

```
                        ┌──────────────── Server (internal-server) ────────────────┐
                        │                                                            │
  radiustask.com  ──►   │  Nginx :80/:443  ──►  PM2 ──►  radiustask     (:3000)     │
  app1.com        ──►   │       (reverse        │        nextjs-app-1  (:3001)     │
  app2.com        ──►   │        proxy +        ├──────► nextjs-app-2  (:3002)     │
  app3.com        ──►   │        SSL)           └──────► nextjs-app-3  (:3003)     │
                        │                                                            │
                        └────────────────────────────────────────────────────────────┘
```

| App | Local port | Domain (example) |
|---|---|---|
| radiustask | 3000 | `radiustask.com` |
| nextjs-app-1 | 3001 | `app1.com` |
| nextjs-app-2 | 3002 | `app2.com` |
| nextjs-app-3 | 3003 | `app3.com` |

> Apps bind to `localhost:<port>` only — never exposed directly. Nginx (behind UFW) is the single public entry point.

---

## Step 2: Install Node.js 22

Skip if already installed (`node -v` shows v22.x).

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Verify (arm64 build)
node -v && npm -v
```

---

## Step 3: Install PM2

PM2 is a process manager — it keeps apps running, restarts them on crash, and starts them on boot.

```bash
sudo npm install -g pm2

# Verify
pm2 -v
```

---

## Step 4: Install Nginx

Skip if already installed (`nginx -v`).

```bash
sudo apt install nginx -y
sudo systemctl enable --now nginx
sudo systemctl status nginx
```

Confirm UFW allows web traffic (set during server hardening):

```bash
sudo ufw allow 'Nginx Full'   # opens 80 + 443
sudo ufw status
```

Visit `http://<server-ip>` — you should see the Nginx welcome page.

---

## Step 5: Deploy Your App Code

Put apps under `/var/www/`. Clone from Git (recommended) or upload via SCP.

```bash
sudo mkdir -p /var/www
sudo chown -R deploy:deploy /var/www
cd /var/www

# Clone each repo
git clone https://github.com/you/radiustask.git
git clone https://github.com/you/nextjs-app-1.git
git clone https://github.com/you/nextjs-app-2.git
git clone https://github.com/you/nextjs-app-3.git
```

> Private repos: use a **deploy key** (`ssh-keygen -t ed25519`, add the public key to the repo's Deploy Keys) or a Personal Access Token.

For SCP upload instead, see [Upload Files to Server](upload-files-to-server.md).

---

## Step 6: Build & Start Each App with PM2

For **each** app: install deps, set its port, build, and start under PM2.

### Set the port per app

Next.js reads the `PORT` env var. Assign a unique port to each app. Create a `.env` (or set inline in the PM2 command).

```bash
cd /var/www/radiustask
npm ci                 # clean install from package-lock
npm run build          # production build
PORT=3000 pm2 start npm --name radiustask -- start
```

Repeat for the others:

```bash
cd /var/www/nextjs-app-1 && npm ci && npm run build
PORT=3001 pm2 start npm --name nextjs-app-1 -- start

cd /var/www/nextjs-app-2 && npm ci && npm run build
PORT=3002 pm2 start npm --name nextjs-app-2 -- start

cd /var/www/nextjs-app-3 && npm ci && npm run build
PORT=3003 pm2 start npm --name nextjs-app-3 -- start
```

### Verify all running

```bash
pm2 list
```

```
┌─────┬────────────────┬─────────┬─────────┬──────────┐
│ id  │ name           │ status  │ cpu     │ memory   │
├─────┼────────────────┼─────────┼─────────┼──────────┤
│ 0   │ radiustask     │ online  │ 0%      │ 65mb     │
│ 1   │ nextjs-app-1   │ online  │ 0%      │ 60mb     │
│ 2   │ nextjs-app-2   │ online  │ 0%      │ 60mb     │
│ 3   │ nextjs-app-3   │ online  │ 0%      │ 60mb     │
└─────┴────────────────┴─────────┴─────────┴──────────┘
```

Test locally:

```bash
curl -I http://localhost:3000
```

### Alternative: ecosystem file (cleaner for many apps)

Instead of individual commands, define all apps in one file:

```bash
vim /var/www/ecosystem.config.js
```

```js
module.exports = {
  apps: [
    { name: 'radiustask',   cwd: '/var/www/radiustask',   script: 'npm', args: 'start', env: { PORT: 3000 } },
    { name: 'nextjs-app-1', cwd: '/var/www/nextjs-app-1', script: 'npm', args: 'start', env: { PORT: 3001 } },
    { name: 'nextjs-app-2', cwd: '/var/www/nextjs-app-2', script: 'npm', args: 'start', env: { PORT: 3002 } },
    { name: 'nextjs-app-3', cwd: '/var/www/nextjs-app-3', script: 'npm', args: 'start', env: { PORT: 3003 } },
  ],
}
```

```bash
pm2 start /var/www/ecosystem.config.js
```

---

## Step 7: Configure Nginx Reverse Proxy

One config file per app under `/etc/nginx/sites-available/`, then symlink to `sites-enabled/`.

### Create a server block

```bash
sudo vim /etc/nginx/sites-available/radiustask
```

```nginx
server {
    listen 80;
    server_name radiustask.com www.radiustask.com;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

**Save:** `Esc` → `:wq` → `Enter`

Repeat for each app — change **three things** each time: the filename, `server_name` (domain), and `proxy_pass` port (3001, 3002, 3003).

### Enable the sites

```bash
sudo ln -s /etc/nginx/sites-available/radiustask   /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/nextjs-app-1 /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/nextjs-app-2 /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/nextjs-app-3 /etc/nginx/sites-enabled/

# Remove the default site so it doesn't shadow yours
sudo rm -f /etc/nginx/sites-enabled/default

# Test config, then reload
sudo nginx -t
sudo systemctl reload nginx
```

---

## Step 8: Point Domains to the Server

At your DNS provider (Cloudflare, Namecheap, Route 53), create an **A record** per domain pointing to your server's **Elastic IP**:

| Type | Name | Value |
|---|---|---|
| A | `@` (radiustask.com) | `<elastic-ip>` |
| A | `www` | `<elastic-ip>` |
| A | `app1.com` | `<elastic-ip>` |
| … | … | … |

Verify propagation (may take minutes to hours):

```bash
dig +short radiustask.com
```

> Certbot (next step) requires DNS to resolve to the server **before** it can issue certificates.

---

## Step 9: Enable HTTPS with Certbot

Free, auto-renewing SSL from Let's Encrypt.

```bash
sudo apt install certbot python3-certbot-nginx -y
```

Issue certificates — Certbot edits your Nginx configs to add SSL and redirect HTTP→HTTPS automatically:

```bash
sudo certbot --nginx \
  -d radiustask.com -d www.radiustask.com \
  -d app1.com \
  -d app2.com \
  -d app3.com
```

Choose **redirect** (option 2) when prompted, to force HTTPS.

Certbot installs a renewal timer automatically. Confirm:

```bash
sudo certbot renew --dry-run
systemctl status certbot.timer
```

Visit `https://radiustask.com` — you should see the padlock. 🔒

---

## Step 10: Persist PM2 Across Reboots

By default PM2 apps die on reboot. Two commands fix that.

```bash
# Generate & install the systemd startup script (run the sudo command it prints)
pm2 startup

# Save the current process list as the boot state
pm2 save
```

Test it survives a reboot:

```bash
sudo reboot
# reconnect after ~30s
pm2 list        # all apps should be 'online'
```

---

## Step 11: Updating an App (Redeploy)

To ship new code for one app:

```bash
cd /var/www/radiustask
git pull
npm ci
npm run build
pm2 reload radiustask       # zero-downtime restart
```

> `pm2 reload` restarts gracefully (no dropped requests). `pm2 restart` is a hard restart — use if reload misbehaves.

---

## Step 12: Quick Reference

### PM2

| Task | Command |
|---|---|
| List apps | `pm2 list` |
| App logs (live) | `pm2 logs radiustask` |
| All logs | `pm2 logs` |
| Monitor dashboard | `pm2 monit` |
| Restart one | `pm2 restart radiustask` |
| Reload (zero-downtime) | `pm2 reload radiustask` |
| Stop one | `pm2 stop radiustask` |
| Delete one | `pm2 delete radiustask` |
| Save process list | `pm2 save` |

### Nginx

| Task | Command |
|---|---|
| Test config | `sudo nginx -t` |
| Reload (apply config) | `sudo systemctl reload nginx` |
| Restart | `sudo systemctl restart nginx` |
| Enabled sites | `ls /etc/nginx/sites-enabled/` |
| Access log | `sudo tail -f /var/log/nginx/access.log` |
| Error log | `sudo tail -f /var/log/nginx/error.log` |

### Certbot

| Task | Command |
|---|---|
| List certs | `sudo certbot certificates` |
| Test renewal | `sudo certbot renew --dry-run` |
| Add a domain | `sudo certbot --nginx -d newdomain.com` |

---

## Troubleshooting

### 502 Bad Gateway

Nginx can't reach the app. Check the app is running on the expected port:

```bash
pm2 list
curl -I http://localhost:3000      # match the proxy_pass port
pm2 logs radiustask --lines 50     # look for a crash
```

### App crashes on start

```bash
pm2 logs <app-name> --err          # view error output
# common causes: missing .env, wrong Node version, build not run
```

### Nginx won't reload

```bash
sudo nginx -t                      # shows the exact config error + line
```

### Certbot fails ("challenge failed")

- DNS not pointing to the server yet → `dig +short yourdomain.com` must return the server IP.
- Port 80 blocked → `sudo ufw status` must allow 80.

### Port already in use

```bash
sudo lsof -i :3000                 # find what's holding the port
```

### High memory (4GB box, 4 apps)

```bash
pm2 monit                          # per-app memory
free -h                            # overall + swap usage
```

Cap each app's memory so PM2 restarts it before it starves the box:

```bash
pm2 start npm --name radiustask --max-memory-restart 400M -- start
```

---

## Memory-Constrained (4GB) Builds

On a t4g.medium/t3.medium (4GB), building Next.js **on the box** is right at the memory edge — worse when a second app + Postgres + Redis are already resident. Two failure modes and their fixes:

### 1. Build gets OOM-killed (exit 137) or hangs

Symptoms: `signal SIGKILL` / `exit code 137`, or the deploy sits for 20+ min swap-thrashing (`available` RAM drops near zero in `free -h`).

- **Add swap** — 2GB is not enough; give it 6GB:
  ```bash
  sudo swapoff /swapfile && sudo rm /swapfile
  sudo fallocate -l 6G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  ```
- **Cap the heap** so Node GCs instead of ballooning (leaves room for PG/Redis):
  ```bash
  export NODE_OPTIONS="--max-old-space-size=2048"
  ```
- **Never build two apps at once.** Two concurrent `next build`s WILL OOM. Serialize deploys (own concurrency group per app in CI; don't hand-run two at once).

### 2. Build compiles, then OOMs on "Running TypeScript"

The `next build` type-check needs >2GB heap and hits the cap above. Types are already enforced in dev + PR CI, so skip the redundant on-server pass. Gate it in `next.config`:

```js
// next.config.js / .mjs
typescript: {
  ignoreBuildErrors: process.env.SKIP_TS_CHECK === '1',
},
```

Then set the flag in the deploy step only:
```bash
export SKIP_TS_CHECK=1
```

This is per-server (the flag isn't set in dev/CI), so type safety is preserved everywhere it matters.

### The real fix: build off-box

On a 4GB box hosting multiple apps, the durable solution is to **build in the CI runner** (`build` → rsync `.next`/`dist` to the server) and have the server only `pm2 reload`. Deploys drop from ~20min swap-death to seconds, and the box never gets starved while serving traffic.

---

## pnpm: native build scripts blocked (v10+)

pnpm v10+ **blocks dependency lifecycle scripts by default** — so Prisma engines, `bcrypt`, `sharp`, `esbuild` don't build and the app breaks at runtime:

```
Error: ERR_PNPM_IGNORED_BUILDS
  × Ignored build scripts: @prisma/engines, bcrypt, esbuild, sharp, ...
```

Fix depends on pnpm major version — **the setting moved**:

- **pnpm 10–11:** list in `pnpm-workspace.yaml`:
  ```yaml
  onlyBuiltDependencies:
    - '@prisma/engines'
    - sharp
  ```
- **pnpm 12+:** a map named `allowBuilds` (the old list is ignored, with a warning):
  ```yaml
  allowBuilds:
    '@prisma/engines': true
    bcrypt: true
    core-js: true
    esbuild: true
    msgpackr-extract: true
    prisma: true
    sharp: true
    unrs-resolver: true
  ```

Commit this to the repo so CI + every server behave the same. If deps are already installed, force the scripts to run:
```bash
pnpm install
pnpm rebuild        # re-runs the now-approved build scripts
```

> Check the version first (`pnpm --version`) — using the wrong key silently does nothing. When unsure, `pnpm approve-builds` writes the correct format for the installed version.

---

## Deployment Checklist

- [ ] Node 22 installed
- [ ] PM2 installed
- [ ] Nginx installed & running
- [ ] App code cloned to `/var/www/`
- [ ] Each app built (`npm run build`)
- [ ] Each app started on its own port under PM2
- [ ] Nginx server block per domain, `nginx -t` passes
- [ ] Default Nginx site removed
- [ ] DNS A records point to Elastic IP
- [ ] SSL issued via Certbot, HTTP→HTTPS redirect on
- [ ] `pm2 startup` + `pm2 save` done
- [ ] Survives a reboot

---

*Document Version: 1.0*
*Stack: Node 22 · PM2 · Nginx · Certbot*
*Server: AWS t4g.medium (Arm64) · Ubuntu 24.04 LTS*
*Last Updated: 2026*
