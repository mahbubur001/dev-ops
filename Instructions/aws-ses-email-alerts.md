[← Back to Home](../README.md)

# Email Alerts via AWS SES (msmtp + sendmail)

> **Server:** AWS t4g.medium · Ubuntu 24.04 | **Mail:** Amazon SES (SMTP) → `msmtp` → `sendmail` interface

Wire server scripts (`security-check.sh`, backup failures, cron output) to send email through **Amazon SES**. We install `msmtp` as a lightweight SMTP relay that exposes a `sendmail` binary — so any script using `sendmail` (including `security-check.sh`) sends via SES with **no script changes**.

---

## Table of Contents

1. [How It Fits Together](#step-1-how-it-fits-together)
2. [Set Up SES (AWS Console)](#step-2-set-up-ses-aws-console)
3. [Get SMTP Credentials](#step-3-get-smtp-credentials)
4. [Install msmtp on the Server](#step-4-install-msmtp-on-the-server)
5. [Configure msmtp for SES](#step-5-configure-msmtp-for-ses)
6. [Send a Test Email](#step-6-send-a-test-email)
7. [Set Alert Variables in /etc/environment](#step-7-set-alert-variables-in-etcenvironment)
8. [Wire Into security-check.sh & Cron](#step-8-wire-into-security-checksh--cron)
9. [Move Out of the SES Sandbox](#step-9-move-out-of-the-ses-sandbox)
10. [Troubleshooting](#troubleshooting)

---

## Step 1: How It Fits Together

```
security-check.sh ─┐
backup scripts    ─┼─►  /usr/sbin/sendmail  ──►  msmtp  ──►  SES SMTP endpoint  ──►  inbox
cron MAILTO       ─┘        (msmtp-mta)              (TLS :587, SMTP auth)
```

`msmtp-mta` installs a drop-in `sendmail` command. Scripts don't know or care it's SES underneath.

---

## Step 2: Set Up SES (AWS Console)

1. Open **Amazon SES** → pick a **region** (e.g. `ap-south-1` Mumbai, close to the server). Note it — SMTP endpoint is region-specific.
2. **Verified identities → Create identity:**
   - **Email address** (simplest): verify a single sender like `alerts@yourdomain.com`. Click the confirmation link SES emails you.
   - **Domain** (better): verify `yourdomain.com` via DNS records (SES gives you DKIM CNAMEs). Lets you send from any address at that domain.
3. New accounts start in the **sandbox** — you can only send **to verified addresses**. For now, also verify your **recipient** (`mamunnu@gmail.com`) as an identity, or [request production access](#step-9-move-out-of-the-ses-sandbox).

---

## Step 3: Get SMTP Credentials

SES SMTP credentials are **not** your AWS access keys.

1. SES → **SMTP settings** → note the **SMTP endpoint**, e.g.
   `email-smtp.ap-south-1.amazonaws.com` (port **587**, STARTTLS).
2. Click **Create SMTP credentials** → creates an IAM user → download the
   **SMTP username** and **SMTP password**. Store them safely (shown once).

---

## Step 4: Install msmtp on the Server

```bash
sudo apt update
sudo apt install -y msmtp msmtp-mta ca-certificates
```

`msmtp-mta` symlinks `/usr/sbin/sendmail` → `msmtp`, satisfying any script that calls `sendmail`.

---

## Step 5: Configure msmtp for SES

Create a system-wide config (readable only by root — it holds the SMTP password):

```bash
sudo vim /etc/msmtprc
```

```conf
# ── Defaults ──────────────────────────────
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# ── Amazon SES ────────────────────────────
account        ses
host           email-smtp.ap-south-1.amazonaws.com
port           587
from           alerts@yourdomain.com
user           YOUR_SES_SMTP_USERNAME
password       YOUR_SES_SMTP_PASSWORD

# Default account
account default : ses
```

**Save:** `Esc` → `:wq` → `Enter`

Lock down permissions (msmtp refuses to run if the file is world-readable):

```bash
sudo chmod 600 /etc/msmtprc
sudo chown root:root /etc/msmtprc
sudo touch /var/log/msmtp.log && sudo chmod 600 /var/log/msmtp.log
```

> Replace `ap-south-1`, `from`, `user`, `password` with your values. `from` **must** be an SES-verified identity.

---

## Step 6: Send a Test Email

```bash
echo -e "Subject: SES test from $(hostname)\n\nIf you see this, SES email works." \
  | sendmail -v mamunnu@gmail.com
```

- Delivered → SES is wired correctly. ✅
- Check the log on failure: `sudo tail -n 30 /var/log/msmtp.log`
- Sandbox error (`Email address is not verified`) → verify the recipient, or [request production access](#step-9-move-out-of-the-ses-sandbox).

---

## Step 7: Set Alert Variables in /etc/environment

`security-check.sh` reads `ALERT_EMAIL` (and optional Resend vars) from the environment. Set system-wide vars in `/etc/environment` so cron jobs inherit them:

```bash
sudo vim /etc/environment
```

Add:

```conf
ALERT_EMAIL=mamunnu@gmail.com
ALERT_FROM=alerts@yourdomain.com
```

**Save:** `Esc` → `:wq` → `Enter`

Apply to your current shell (or just re-login):

```bash
source /etc/environment
echo "$ALERT_EMAIL"
```

> `/etc/environment` is a simple `KEY=value` file (no `export`, no shell expansion). Cron reads it via PAM on most Ubuntu setups; if a cron job doesn't see the var, set it inline in the crontab instead (below).

---

## Step 8: Wire Into security-check.sh & Cron

`security-check.sh` already tries **Resend** first, then falls back to **`sendmail`** — which is now SES via msmtp. No script edit needed; just ensure no `RESEND_API_KEY` is set, so it uses the sendmail path.

Run it manually to trigger an alert path:

```bash
sudo ALERT_EMAIL=mamunnu@gmail.com /usr/local/bin/security-check.sh
```

For cron, set the vars inline so they're guaranteed present:

```bash
sudo crontab -e
```

```cron
ALERT_EMAIL=mamunnu@gmail.com

0 * * * * /usr/local/bin/security-check.sh >> /var/log/security-check.log 2>&1
0 2 * * * /usr/local/bin/pg-backup.sh
0 * * * * /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1
```

> Cron variables must be declared **above** the job lines, one `KEY=value` per line (cron does not expand `$OTHER` references).

---

## Step 9: Move Out of the SES Sandbox

The sandbox blocks sending to unverified recipients. To email anyone:

1. SES → **Account dashboard** → **Request production access**.
2. Fill the form: use case (transactional server alerts), expected volume (low), that you handle bounces/complaints.
3. Approval is usually within 24 h. After that, no per-recipient verification needed.

Until approved, keep `mamunnu@gmail.com` verified as an SES identity.

---

## Troubleshooting

### `sendmail: cannot open ... msmtprc: permission`

Config must be `chmod 600`, owned by root. Re-check Step 5.

### `Email address is not verified` (sandbox)

Verify the **recipient** in SES, or request production access (Step 9). The `from` must also be verified.

### `TLS` / certificate errors

Ensure `ca-certificates` is installed and `tls_trust_file` points to
`/etc/ssl/certs/ca-certificates.crt`.

### Nothing arrives, no error

Check SES sending stats in the console and the msmtp log:

```bash
sudo tail -f /var/log/msmtp.log
```

Also check the Gmail spam folder and that the `from` domain has DKIM verified (domain identities land far better than raw email identities).

### Cron alert didn't send but manual run did

The cron job didn't see `ALERT_EMAIL`. Declare it inline in the crontab (Step 8), not only in `/etc/environment`.

---

## Alternative: AWS CLI (`aws ses send-email`)

If you prefer IAM-role auth over SMTP credentials (no password on disk):

```bash
sudo apt install -y awscli
aws ses send-email \
  --region ap-south-1 \
  --from alerts@yourdomain.com \
  --destination "ToAddresses=mamunnu@gmail.com" \
  --message "Subject={Data=Test},Body={Text={Data=Hello from $(hostname)}}"
```

Attach an EC2 **instance IAM role** with `ses:SendEmail` permission — no keys stored on the box. This needs a small script change to call `aws ses` instead of `sendmail`; the msmtp/SMTP route above is the drop-in that works with the existing scripts unchanged.

---

## Setup Checklist

- [ ] SES region chosen, sender identity verified (DKIM if domain)
- [ ] SMTP credentials created & saved
- [ ] `msmtp` + `msmtp-mta` installed
- [ ] `/etc/msmtprc` configured, `chmod 600`
- [ ] Test email received
- [ ] `ALERT_EMAIL` set in `/etc/environment` + crontab
- [ ] `security-check.sh` sends via sendmail path
- [ ] Production access requested (out of sandbox)

---

*Document Version: 1.0*
*Mail: Amazon SES (SMTP) via msmtp · Ubuntu 24.04*
*Last Updated: 2026*
