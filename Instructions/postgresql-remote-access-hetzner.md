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
sudo vim /etc/postgresql/*/main/postgresql.conf
```

Find `listen_addresses` and change to:

```
listen_addresses = '*'
```

### Step 2: Edit pg_hba.conf

```bash
sudo vim /etc/postgresql/*/main/pg_hba.conf
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

### Step 3: Open Hetzner Cloud Firewall

UFW is **not used** on this server for port 5432 — Hetzner's own cloud firewall controls network-level access.

> **Two-layer model:**
> - **Hetzner firewall** — controls which IPs can reach port 5432 at the network level
> - **pg_hba.conf** — controls which IPs PostgreSQL allows to authenticate
>
> Both layers need the entry. Removing an IP from pg_hba.conf will refuse the connection even if the Hetzner firewall lets it through.

To allow a new IP, update the Hetzner cloud firewall in the [Hetzner Cloud Console](https://console.hetzner.cloud/):

1. Go to your project → **Firewalls**
2. Select the firewall attached to this server
3. Under **Inbound rules**, add a rule:
   - **Protocol:** TCP
   - **Port:** 5432
   - **Source IPs:** `103.86.199.233/32`, `103.55.145.186/32`
4. Apply the firewall rule

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

2. Add the IP to the **Hetzner Cloud Firewall** (not UFW):
   - Console → Firewalls → select firewall → Inbound rules
   - Add TCP rule for port 5432, source: `NEW_IP/32`

3. Restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

> Both steps are required — Hetzner firewall is the network gate; pg_hba.conf is the PostgreSQL auth gate.

---

## Revert to Tunnel-Only (Remove Direct Access)

### Step 1: Remove IPs from pg_hba.conf

```bash
sudo vim /etc/postgresql/*/main/pg_hba.conf
```

Delete all `host` lines with remote IPs.

### Step 2: Change listen_addresses back

```bash
sudo vim /etc/postgresql/*/main/postgresql.conf
```

Change to:

```
listen_addresses = 'localhost'
```

### Step 3: Restart PostgreSQL

```bash
sudo systemctl restart postgresql
```

### Step 4: Remove Hetzner Firewall Rules

In the [Hetzner Cloud Console](https://console.hetzner.cloud/):

1. Go to Firewalls → select firewall → Inbound rules
2. Delete the TCP port 5432 rules for the IPs you're removing

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