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
- [Cloudflare API Token](#cloudflare-api-token)
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

### 1. Upload the script to your server

```bash
scp cf-manager.sh user@your-server:/tmp/
ssh user@your-server
```

### 2. Run the interactive menu

```bash
sudo bash /tmp/cf-manager.sh
```

### 3. Follow the menu

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

**Recommended first-time flow:** `1 → 2 → 3 → 4`

After installation (step `1`), you can run `sudo cf-manager` from anywhere.

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
