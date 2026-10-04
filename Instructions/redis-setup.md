[← Back to Home](../README.md)

# Redis Setup & Hardening

> **OS:** Ubuntu 24.04 LTS (arm64) | **Redis:** 7.x (Ubuntu repo) | **Bind:** localhost-only

Install Redis as a password-protected, localhost-only cache/queue for apps running on the same server. Written for the AWS t4g.medium box alongside PostgreSQL and the Node/Next.js apps.

---

## Table of Contents

1. [Install Redis](#step-1-install-redis)
2. [Harden the Config](#step-2-harden-the-config)
3. [Set a Password](#step-3-set-a-password)
4. [Restart & Enable on Boot](#step-4-restart--enable-on-boot)
5. [Test the Connection](#step-5-test-the-connection)
6. [Connection String](#step-6-connection-string)
7. [Quick Reference](#step-7-quick-reference)
8. [Troubleshooting](#troubleshooting)

---

## Step 1: Install Redis

```bash
sudo apt update
sudo apt install -y redis-server

# Verify the package + binaries
dpkg -l | grep redis
redis-server --version
```

Confirm the systemd unit exists (it's `redis-server.service` on Ubuntu):

```bash
systemctl list-unit-files | grep redis
```

---

## Step 2: Harden the Config

```bash
sudo vim /etc/redis/redis.conf
```

Set (or confirm) these values:

```conf
# Run under systemd so status/restart work cleanly
supervised systemd

# Localhost-only — never expose Redis to the internet
bind 127.0.0.1 ::1

# Cap memory so Redis can't starve the 4GB box; evict oldest keys when full
maxmemory 512mb
maxmemory-policy allkeys-lru
```

**Save:** `Esc` → `:wq` → `Enter`

> **Why localhost-only:** An internet-exposed Redis with no auth is one of the most-exploited misconfigurations — attackers use it to write cron jobs / SSH keys and take over the box. Keep `bind 127.0.0.1` for apps on the same server. For cross-server access, use an SSH tunnel or a private network instead of opening the port.

---

## Step 3: Set a Password

Redis 6+ treats `requirepass` as the password for the built-in `default` user (ACL system) — clients still authenticate with `AUTH <password>`.

Generate a strong password:

```bash
openssl rand -base64 24
```

### Option A — edit the config file

In `/etc/redis/redis.conf`, find the commented line:

```conf
# requirepass foobared
```

Uncomment it and set your password (no leading `#`):

```conf
requirepass YourStrongRedisPass
```

**Save:** `Esc` → `:wq` → `Enter`

### Option B — set at runtime and persist

```bash
PASS=$(openssl rand -base64 24)
redis-cli CONFIG SET requirepass "$PASS"
redis-cli -a "$PASS" CONFIG REWRITE
echo "Redis password: $PASS"
```

> Save the password somewhere safe — your apps need it in their connection string.

---

## Step 4: Restart & Enable on Boot

```bash
sudo systemctl restart redis-server
sudo systemctl enable redis-server
sudo systemctl status redis-server
```

---

## Step 5: Test the Connection

Interactive (avoids leaking the password into shell history):

```bash
redis-cli
AUTH YourStrongRedisPass
PING          # → PONG
exit
```

One-liner (note: `-a` prints a safety warning, which is harmless):

```bash
redis-cli -a 'YourStrongRedisPass' PING     # → PONG
```

Confirm it's bound to localhost only:

```bash
grep '^bind' /etc/redis/redis.conf          # → bind 127.0.0.1 ::1
sudo ss -tlnp | grep 6379                    # should show 127.0.0.1:6379, not 0.0.0.0
```

---

## Step 6: Connection String

Use in your app's `.env`:

```env
REDIS_URL="redis://:YourStrongRedisPass@localhost:6379"
```

With a specific database index (0–15):

```env
REDIS_URL="redis://:YourStrongRedisPass@localhost:6379/0"
```

---

## Step 7: Quick Reference

| Task | Command |
|---|---|
| Start | `sudo systemctl start redis-server` |
| Stop | `sudo systemctl stop redis-server` |
| Restart | `sudo systemctl restart redis-server` |
| Status | `sudo systemctl status redis-server` |
| Enable on boot | `sudo systemctl enable redis-server` |
| CLI (auth) | `redis-cli` → `AUTH <pass>` |
| Ping | `redis-cli -a '<pass>' PING` |
| Memory usage | `redis-cli -a '<pass>' INFO memory` |
| Live stats | `redis-cli -a '<pass>' INFO stats` |
| Flush all keys | `redis-cli -a '<pass>' FLUSHALL` |
| Config file | `/etc/redis/redis.conf` |
| Log file | `/var/log/redis/redis-server.log` |

---

## Troubleshooting

### `Unit redis-server.service not found`

The package isn't installed (or install failed). Reinstall and watch for errors:

```bash
sudo apt update && sudo apt install -y redis-server
dpkg -l | grep redis
```

### `NOAUTH Authentication required`

You set a password but didn't authenticate. Run `AUTH <password>` after connecting, or use `redis-cli -a '<password>'`.

### `WRONGPASS invalid username-password pair`

Password mismatch. Re-check `requirepass` in the config, then `sudo systemctl restart redis-server`.

### Redis won't start after editing config

Check the log for the offending line:

```bash
sudo tail -n 30 /var/log/redis/redis-server.log
```

A common cause is a typo in `redis.conf` (e.g. a stray `#` left on `requirepass`).

### Verify it's not internet-exposed

```bash
sudo ss -tlnp | grep 6379
```

Must show `127.0.0.1:6379`. If it shows `0.0.0.0:6379`, fix `bind` in the config and restart.

---

## Optional: Add to Health Check

Add Redis to the `PORTS` array in [`scripts/health-check-aws.sh`](../scripts/health-check-aws.sh):

```bash
"6379:Redis"
```

---

*Document Version: 1.0*
*Redis: 7.x · Ubuntu 24.04 LTS (arm64)*
*Last Updated: 2026*
