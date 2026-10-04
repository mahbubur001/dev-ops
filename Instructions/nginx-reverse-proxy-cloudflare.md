[← Back to Home](../README.md)

# Nginx Reverse Proxy + SSL Behind Cloudflare

> **Stack:** Cloudflare (proxy) → Nginx (Let's Encrypt) → PM2 → Next.js | **OS:** Ubuntu 24.04

Put a Next.js app behind Nginx with a free Let's Encrypt cert, when DNS is managed by Cloudflare. Covers the gotchas of **reusing an existing server's Nginx config** and issuing certs while Cloudflare proxying is on.

---

## Table of Contents

1. [Reusing a Config From Another Server](#step-1-reusing-a-config-from-another-server)
2. [Write an HTTP-Only Server Block](#step-2-write-an-http-only-server-block)
3. [Enable & Test](#step-3-enable--test)
4. [Point Cloudflare DNS (Grey-Cloud for Issuance)](#step-4-point-cloudflare-dns-grey-cloud-for-issuance)
5. [Issue the Certificate](#step-5-issue-the-certificate)
6. [Re-Proxy + SSL Mode](#step-6-re-proxy--ssl-mode)
7. [Troubleshooting](#troubleshooting)

---

## Step 1: Reusing a Config From Another Server

Copying a working `.conf` from another box (e.g. Hetzner → AWS) fails `nginx -t` for two reasons — fix both **before** running Certbot:

1. **It already has Certbot's SSL block** (`ssl_certificate /etc/letsencrypt/live/<domain>/...`). Those cert files don't exist on the new server yet, so `nginx -t` fails → Nginx won't start → Certbot can't run. **Certbot must start from an HTTP-only config and inject SSL itself.**
2. **Wrong `root`/`alias` paths** — the old server's paths (e.g. `/var/www/internal/<app>`) won't exist on the new box (`/var/www/<app>`). Every `alias`/`root` must be corrected or static routes 404.

The safe move: strip it back to a single HTTP-only `server` block with correct paths, then let Certbot add HTTPS.

---

## Step 2: Write an HTTP-Only Server Block

Use `sudo tee` with a quoted heredoc — this avoids editor paste errors (a dropped line silently breaks a `location` block and yields confusing `"proxy_pass" directive is not allowed here` / `named location can be on server level only` errors).

```bash
sudo tee /etc/nginx/sites-available/<domain>.conf > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name <domain> www.<domain>;

    root /var/www/<app>;
    client_max_body_size 30M;

    location /_next/static/ {
        proxy_pass http://127.0.0.1:<port>;
        proxy_set_header Host $host;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location / {
        proxy_pass http://127.0.0.1:<port>;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 60s;
    }

    location ~ /\.env { deny all; }
    location ~ /\.git { deny all; }

    error_log  /var/log/nginx/<domain>-error.log;
    access_log /var/log/nginx/<domain>-access.log;
}
EOF
```

Replace `<domain>`, `<app>`, `<port>` (e.g. `bikribd.com` / `bikribd.com` / `4000`).

> For Server-Sent Events endpoints, add a dedicated `location` with `proxy_buffering off;` and a long `proxy_read_timeout` (e.g. `3600s`) — buffering breaks live streams.

---

## Step 3: Enable & Test

```bash
sudo ln -sf /etc/nginx/sites-available/<domain>.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default      # only for the first vhost on the box
sudo nginx -t
sudo systemctl reload nginx
```

If `systemctl reload` warns *"unit ... changed on disk"*, clear it:
```bash
sudo systemctl daemon-reload && sudo systemctl reload nginx
```

Confirm the app is actually up on `<port>` first, or you'll proxy to nothing:
```bash
pm2 list
curl -I http://localhost:<port>
```

---

## Step 4: Point Cloudflare DNS (Grey-Cloud for Issuance)

Let's Encrypt's HTTP-01 challenge must reach **your origin**, not Cloudflare's edge. Temporarily disable proxying:

1. Cloudflare → DNS → the `A` record(s) → click the **orange cloud** so it turns **grey** ("DNS only").
2. Make sure the record points at the **server's public IP** (a common mistake is leaving the old server's IP).
3. Verify it resolves to the origin:
   ```bash
   dig +short <domain>          # must be your server IP, not 104.x / 172.67.x
   ```

---

## Step 5: Issue the Certificate

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d <domain> -d www.<domain>
```

- Enter email, agree to ToS
- Choose **2: Redirect** (force HTTP→HTTPS)

Certbot rewrites your config with the SSL block + redirect automatically and installs a renewal timer. Verify:
```bash
sudo certbot certificates
sudo certbot renew --dry-run
```

---

## Step 6: Re-Proxy + SSL Mode

1. Cloudflare → flip the `A` record(s) back to **Proxied** (orange cloud).
2. Cloudflare → **SSL/TLS → Overview → Full (strict)**.
   - **Full (strict)** validates your origin's Let's Encrypt cert end-to-end.
   - **Do NOT use "Flexible"** — it terminates SSL at the edge and speaks HTTP to your origin, which collides with the force-HTTPS redirect and causes redirect loops.

Test through Cloudflare:
```bash
curl -sI https://<domain> | grep -i -E 'server|cf-ray'      # server: cloudflare = proxied
```

---

## Alternative: Cloudflare Origin Certificate

Behind Cloudflare you can skip Let's Encrypt entirely: generate a **Cloudflare Origin Certificate** (15-year, no renewals), install it on the origin, and set SSL mode to **Full (strict)**. Cleaner when the domain stays proxied — no grey-cloud dance, no 90-day renewals. Use this if Certbot renewals behind Cloudflare become a hassle.

---

## Troubleshooting

### `nginx -t`: "proxy_pass directive is not allowed here"

A `proxy_pass` ended up at `server` scope because a `location { ... }` opener was dropped (usually an editor paste). Rewrite the file with the `sudo tee` heredoc (Step 2) rather than hand-editing.

### `nginx -t`: named location "@x" can be on the server level only

A `location @name { }` got nested inside another `location`. Same cause/fix as above.

### Certbot: "challenge failed" / timeout

- DNS still points at Cloudflare (proxied) or the wrong IP → grey-cloud + `dig +short <domain>` must show the origin IP.
- Port 80 blocked → `sudo ufw status` must allow 80, and the AWS security group too.

### Site loads but redirect loops

Cloudflare SSL mode is **Flexible**. Switch to **Full (strict)**.

### 502 Bad Gateway

Nginx can't reach the app. `pm2 list` + `curl -I http://localhost:<port>` — the app isn't running on the expected port.

---

*Document Version: 1.0*
*Stack: Cloudflare · Nginx · Certbot · Next.js · Ubuntu 24.04*
*Last Updated: 2026*
