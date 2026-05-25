# Cloudflare Manager

> A simple, all-in-one SSH-based tool to install, configure, manage, and remove Cloudflare protection on any Linux server.

[![Bash](https://img.shields.io/badge/bash-4%2B-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![Version](https://img.shields.io/badge/version-1.0.0-orange.svg)](#)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Permissions Summary](#permissions-summary)
- [Cloudflare API Token](#cloudflare-api-token)
- [How SSH Authentication Works](#how-ssh-authentication-works)
- [Feature Activation Flow](#feature-activation-flow)
- [Lifecycle & Commands](#lifecycle--commands)
- [File Locations](#file-locations)
- [Web Server Integration](#web-server-integration)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [License](#license)
- [Author](#author)

---

## Overview

**Cloudflare Manager** is a single-file Bash tool that automates the full Cloudflare integration workflow on a Linux server. It handles everything from initial credential setup to domain protection, SSL/TLS hardening, origin firewall, and complete uninstallation — all over SSH, with both interactive menus and direct command-line usage.

The tool follows a clear lifecycle:

```
Install → Setup credentials → Add domain(s) → Monitor → Disable/Enable → Uninstall
```

You can start **without a domain** (just save credentials), then add domains later as needed.

---

## Features

| Module | Description |
|---|---|
| **Installation** | Auto-installs dependencies (`curl`, `jq`, `openssl`), copies the script to `/usr/local/bin/cf-manager` |
| **Authentication** | Validates Cloudflare API Token via the official `/user/tokens/verify` endpoint |
| **Account resolution** | Auto-detects account or prompts when multiple accounts exist |
| **Zone management** | Detects existing zones or creates new ones, shows assigned nameservers |
| **DNS records** | Creates/updates A records for apex + www + custom subdomains (idempotent) |
| **SSL / TLS** | Full (Strict) mode, Always HTTPS, TLS 1.2 minimum, TLS 1.3, HTTPS rewrites |
| **Security** | Browser Integrity Check, email obfuscation, security level adjustment |
| **Performance** | Brotli compression, HTTP/3 (QUIC), 0-RTT connection resumption |
| **Origin Certificate** | Free 15-year RSA certificate (apex + wildcard) for origin-pull TLS |
| **Origin firewall** | Restricts ports 80/443 to Cloudflare IPs only (UFW / firewalld / iptables) |
| **Pause / Unpause** | Temporarily disable Cloudflare without losing any configuration |
| **Status check** | Health snapshot of credentials, domains, zones, and firewall rules |
| **Clean uninstall** | Removes all local files and firewall rules; Cloudflare account untouched |

---

## Requirements

- **Operating System:** Ubuntu 20.04+, Debian 11+, CentOS 8+, AlmaLinux, Rocky Linux, Fedora
- **Privileges:** root (or sudo)
- **Network:** Outbound HTTPS to `api.cloudflare.com`
- **Auto-installed dependencies:** `curl`, `jq`, `openssl`

---

## Quick Start

### Step 1 — Upload the script to your server

From your local machine:

```bash
scp cf-manager.sh user@your-server:/tmp/
```

Or download it directly on the server:

```bash
ssh user@your-server
cd /tmp
# (place cf-manager.sh here by any method: scp, wget, nano, etc.)
```

---

### Step 2 — Give the script execute permission

This is **required** before you can run it as an executable:

```bash
chmod +x /tmp/cf-manager.sh
```

Verify the permission was applied:

```bash
ls -l /tmp/cf-manager.sh
```

You should see `-rwxr-xr-x` (the `x` letters mean executable):

```
-rwxr-xr-x 1 user user 30204 May 25 17:49 /tmp/cf-manager.sh
```

> **Note:** If you skip `chmod +x`, you can still run it via `sudo bash /tmp/cf-manager.sh`, but giving it execute permission is the cleaner approach.

---

### Step 3 — Run the script (first time)

Run as root using `sudo`:

```bash
sudo /tmp/cf-manager.sh
```

Or, if you didn't run `chmod +x`:

```bash
sudo bash /tmp/cf-manager.sh
```

The interactive menu will appear:

```
1) Install (system-wide)
2) Setup credentials   (no domain required)
3) Add / protect a domain
4) Check status
5) Disable (pause) a domain
6) Enable (unpause) a domain
7) Uninstall
8) Help
0) Exit
```

---

### Step 4 — Install system-wide (recommended)

Choose option **`1`** from the menu. This will:

- Install required packages (`curl`, `jq`, `openssl`)
- Copy the script to `/usr/local/bin/cf-manager` with mode `755`
- Create `/etc/cf-manager/` with mode `700`

After this, you can run the tool from anywhere with just:

```bash
sudo cf-manager
```

No more `bash`, no more full paths.

---

### Step 5 — Recommended first-time flow

After installation, do this sequence:

```bash
sudo cf-manager setup                    # 1. Save your API token
sudo cf-manager add-domain example.com   # 2. Protect your first domain
sudo cf-manager status                   # 3. Verify everything is working
```

---

## Permissions Summary

| File | Required Mode | Why |
|---|---|---|
| `cf-manager.sh` (before install) | `755` (`chmod +x`) | So it can be executed directly |
| `/usr/local/bin/cf-manager` (after install) | `755` | Standard executable location |
| `/etc/cf-manager/` | `700` | Only root can read configs |
| `/etc/cf-manager/config` | `600` | Contains the API token — root-only |
| `/etc/ssl/cloudflare/*.key` | `600` | Private keys — root-only |

All these permissions are **set automatically** by the script's `install` command. You only need to manually run `chmod +x` once on the initial download.

---

## Cloudflare API Token

Create a token at: **https://dash.cloudflare.com/profile/api-tokens**

### Required permissions

| Scope | Permission |
|---|---|
| Account | Read |
| Zone | Read |
| Zone | Edit |
| DNS | Edit |
| SSL and Certificates | Edit |
| Zone WAF | Edit |

### Recommended approach

1. Click **Create Token** → **Create Custom Token**
2. Name it `cf-manager-server`
3. Add all permissions listed above
4. **Resource scope:** `Include — All zones from an account` (or specific zones)
5. **TTL:** leave blank (no expiration) or set an expiration date
6. **IP filtering:** optional, restrict to your server IP for extra security
7. Click **Continue to summary → Create Token**
8. Copy the token immediately — it's shown only once

---

## How SSH Authentication Works

This tool **never asks for your Cloudflare email/password** and **never opens a browser**. All authentication happens through the Cloudflare REST API using an API Token over HTTPS — fully compatible with headless SSH sessions.

### The authentication chain

```
┌──────────────┐    SSH       ┌──────────────┐   HTTPS    ┌──────────────────┐
│  Your laptop │ ───────────► │ Linux server │ ─────────► │ api.cloudflare   │
│   (terminal) │              │ (cf-manager) │   Token    │      .com        │
└──────────────┘              └──────────────┘            └──────────────────┘
                                      │
                                      ▼
                               /etc/cf-manager/
                                  config (600)
                              ┌────────────────┐
                              │ CF_API_TOKEN   │
                              │ CF_EMAIL       │
                              │ CF_ACCOUNT_ID  │
                              └────────────────┘
```

### Step-by-step what happens during `setup`

When you run `sudo cf-manager setup` over SSH:

#### 1. The tool prompts for the API Token

```
? Cloudflare API Token: ***************************
? Cloudflare account email: you@example.com
```

The token is read with `read -s` (silent mode) — it is **never displayed on screen** and never echoed to your SSH session.

#### 2. The token is sent to Cloudflare for verification

The script sends an HTTPS request to Cloudflare's official token verification endpoint:

```bash
curl -sS -X GET \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
```

A valid response looks like:

```json
{
  "result": {
    "id": "abc123...",
    "status": "active"
  },
  "success": true,
  "errors": [],
  "messages": [...]
}
```

If `success: true` and `status: active` → token is accepted.
If not → script exits with a clear error and tells you which permissions are missing.

#### 3. Account ID is resolved automatically

The script then calls:

```bash
curl -sS -X GET \
  -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts
```

- If you have **one account** → it's used automatically
- If you have **multiple accounts** → the script shows a numbered list and you pick one

#### 4. Credentials are saved securely

The token, email, and account ID are written to `/etc/cf-manager/config` with strict permissions:

```
-rw------- 1 root root  /etc/cf-manager/config   (mode 600)
drwx------ 2 root root  /etc/cf-manager/          (mode 700)
```

Only `root` can read this file. The token never appears in shell history, environment variables, or process listings.

### Why this is safe over SSH

| Concern | How it's handled |
|---|---|
| Token visible on screen | `read -s` hides it during input |
| Token in shell history | Never typed as a command, only read interactively |
| Token in process list | Sent as a header via `curl`, not as a command-line argument |
| Token transmitted in clear | All traffic goes over **HTTPS to api.cloudflare.com** |
| File readable by other users | Saved as mode `600`, root-only |
| Token reused later | Loaded from file each run, never re-prompted |

### Subsequent runs don't re-prompt

Once `setup` is done, every other command (`add-domain`, `status`, `disable`, etc.) loads the saved token automatically:

```bash
# Internally:
source /etc/cf-manager/config
# Now $CF_API_TOKEN is available for all API calls
```

So all your future SSH sessions just work — no re-entering credentials.

### Rotating or revoking the token

**To rotate:**
```bash
# 1. Create a new token in the Cloudflare dashboard
# 2. Re-run setup with the new value:
sudo cf-manager setup
# 3. Revoke the old token in the dashboard
```

**To revoke completely:**
- Go to https://dash.cloudflare.com/profile/api-tokens
- Click the token → **Roll** or **Delete**
- The script will immediately fail until a new valid token is provided

---

## Feature Activation Flow

Once authenticated, here's exactly **how each protection feature is activated** through the API — all without ever leaving your SSH session.

### Visual flow: `add-domain example.com`

```
sudo cf-manager add-domain example.com
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 1. Verify saved token (GET /user/tokens/verify)            │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 2. Check if zone exists (GET /zones?name=example.com)      │
│    - If not: POST /zones to create it                      │
│    - Display the assigned nameservers to update at         │
│      your domain registrar                                 │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 3. Detect server public IP via api.ipify.org               │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 4. Create DNS records                                      │
│    POST /zones/{id}/dns_records                            │
│      type: A, name: example.com,     proxied: true         │
│      type: A, name: www.example.com, proxied: true         │
│    + any custom subdomains you add                         │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 5. Harden SSL/TLS                                          │
│    PATCH /zones/{id}/settings/ssl                          │
│    PATCH /zones/{id}/settings/always_use_https             │
│    PATCH /zones/{id}/settings/automatic_https_rewrites     │
│    PATCH /zones/{id}/settings/min_tls_version              │
│    PATCH /zones/{id}/settings/tls_1_3                      │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 6. Enable security features                                │
│    PATCH /zones/{id}/settings/security_level               │
│    PATCH /zones/{id}/settings/browser_check                │
│    PATCH /zones/{id}/settings/email_obfuscation            │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 7. Enable performance features                             │
│    PATCH /zones/{id}/settings/brotli                       │
│    PATCH /zones/{id}/settings/http3                        │
│    PATCH /zones/{id}/settings/0rtt                         │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 8. Generate Origin Certificate (optional)                  │
│    - openssl genrsa  → /etc/ssl/cloudflare/<domain>.key    │
│    - openssl req     → CSR                                 │
│    - POST /certificates with the CSR                       │
│    - Save returned cert to <domain>.crt                    │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 9. Lock origin firewall (optional)                         │
│    - Fetch https://www.cloudflare.com/ips-v4 and ips-v6    │
│    - Add ACCEPT rules for each CF range on ports 80/443    │
│    - Block all other traffic on those ports                │
│    - Detects UFW / firewalld / iptables automatically      │
└────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ 10. Add domain to local tracking                           │
│     echo "example.com|<zone_id>" >> /etc/cf-manager/domains│
└────────────────────────────────────────────────────────────┘
```

### Behind every "✓ ok" message

Every green check mark you see in the terminal corresponds to one API call. Here's a sample mapping:

| Terminal output | API call made |
|---|---|
| `✓ Token is valid.` | `GET /user/tokens/verify` |
| `✓ Account: a1b2c3...` | `GET /accounts` |
| `✓ Zone created: xyz...` | `POST /zones` |
| `✓ DNS A example.com → 1.2.3.4` | `POST /zones/{id}/dns_records` |
| `✓ SSL mode: Full (Strict)` | `PATCH /zones/{id}/settings/ssl` |
| `✓ Always Use HTTPS` | `PATCH /zones/{id}/settings/always_use_https` |
| `✓ TLS 1.3` | `PATCH /zones/{id}/settings/tls_1_3` |
| `✓ Brotli` | `PATCH /zones/{id}/settings/brotli` |
| `✓ HTTP/3` | `PATCH /zones/{id}/settings/http3` |
| `✓ Browser Integrity Check` | `PATCH /zones/{id}/settings/browser_check` |
| `✓ Cloudflare is now paused for example.com` | `POST /zones/{id}/pause` |
| `✓ Cloudflare is now active for example.com` | `POST /zones/{id}/unpause` |

### Complete settings table

These are the exact values the script applies to every protected domain:

#### SSL / TLS

| Setting | Value | Effect |
|---|---|---|
| `ssl` | `strict` | Encrypts visitor↔CF and CF↔origin, verifies origin cert |
| `always_use_https` | `on` | Redirects all HTTP to HTTPS at the edge |
| `automatic_https_rewrites` | `on` | Rewrites HTTP links in HTML to HTTPS |
| `min_tls_version` | `1.2` | Blocks TLS 1.0/1.1 (deprecated, insecure) |
| `tls_1_3` | `on` | Latest, fastest TLS version |

#### Security

| Setting | Value | Effect |
|---|---|---|
| `security_level` | `medium` | Challenges suspicious visitors based on threat score |
| `browser_check` | `on` | Verifies HTTP headers to detect basic bots |
| `email_obfuscation` | `on` | Hides email addresses from scrapers automatically |

#### Performance

| Setting | Value | Effect |
|---|---|---|
| `brotli` | `on` | Better compression than gzip → faster page loads |
| `http3` | `on` | HTTP/3 (QUIC) — faster on mobile and lossy networks |
| `0rtt` | `on` | 0-RTT resumption — eliminates one round-trip for repeat visits |

All these can be modified later through the Cloudflare dashboard. The script just sets safe, recommended defaults.

### Activating only specific features

Currently, `add-domain` runs the full hardening pass. To toggle individual settings without re-running everything, you have two options:

**Option 1 — Use the Cloudflare dashboard** at `https://dash.cloudflare.com/<account_id>/<domain>`

**Option 2 — Call the API directly via curl**, using the saved token:

```bash
# Load the saved credentials
source /etc/cf-manager/config

# Get the zone ID for your domain
ZONE_ID=$(curl -sS \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=example.com" \
  | jq -r '.result[0].id')

# Example: turn OFF email obfuscation
curl -sS -X PATCH \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value":"off"}' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/email_obfuscation"
```

---

## Lifecycle & Commands

### Two ways to use the tool

| Mode | How |
|---|---|
| **Interactive menu** | `sudo bash cf-manager.sh` — best for first-time users |
| **Direct commands** | `sudo cf-manager <command>` — best for scripts and repeat use |

### Command reference

#### `install`

Installs dependencies and copies the script to `/usr/local/bin/cf-manager` so it can be called from anywhere.

```bash
sudo bash cf-manager.sh install
```

**What happens:**
- Detects OS and installs missing packages
- Creates `/etc/cf-manager/` with mode `700`
- Copies the script to `/usr/local/bin/cf-manager` with mode `755`
- Creates the log file `/var/log/cf-manager.log`

---

#### `setup`

Saves your Cloudflare API credentials. **No domain required at this stage.**

```bash
sudo cf-manager setup
```

**Prompts for:**
- Cloudflare API Token (hidden input)
- Account email

**What happens:**
- Verifies the token with Cloudflare
- Resolves your account ID
- Saves credentials to `/etc/cf-manager/config` (mode `600`)

---

#### `add-domain [DOMAIN]`

Adds a domain to your Cloudflare account and applies full protection.

```bash
sudo cf-manager add-domain example.com
```

Or interactively (will prompt for the domain):

```bash
sudo cf-manager add-domain
```

**What happens (step by step):**

1. Checks if the zone already exists; creates it if not
2. Shows the assigned Cloudflare nameservers (you must update them at your registrar)
3. Detects your server's public IP
4. Creates A records: `example.com` and `www.example.com` (proxied)
5. Optionally asks for additional subdomains
6. Configures SSL/TLS to **Full (Strict)** mode
7. Enables Always HTTPS, TLS 1.3, HTTP/3, Brotli, 0-RTT
8. Sets security level to Medium with Browser Integrity Check
9. Optionally generates a 15-year Origin Certificate
10. Optionally restricts ports 80/443 to Cloudflare IPs only

---

#### `status`

Shows a complete health snapshot.

```bash
sudo cf-manager status
```

**Example output:**

```
─── Cloudflare Manager status ───

✓ Installed at : /usr/local/bin/cf-manager
✓ Credentials  : configured (/etc/cf-manager/config)
  Email     : you@example.com
  Account ID: a1b2c3d4e5f6...
✓ API token    : active and valid

Protected domains:
  ● example.com     — active
  ⏸ staging.com     — paused
  ○ newsite.com     — pending

Origin firewall:
✓ UFW has Cloudflare allow-list active
```

---

#### `disable [DOMAIN]` / `pause`

Pauses Cloudflare for a specific domain. **Traffic bypasses Cloudflare entirely** (DNS-only mode) — useful when troubleshooting whether an issue is caused by Cloudflare.

```bash
sudo cf-manager disable example.com
```

**Important:** No settings are lost. The zone remains configured; only the proxy is paused.

---

#### `enable [DOMAIN]` / `unpause`

Un-pauses Cloudflare. Protection returns instantly.

```bash
sudo cf-manager enable example.com
```

---

#### `uninstall` / `remove`

Removes the tool completely from the server.

```bash
sudo cf-manager uninstall
```

**Removes:**
- `/usr/local/bin/cf-manager`
- `/etc/cf-manager/` (credentials, domain list, backups)
- `/var/log/cf-manager.log`
- All Cloudflare-related firewall rules (UFW / firewalld / iptables)

**Optionally removes:**
- `/etc/ssl/cloudflare/` (origin certificates) — asks for confirmation

**Does NOT touch:**
- Your Cloudflare account
- Your DNS zones on Cloudflare
- Your DNS records (they remain protected)

---

#### `help`

Shows the command reference. **Works without root.**

```bash
cf-manager help
```

---

## File Locations

| Path | Mode | Purpose |
|---|---|---|
| `/usr/local/bin/cf-manager` | `755` | The installed executable |
| `/etc/cf-manager/` | `700` | Configuration directory (root-only) |
| `/etc/cf-manager/config` | `600` | API token, email, account ID |
| `/etc/cf-manager/domains` | `600` | List of protected domains (`domain\|zone_id`) |
| `/etc/cf-manager/backups/` | `700` | Firewall rule backups (timestamped) |
| `/var/log/cf-manager.log` | `600` | Action log |
| `/etc/ssl/cloudflare/` | `700` | Origin certificates directory |
| `/etc/ssl/cloudflare/<domain>.crt` | `644` | Origin certificate |
| `/etc/ssl/cloudflare/<domain>.key` | `600` | Origin private key |
| `/etc/ssl/cloudflare/<domain>.csr` | `644` | Certificate Signing Request |

---

## Web Server Integration

Once an Origin Certificate is generated, point your web server to it.

### Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name example.com www.example.com;

    ssl_certificate     /etc/ssl/cloudflare/example.com.crt;
    ssl_certificate_key /etc/ssl/cloudflare/example.com.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Restore real visitor IP from Cloudflare
    real_ip_header     CF-Connecting-IP;
    set_real_ip_from   173.245.48.0/20;
    set_real_ip_from   103.21.244.0/22;
    # ... (full list at https://www.cloudflare.com/ips/)

    root /var/www/example.com;
}
```

Reload Nginx:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

### Apache

```apache
<VirtualHost *:443>
    ServerName example.com
    ServerAlias www.example.com

    SSLEngine on
    SSLCertificateFile    /etc/ssl/cloudflare/example.com.crt
    SSLCertificateKeyFile /etc/ssl/cloudflare/example.com.key

    DocumentRoot /var/www/example.com
</VirtualHost>
```

Reload Apache:
```bash
sudo apachectl configtest && sudo systemctl reload apache2
```

### Restoring real visitor IP

When traffic comes through Cloudflare, the source IP is a Cloudflare edge IP. To see the real visitor IP in your logs, use the `CF-Connecting-IP` header (configured above for Nginx). Apache users can install the `mod_remoteip` module.

---

## Security

### What this script protects

- **Credentials at rest:** API token never echoed; config file mode `600`
- **Private keys:** mode `600`, stored under `/etc/ssl/cloudflare/`
- **Firewall backups:** every change saved to `/etc/cf-manager/backups/` before applying
- **Idempotent operations:** safe to re-run; no duplicate DNS records or firewall rules

### Best practices

1. **Use a scoped API token** — not the global API key
2. **Restrict the token to specific zones** if you don't manage all zones with this server
3. **Enable token IP filtering** in the Cloudflare dashboard to limit token usage to your server IP
4. **Rotate the token periodically** — re-run `sudo cf-manager setup` with the new value
5. **Keep your SSH port open** in the firewall before enabling origin protection (the script doesn't touch other ports, but verify yours)
6. **Review the log** at `/var/log/cf-manager.log` after each major change

---

## Troubleshooting

### `Invalid Cloudflare API token`

The token is missing required permissions or has been revoked. Recreate it with the permissions listed in the [API Token section](#cloudflare-api-token).

### `Could not detect server public IP`

The server can't reach `api.ipify.org`, `ifconfig.me`, or `icanhazip.com`. Check:
- Outbound HTTPS connectivity
- No restrictive firewall on egress
- Try: `curl -v https://api.ipify.org`

### Zone stays in `pending` status

Cloudflare hasn't detected the nameserver change yet. Run:

```bash
dig NS yourdomain.com
```

The result must show the Cloudflare nameservers (e.g. `*.ns.cloudflare.com`). If not, update them at your domain registrar. Propagation can take a few minutes to 48 hours.

### Locked out of HTTP/HTTPS after enabling origin firewall

The script backs up firewall rules before any change. Restore from backup:

**UFW:**
```bash
sudo ufw reset
# then manually re-add your rules from /etc/cf-manager/backups/
```

**iptables:**
```bash
sudo iptables-restore < /etc/cf-manager/backups/iptables-<timestamp>.bak
```

### `jq: command not found`

Re-run any command — the script's dependency installer will install it automatically.

### "I want to keep the script but remove a single domain"

The tool currently doesn't remove individual domains (this keeps the focus on safe lifecycle actions). To remove a domain from Cloudflare, do it through the Cloudflare dashboard, then manually edit `/etc/cf-manager/domains` to remove the corresponding line.

---

## FAQ

**Q: Can I run setup without owning a domain yet?**
Yes. The `setup` command only saves credentials. Add domains later with `add-domain`.

**Q: Does `disable` lose my settings?**
No. It only pauses the proxy. All DNS records, SSL settings, and firewall rules remain configured on Cloudflare. `enable` restores everything instantly.

**Q: Can I manage multiple domains?**
Yes. Run `add-domain` for each one. They all share the same credentials, and `status` shows all of them.

**Q: Will `uninstall` delete my zones from Cloudflare?**
No. Uninstall only removes local files and firewall rules. Your Cloudflare account, zones, and DNS records are untouched.

**Q: Is this safe to re-run?**
Yes — every command is idempotent. Re-running `add-domain` updates existing records rather than duplicating them.

**Q: Can I use the Global API Key instead of a token?**
No, by design. Tokens are scoped, revocable, and the official recommended method.

**Q: Does it support wildcard subdomains?**
The Origin Certificate covers `*.example.com` automatically. For DNS records, add each subdomain explicitly during `add-domain`.

**Q: What if my server is behind NAT?**
The script detects the **public** IP via external services. If your public IP differs from the server's local IP (NAT scenario), make sure port forwarding to 80/443 is configured on your router/firewall.

---

## License

MIT License. Free to use, modify, and redistribute.

---

## Author

**Eng. Sherif Hassan Elkhouly**
Dylanu — [https://dylanu.com](https://dylanu.com)

© 2026 — All rights reserved.
