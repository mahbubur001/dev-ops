[← Back to Home](../README.md)

# PostgreSQL Remote Access Setup — Hetzner Server

## Server Details

- **Server:** Hetzner (87.99.130.89)
- **PostgreSQL Port:** 5432
- **Database:** bikribd
- **User:** bikribdu

---

## Connection URLs

### On Hetzner Server (localhost)

```
postgresql://bikribdu:****@127.0.0.1:5432/bikribd?schema=public
```

### On Local PC (direct remote connection)

```
postgresql://bikribdu:****@87.99.130.89:5432/bikribd?schema=public
```

---

## Setup Steps

### Step 1: Edit postgresql.conf

```bash
sudo nano /etc/postgresql/*/main/postgresql.conf
```

Find `listen_addresses` and change to:

```
listen_addresses = '*'
```

### Step 2: Edit pg_hba.conf

```bash
sudo nano /etc/postgresql/*/main/pg_hba.conf
```

Full configuration:

```
# Local connections
local   all             postgres                                peer
local   all             all                                     peer

# Localhost IPv4
host    all             all             127.0.0.1/32            md5

# Localhost IPv6
host    all             all             ::1/128                 md5

# Remote access - allowed IPs
host    all             all             103.86.199.233/32       md5
host    all             all             103.55.145.186/32       md5
```

### Step 3: Open Firewall

```bash
sudo ufw allow from 103.86.199.233 to any port 5432
sudo ufw allow from 103.55.145.186 to any port 5432
```

### Step 4: Restart PostgreSQL

```bash
sudo systemctl restart postgresql
```

---

## Adding a New IP

1. Add to `pg_hba.conf`:

```
host    all             all             NEW_IP/32       md5
```

2. Add firewall rule:

```bash
sudo ufw allow from NEW_IP to any port 5432
```

3. Restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

---

## Revert to Tunnel-Only (Remove Direct Access)

### Step 1: Remove IPs from pg_hba.conf

```bash
sudo nano /etc/postgresql/*/main/pg_hba.conf
```

Delete all `host` lines with remote IPs.

### Step 2: Change listen_addresses back

```bash
sudo nano /etc/postgresql/*/main/postgresql.conf
```

Change to:

```
listen_addresses = 'localhost'
```

### Step 3: Restart PostgreSQL

```bash
sudo systemctl restart postgresql
```

### Step 4: Remove Firewall Rules

```bash
sudo ufw delete allow from 103.86.199.233 to any port 5432
sudo ufw delete allow from 103.55.145.186 to any port 5432
```

### Step 5: Use SSH Tunnel Instead

```bash
ssh -L 5433:localhost:5432 deploy@87.99.130.89 -N -C
```

Then connect to:

```
postgresql://bikribdu:****@127.0.0.1:5433/bikribd?schema=public
```

---

## Check Current Status

```bash
# Check PostgreSQL is running
sudo systemctl status postgresql

# Check listen_addresses
sudo -u postgres psql -c "SHOW listen_addresses;"

# Check active connections
sudo -u postgres psql -c "SELECT pid, datname, usename, client_addr FROM pg_stat_activity;"

# Check firewall rules
sudo ufw status
```