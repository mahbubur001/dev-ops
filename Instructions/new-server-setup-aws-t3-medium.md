[← Back to Home](../README.md)

# New Server Setup Guide for AWS t3.medium

> **Instance:** t3.medium (2 vCPU / 4GB RAM) | **OS:** Ubuntu Server 24.04 LTS | **Storage:** 30GB gp3

A first-boot checklist for a fresh EC2 instance: connect, update, create a deploy user, harden SSH, configure the firewall, add swap, and install the baseline tooling. Run these steps once, in order, before deploying anything.

---

## Table of Contents

1. [Launch Checklist (AWS Console)](#step-1-launch-checklist-aws-console)
2. [Connect to the Instance](#step-2-connect-to-the-instance)
3. [Update the System](#step-3-update-the-system)
4. [Set Hostname & Timezone](#step-4-set-hostname--timezone)
5. [Create a Deploy User](#step-5-create-a-deploy-user)
6. [Set Up SSH Key for Deploy User](#step-6-set-up-ssh-key-for-deploy-user)
7. [Harden SSH](#step-7-harden-ssh)
8. [Configure the Firewall (UFW)](#step-8-configure-the-firewall-ufw)
9. [Add Swap Space](#step-9-add-swap-space)
10. [Install Fail2ban](#step-10-install-fail2ban)
11. [Enable Automatic Security Updates](#step-11-enable-automatic-security-updates)
12. [Install Baseline Tooling](#step-12-install-baseline-tooling)
13. [Verify the Setup](#step-13-verify-the-setup)
14. [Quick Reference](#step-14-quick-reference)
15. [Next Steps](#next-steps)

---

## Step 1: Launch Checklist (AWS Console)

Before connecting, confirm the instance was launched with:

| Setting | Value |
|---|---|
| **AMI** | Ubuntu Server 24.04 LTS (HVM), SSD |
| **Instance type** | `t3.medium` |
| **Key pair** | Downloaded `.pem` file (store it safely) |
| **Storage** | 30GB `gp3` root volume |
| **Security group** | SSH (22) from **your IP only**, HTTP (80) + HTTPS (443) as needed |
| **Elastic IP** | Allocated & associated (so the IP survives reboots) |

> **Tip:** Restrict port 22 to your own IP in the security group. Open 80/443 to `0.0.0.0/0` only if the server hosts a public site.

---

## Step 2: Connect to the Instance

From your **local machine**, lock down the key file, then connect:

```bash
chmod 400 ~/Downloads/your-key.pem
ssh -i ~/Downloads/your-key.pem ubuntu@<ec2-public-ip>
```

The default user on Ubuntu AMIs is `ubuntu`.

---

## Step 3: Update the System

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
```

Reboot if the kernel was updated:

```bash
sudo reboot
```

Reconnect after ~30 seconds.

---

## Step 4: Set Hostname & Timezone

```bash
# Set a recognizable hostname
sudo hostnamectl set-hostname app-server

# Set timezone (adjust to your region)
sudo timedatectl set-timezone Asia/Dhaka

# Verify
timedatectl
```

Map the hostname in `/etc/hosts`:

```bash
sudo sh -c 'echo "127.0.1.1 app-server" >> /etc/hosts'
```

---

## Step 5: Create a Deploy User

Working as `root`/`ubuntu` for everything is bad practice. Create a dedicated sudo user.

```bash
# Create the user (you'll be prompted for a password)
sudo adduser deploy

# Grant sudo access
sudo usermod -aG sudo deploy

# Verify
groups deploy
```

---

## Step 6: Set Up SSH Key for Deploy User

### Option A — Reuse your existing key

Copy the `ubuntu` user's authorized key to `deploy`:

```bash
sudo mkdir -p /home/deploy/.ssh
sudo cp ~/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

### Option B — Add a new key from your laptop

On your **local machine**:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@<ec2-public-ip>
```

### Test before locking down

From your **local machine**, open a **new terminal** and confirm the deploy login works:

```bash
ssh deploy@<ec2-public-ip>
```

> Keep the original `ubuntu` session open until you've verified `deploy` logs in and can run `sudo`.

---

## Step 7: Harden SSH

Edit the SSH daemon config:

```bash
sudo vim /etc/ssh/sshd_config
```

Set (or uncomment and change) these values:

```conf
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
```

**Save:** `Esc` → `:wq` → `Enter`

Validate the config, then reload:

```bash
sudo sshd -t          # returns nothing if config is valid
sudo systemctl restart ssh
```

> **Do not close your current session** until a fresh `ssh deploy@<ip>` connection succeeds. If it fails, fix the config from the still-open session.

---

## Step 8: Configure the Firewall (UFW)

```bash
# Default: deny incoming, allow outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (do this FIRST or you'll lock yourself out)
sudo ufw allow OpenSSH

# Web traffic (only if hosting a site)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Enable
sudo ufw enable

# Check
sudo ufw status verbose
```

> UFW is a host-level firewall that layers **on top of** the AWS security group. Both must allow a port for traffic to pass.

---

## Step 9: Add Swap Space

t3.medium has only 4GB RAM. A 2GB swap file guards against OOM kills during builds.

```bash
# Create a 2GB swap file
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Persist across reboots
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Tune swappiness (prefer RAM, use swap only under pressure)
sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

# Verify
free -h
swapon --show
```

---

## Step 10: Install Fail2ban

Blocks IPs after repeated failed SSH logins.

```bash
sudo apt install fail2ban -y

# Enable and start
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Check the SSH jail
sudo fail2ban-client status sshd
```

Default settings protect SSH out of the box. To customize, create `/etc/fail2ban/jail.local` (never edit `jail.conf` directly).

---

## Step 11: Enable Automatic Security Updates

```bash
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

Choose **Yes** when prompted. This applies security patches automatically without touching feature upgrades.

---

## Step 12: Install Baseline Tooling

```bash
sudo apt install -y \
  curl wget git vim htop \
  build-essential \
  net-tools \
  unzip \
  ca-certificates \
  gnupg \
  pv
```

| Package | Purpose |
|---|---|
| `curl` / `wget` | Fetch files & scripts |
| `git` | Version control |
| `vim` | Editor |
| `htop` | Live process/resource monitor |
| `build-essential` | Compilers for native modules |
| `net-tools` | `netstat`, `ifconfig` |
| `unzip` / `pv` | Archives & progress bars |

### Optional: Node.js (via NodeSource)

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v && npm -v
```

### Optional: Nginx (reverse proxy)

```bash
sudo apt install nginx -y
sudo systemctl enable nginx
sudo systemctl status nginx
```

---

## Step 13: Verify the Setup

```bash
# System
hostnamectl
timedatectl
free -h

# Security
sudo ufw status verbose
sudo fail2ban-client status sshd
grep -E "PermitRootLogin|PasswordAuthentication" /etc/ssh/sshd_config

# Users
groups deploy
```

Run the health-check script if you've copied it over (see [Server Management Scripts](server-management-scripts.md)):

```bash
sudo /usr/local/bin/health-check.sh
```

---

## Step 14: Quick Reference

### Connect

| Task | Command |
|---|---|
| SSH as deploy | `ssh deploy@<ec2-ip>` |
| SSH as ubuntu (fallback) | `ssh -i key.pem ubuntu@<ec2-ip>` |

### Service Management

| Task | Command |
|---|---|
| Restart SSH | `sudo systemctl restart ssh` |
| Firewall status | `sudo ufw status verbose` |
| Fail2ban status | `sudo fail2ban-client status sshd` |
| System resources | `htop` / `free -h` |

### Swap

| Task | Command |
|---|---|
| Show swap | `swapon --show` |
| Disable swap | `sudo swapoff /swapfile` |

---

## Next Steps

- **Install PostgreSQL** → [PostgreSQL 18 Installation Guide](complete-postgresql-18-installation-guide-for-aws-ec2.md)
- **Copy management scripts** → [Server Management Scripts](server-management-scripts.md)
- **Set up backups** → [Auto Backup Guide](postgresql-auto-backup-guide.md)
- **Upload your app** → [Upload Files to Server](upload-files-to-server.md)

---

## Hardening Checklist

- [ ] Instance launched with restricted security group
- [ ] Elastic IP associated
- [ ] System updated & rebooted
- [ ] Hostname & timezone set
- [ ] Deploy user created with sudo
- [ ] SSH key added to deploy user
- [ ] Root login disabled
- [ ] Password authentication disabled
- [ ] UFW enabled (SSH allowed first)
- [ ] 2GB swap added & persisted
- [ ] Fail2ban running
- [ ] Automatic security updates enabled
- [ ] Baseline tooling installed
- [ ] Setup verified

---

*Document Version: 1.0*
*Instance: AWS t3.medium*
*Ubuntu Version: 24.04 LTS*
*Last Updated: 2026*
