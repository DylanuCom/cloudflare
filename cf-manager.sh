#!/usr/bin/env bash
###############################################################################
#
#  Cloudflare Manager
#  ------------------
#  A simple, all-in-one tool to install, configure, manage, and remove
#  Cloudflare protection on a Linux server — all via SSH.
#
#  ---------------------------------------------------------------------------
#  Author    : Eng. Sherif Hassan Elkhouly
#  Company   : Dylanu  (https://dylanu.com)
#  Version   : 1.0.0
#  License   : MIT
#  Copyright : (c) 2026 Sherif Hassan Elkhouly — All rights reserved.
#  ---------------------------------------------------------------------------
#
#  Lifecycle:
#    1. Install    -> install dependencies and save the script system-wide
#    2. Setup      -> add API credentials (no domain required at this stage)
#    3. Add domain -> attach one or more domains to your Cloudflare account
#    4. Status     -> check the health of credentials, domains and firewall
#    5. Disable    -> temporarily turn Cloudflare protection off (pause zone)
#    6. Enable     -> turn protection back on
#    7. Uninstall  -> remove all files, configs and firewall rules
#
#  Usage:
#    sudo bash cf-manager.sh           (interactive menu)
#    sudo cf-manager install           (after installation)
#    sudo cf-manager status
#    sudo cf-manager add-domain example.com
#    sudo cf-manager disable example.com
#    sudo cf-manager uninstall
#
###############################################################################

set -o errexit
set -o nounset
set -o pipefail

###############################################################################
# CONFIGURATION
###############################################################################

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="cf-manager"
readonly INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"
readonly CONFIG_DIR="/etc/cf-manager"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly DOMAINS_FILE="${CONFIG_DIR}/domains"
readonly LOG_FILE="/var/log/cf-manager.log"
readonly BACKUP_DIR="${CONFIG_DIR}/backups"
readonly CF_API="https://api.cloudflare.com/client/v4"

# Colors
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'

# Runtime
CF_API_TOKEN=""
CF_ACCOUNT_ID=""
CF_EMAIL=""

###############################################################################
# OUTPUT HELPERS
###############################################################################

log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}" 2>/dev/null || true; }
msg()        { echo -e "$*"; log "$*"; }
ok()         { echo -e "${C_GREEN}✓${C_RESET} $*"; log "[OK]  $*"; }
warn()       { echo -e "${C_YELLOW}!${C_RESET} $*"; log "[WARN] $*"; }
err()        { echo -e "${C_RED}✗${C_RESET} $*" >&2; log "[ERR] $*"; }
info()       { echo -e "${C_BLUE}i${C_RESET} $*"; log "[INFO] $*"; }
step()       { echo -e "\n${C_CYAN}${C_BOLD}» $*${C_RESET}"; log "[STEP] $*"; }
die()        { err "$1"; exit "${2:-1}"; }

banner() {
    cat <<EOF
${C_CYAN}${C_BOLD}
┌───────────────────────────────────────────────┐
│                                               │
│           Cloudflare Manager  v${SCRIPT_VERSION}           │
│        Simple SSH-based protection tool       │
│                                               │
├───────────────────────────────────────────────┤
│  Eng. Sherif Hassan Elkhouly                  │
│  Dylanu  —  https://dylanu.com                │
└───────────────────────────────────────────────┘
${C_RESET}
EOF
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local hint="[y/N]"
    [[ "${default^^}" == "Y" ]] && hint="[Y/n]"

    local answer
    read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} ${prompt} ${hint}: ")" answer
    answer="${answer:-${default}}"
    [[ "${answer,,}" =~ ^(y|yes)$ ]]
}

###############################################################################
# PERMISSIONS & ENVIRONMENT
###############################################################################

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Please run as root: sudo bash $0"
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS (no /etc/os-release)."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID,,}"
}

install_deps() {
    local missing=()
    for cmd in curl jq openssl; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    info "Installing missing packages: ${missing[*]}"
    case "${OS_ID}" in
        ubuntu|debian)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command -v dnf >/dev/null; then
                dnf install -y "${missing[@]}" >/dev/null
            else
                yum install -y "${missing[@]}" >/dev/null
            fi
            ;;
        *)
            die "Unsupported OS: ${OS_ID}. Install manually: ${missing[*]}"
            ;;
    esac
    ok "Dependencies installed."
}

prepare_dirs() {
    mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}"
    chmod 700 "${CONFIG_DIR}"
    touch "${LOG_FILE}" "${DOMAINS_FILE}"
    chmod 600 "${LOG_FILE}" "${DOMAINS_FILE}"
}

###############################################################################
# CONFIG LOAD / SAVE
###############################################################################

save_config() {
    cat > "${CONFIG_FILE}" <<EOF
# Cloudflare Manager configuration
# Generated $(date '+%Y-%m-%d %H:%M:%S')
CF_API_TOKEN="${CF_API_TOKEN}"
CF_EMAIL="${CF_EMAIL}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        return 0
    fi
    return 1
}

require_config() {
    if ! load_config || [[ -z "${CF_API_TOKEN}" ]]; then
        die "No credentials found. Run setup first: sudo ${SCRIPT_NAME} setup"
    fi
}

###############################################################################
# CLOUDFLARE API
###############################################################################

cf() {
    # cf METHOD ENDPOINT [DATA]
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-sS -X "${method}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
    [[ -n "${data}" ]] && args+=(--data "${data}")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

cf_ok() {
    # cf_ok RESPONSE [CONTEXT]  → returns 0 if API said success:true
    local resp="$1" ctx="${2:-Cloudflare API}"
    if [[ "$(echo "${resp}" | jq -r '.success // false')" != "true" ]]; then
        err "${ctx} failed:"
        echo "${resp}" | jq -r '.errors[]? | "    [\(.code)] \(.message)"' 2>/dev/null \
            || echo "    (no error details)"
        return 1
    fi
    return 0
}

verify_token() {
    local resp
    resp="$(cf GET /user/tokens/verify)"
    cf_ok "${resp}" "Token verification" || return 1
    local status
    status="$(echo "${resp}" | jq -r '.result.status')"
    [[ "${status}" == "active" ]] || die "Token is not active (status: ${status})"
}

resolve_account() {
    local resp
    resp="$(cf GET /accounts)"
    cf_ok "${resp}" "Account lookup" || return 1
    local count
    count="$(echo "${resp}" | jq -r '.result | length')"
    [[ "${count}" -gt 0 ]] || die "No Cloudflare accounts found for this token."

    if [[ "${count}" -eq 1 ]]; then
        CF_ACCOUNT_ID="$(echo "${resp}" | jq -r '.result[0].id')"
    else
        echo
        info "Multiple accounts found:"
        echo "${resp}" | jq -r '.result | to_entries[] | "  \(.key+1)) \(.value.name) — \(.value.id)"'
        echo
        local choice
        read -r -p "Select account [1-${count}]: " choice
        CF_ACCOUNT_ID="$(echo "${resp}" | jq -r ".result[$((choice - 1))].id")"
    fi
    ok "Account: ${CF_ACCOUNT_ID}"
}

zone_id_for() {
    # zone_id_for DOMAIN  → prints zone ID, or empty
    local domain="$1"
    cf GET "/zones?name=${domain}" | jq -r '.result[0].id // empty'
}

###############################################################################
# 1) INSTALL
###############################################################################

cmd_install() {
    step "Installing Cloudflare Manager"
    install_deps
    prepare_dirs

    local source_path
    source_path="$(readlink -f "$0")"

    if [[ "${source_path}" != "${INSTALL_PATH}" ]]; then
        cp "${source_path}" "${INSTALL_PATH}"
        chmod 755 "${INSTALL_PATH}"
        ok "Installed to ${INSTALL_PATH}"
    else
        info "Already running from ${INSTALL_PATH}"
    fi

    cat <<EOF

${C_GREEN}${C_BOLD}Installation complete.${C_RESET}

You can now run the tool from anywhere:
  ${C_CYAN}sudo ${SCRIPT_NAME}${C_RESET}                    (interactive menu)
  ${C_CYAN}sudo ${SCRIPT_NAME} setup${C_RESET}              (add credentials)
  ${C_CYAN}sudo ${SCRIPT_NAME} add-domain DOMAIN${C_RESET}  (protect a domain)
  ${C_CYAN}sudo ${SCRIPT_NAME} status${C_RESET}             (check health)
  ${C_CYAN}sudo ${SCRIPT_NAME} help${C_RESET}               (full command list)

Next step: run ${C_BOLD}sudo ${SCRIPT_NAME} setup${C_RESET} to add your Cloudflare credentials.
EOF
}

###############################################################################
# 2) SETUP (credentials only — no domain required)
###############################################################################

cmd_setup() {
    step "Cloudflare credentials setup"
    prepare_dirs

    cat <<'EOF'

You need a Cloudflare API Token. Create one at:
  https://dash.cloudflare.com/profile/api-tokens

Required permissions:
  • Zone : Read, Edit
  • DNS : Edit
  • SSL and Certificates : Edit
  • Zone WAF : Edit
  • Account : Read

EOF

    while true; do
        read -r -s -p "$(echo -e "${C_YELLOW}?${C_RESET} Cloudflare API Token: ")" CF_API_TOKEN
        echo
        [[ -n "${CF_API_TOKEN}" && ${#CF_API_TOKEN} -ge 20 ]] && break
        warn "Token looks invalid. Try again."
    done

    read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} Cloudflare account email: ")" CF_EMAIL
    if [[ ! "${CF_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        die "Invalid email format."
    fi

    step "Verifying credentials"
    verify_token
    ok "Token is valid."

    step "Resolving account"
    resolve_account

    save_config
    ok "Configuration saved to ${CONFIG_FILE}"

    echo
    info "Setup is done. No domain is configured yet."
    info "To protect a domain run: ${C_CYAN}sudo ${SCRIPT_NAME} add-domain example.com${C_RESET}"
}

###############################################################################
# 3) ADD DOMAIN
###############################################################################

cmd_add_domain() {
    require_config
    verify_token

    local domain="${1:-}"
    if [[ -z "${domain}" ]]; then
        read -r -p "$(echo -e "${C_YELLOW}?${C_RESET} Domain to protect (e.g. example.com): ")" domain
    fi

    domain="${domain,,}"
    domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%/}"

    if [[ ! "${domain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        die "Invalid domain: ${domain}"
    fi

    step "Adding domain: ${domain}"

    # Get or create the zone
    local zone_id
    zone_id="$(zone_id_for "${domain}")"

    if [[ -n "${zone_id}" ]]; then
        ok "Zone already exists: ${zone_id}"
    else
        info "Creating zone on Cloudflare..."
        local payload resp
        payload="$(jq -n --arg n "${domain}" --arg a "${CF_ACCOUNT_ID}" \
            '{name:$n,account:{id:$a},type:"full",jump_start:true}')"
        resp="$(cf POST /zones "${payload}")"
        cf_ok "${resp}" "Zone creation" || die "Failed to create zone."
        zone_id="$(echo "${resp}" | jq -r '.result.id')"
        ok "Zone created: ${zone_id}"

        echo
        info "Update your domain registrar to use these nameservers:"
        echo "${resp}" | jq -r '.result.name_servers[]' | sed 's/^/    /'
        echo
        read -r -p "Press [Enter] once you've noted them..."
    fi

    # Detect public IP
    local server_ip=""
    for svc in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        server_ip="$(curl -fsS --max-time 5 "${svc}" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "${server_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        server_ip=""
    done
    [[ -n "${server_ip}" ]] || die "Could not detect server public IP."
    ok "Server public IP: ${server_ip}"

    # Create A records
    create_dns_record() {
        local type="$1" name="$2" content="$3" proxied="$4"
        local existing payload resp existing_id
        existing="$(cf GET "/zones/${zone_id}/dns_records?type=${type}&name=${name}")"
        existing_id="$(echo "${existing}" | jq -r '.result[0].id // empty')"
        payload="$(jq -n --arg t "${type}" --arg n "${name}" --arg c "${content}" \
            --argjson p "${proxied}" \
            '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')"
        if [[ -n "${existing_id}" ]]; then
            resp="$(cf PUT "/zones/${zone_id}/dns_records/${existing_id}" "${payload}")"
        else
            resp="$(cf POST "/zones/${zone_id}/dns_records" "${payload}")"
        fi
        cf_ok "${resp}" "DNS ${type} ${name}" && ok "DNS ${type} ${name} → ${content}"
    }

    step "Creating DNS records"
    create_dns_record A "${domain}" "${server_ip}" true
    create_dns_record A "www.${domain}" "${server_ip}" true

    # Optional subdomains
    if confirm "Add more subdomains now?" N; then
        while true; do
            read -r -p "Subdomain (Enter to finish): " sub
            [[ -z "${sub}" ]] && break
            sub="${sub,,}"; sub="${sub%%.*}"
            create_dns_record A "${sub}.${domain}" "${server_ip}" true
        done
    fi

    # SSL/TLS hardening
    step "Configuring SSL/TLS"
    cf PATCH "/zones/${zone_id}/settings/ssl"                      '{"value":"strict"}' >/dev/null && ok "SSL mode: Full (Strict)"
    cf PATCH "/zones/${zone_id}/settings/always_use_https"         '{"value":"on"}'     >/dev/null && ok "Always Use HTTPS"
    cf PATCH "/zones/${zone_id}/settings/automatic_https_rewrites" '{"value":"on"}'     >/dev/null && ok "Automatic HTTPS Rewrites"
    cf PATCH "/zones/${zone_id}/settings/min_tls_version"          '{"value":"1.2"}'    >/dev/null && ok "Minimum TLS 1.2"
    cf PATCH "/zones/${zone_id}/settings/tls_1_3"                  '{"value":"on"}'     >/dev/null && ok "TLS 1.3"

    # Security
    step "Configuring security settings"
    cf PATCH "/zones/${zone_id}/settings/security_level"           '{"value":"medium"}' >/dev/null && ok "Security: Medium"
    cf PATCH "/zones/${zone_id}/settings/browser_check"            '{"value":"on"}'     >/dev/null && ok "Browser Integrity Check"
    cf PATCH "/zones/${zone_id}/settings/email_obfuscation"        '{"value":"on"}'     >/dev/null && ok "Email Obfuscation"

    # Performance
    step "Configuring performance"
    cf PATCH "/zones/${zone_id}/settings/brotli" '{"value":"on"}' >/dev/null && ok "Brotli"
    cf PATCH "/zones/${zone_id}/settings/http3"  '{"value":"on"}' >/dev/null && ok "HTTP/3"
    cf PATCH "/zones/${zone_id}/settings/0rtt"   '{"value":"on"}' >/dev/null && ok "0-RTT"

    # Origin Certificate
    if confirm "Generate a free 15-year Origin Certificate?" Y; then
        generate_origin_cert "${domain}"
    fi

    # Origin firewall
    if confirm "Restrict ports 80/443 to Cloudflare IPs only? (recommended)" Y; then
        protect_origin
    fi

    # Track domain
    if ! grep -qx "${domain}|${zone_id}" "${DOMAINS_FILE}" 2>/dev/null; then
        echo "${domain}|${zone_id}" >> "${DOMAINS_FILE}"
    fi

    echo
    ok "Domain ${domain} is fully configured."
    info "Dashboard: https://dash.cloudflare.com/${CF_ACCOUNT_ID}/${domain}"
}

generate_origin_cert() {
    local domain="$1"
    step "Generating Origin Certificate for ${domain}"
    local cdir="/etc/ssl/cloudflare"
    mkdir -p "${cdir}"; chmod 700 "${cdir}"

    openssl genrsa -out "${cdir}/${domain}.key" 2048 2>/dev/null
    chmod 600 "${cdir}/${domain}.key"
    openssl req -new -key "${cdir}/${domain}.key" -out "${cdir}/${domain}.csr" \
        -subj "/CN=${domain}/O=Cloudflare Origin/C=US" 2>/dev/null

    local payload resp
    payload="$(jq -n --arg csr "$(cat "${cdir}/${domain}.csr")" --arg d "${domain}" --arg w "*.${domain}" \
        '{hostnames:[$d,$w],requested_validity:5475,request_type:"origin-rsa",csr:$csr}')"
    resp="$(cf POST /certificates "${payload}")"

    if cf_ok "${resp}" "Origin Certificate"; then
        echo "${resp}" | jq -r '.result.certificate' > "${cdir}/${domain}.crt"
        chmod 644 "${cdir}/${domain}.crt"
        ok "Certificate : ${cdir}/${domain}.crt"
        ok "Private key : ${cdir}/${domain}.key"
        ok "Valid for   : 15 years"
    fi
}

protect_origin() {
    step "Restricting origin to Cloudflare IPs"
    local cf4 cf6
    cf4="$(curl -fsS https://www.cloudflare.com/ips-v4 || true)"
    cf6="$(curl -fsS https://www.cloudflare.com/ips-v6 || true)"
    [[ -n "${cf4}" ]] || { warn "Cannot fetch Cloudflare IPs; skipping."; return 1; }

    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw status numbered > "${BACKUP_DIR}/ufw-$(date +%s).bak" 2>/dev/null || true
        ufw delete allow 80/tcp  >/dev/null 2>&1 || true
        ufw delete allow 443/tcp >/dev/null 2>&1 || true
        while IFS= read -r ip; do
            [[ -z "${ip}" ]] && continue
            ufw allow from "${ip}" to any port 80  proto tcp comment "CF" >/dev/null
            ufw allow from "${ip}" to any port 443 proto tcp comment "CF" >/dev/null
        done <<< "${cf4}${cf6:+$'\n'}${cf6}"
        ufw reload >/dev/null
        ok "UFW updated."
    elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --new-zone=cloudflare 2>/dev/null || true
        firewall-cmd --permanent --zone=cloudflare --set-target=ACCEPT >/dev/null
        while IFS= read -r ip; do
            [[ -z "${ip}" ]] && continue
            firewall-cmd --permanent --zone=cloudflare --add-source="${ip}" >/dev/null
        done <<< "${cf4}${cf6:+$'\n'}${cf6}"
        firewall-cmd --permanent --zone=cloudflare --add-service=http  >/dev/null
        firewall-cmd --permanent --zone=cloudflare --add-service=https >/dev/null
        firewall-cmd --permanent --zone=public --remove-service=http  2>/dev/null || true
        firewall-cmd --permanent --zone=public --remove-service=https 2>/dev/null || true
        firewall-cmd --reload >/dev/null
        ok "firewalld updated."
    else
        iptables-save > "${BACKUP_DIR}/iptables-$(date +%s).bak" 2>/dev/null || true
        iptables -N CLOUDFLARE 2>/dev/null || iptables -F CLOUDFLARE
        while IFS= read -r ip; do
            [[ -z "${ip}" ]] && continue
            iptables -A CLOUDFLARE -s "${ip}" -j ACCEPT
        done <<< "${cf4}"
        iptables -I INPUT -p tcp -m multiport --dports 80,443 -j CLOUDFLARE
        iptables -A INPUT  -p tcp -m multiport --dports 80,443 -j DROP
        ok "iptables updated."
    fi
}

###############################################################################
# 4) STATUS
###############################################################################

cmd_status() {
    echo
    echo -e "${C_BOLD}─── Cloudflare Manager status ───${C_RESET}"
    echo

    # Installation
    if [[ -f "${INSTALL_PATH}" ]]; then
        ok "Installed at : ${INSTALL_PATH}"
    else
        warn "Not installed system-wide (run: sudo bash $0 install)"
    fi

    # Configuration
    if load_config && [[ -n "${CF_API_TOKEN}" ]]; then
        ok "Credentials  : configured (${CONFIG_FILE})"
        echo -e "  ${C_DIM}Email     : ${CF_EMAIL}${C_RESET}"
        echo -e "  ${C_DIM}Account ID: ${CF_ACCOUNT_ID}${C_RESET}"

        if verify_token 2>/dev/null; then
            ok "API token    : active and valid"
        else
            err "API token    : invalid or expired"
        fi
    else
        warn "Credentials  : not set (run: sudo ${SCRIPT_NAME} setup)"
        return 0
    fi

    # Domains
    echo
    if [[ -s "${DOMAINS_FILE}" ]]; then
        echo -e "${C_BOLD}Protected domains:${C_RESET}"
        while IFS='|' read -r domain zone_id; do
            [[ -z "${domain}" ]] && continue
            local resp status paused
            resp="$(cf GET "/zones/${zone_id}" 2>/dev/null)"
            status="$(echo "${resp}" | jq -r '.result.status // "unknown"')"
            paused="$(echo "${resp}" | jq -r '.result.paused // false')"

            local icon color label
            if [[ "${paused}" == "true" ]]; then
                icon="⏸"; color="${C_YELLOW}"; label="paused"
            elif [[ "${status}" == "active" ]]; then
                icon="●"; color="${C_GREEN}"; label="active"
            else
                icon="○"; color="${C_YELLOW}"; label="${status}"
            fi
            echo -e "  ${color}${icon}${C_RESET} ${domain} ${C_DIM}— ${label}${C_RESET}"
        done < "${DOMAINS_FILE}"
    else
        info "No domains added yet (run: sudo ${SCRIPT_NAME} add-domain DOMAIN)"
    fi

    # Firewall
    echo
    echo -e "${C_BOLD}Origin firewall:${C_RESET}"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Cloudflare"; then
        ok "UFW has Cloudflare allow-list active"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --get-zones 2>/dev/null | grep -qw cloudflare; then
        ok "firewalld 'cloudflare' zone is active"
    elif iptables -L CLOUDFLARE -n >/dev/null 2>&1; then
        ok "iptables CLOUDFLARE chain is active"
    else
        warn "No Cloudflare-only firewall rules detected"
    fi
    echo
}

###############################################################################
# 5/6) DISABLE / ENABLE
###############################################################################

cmd_disable() {
    require_config; verify_token
    local domain="${1:-}"
    [[ -z "${domain}" ]] && read -r -p "Domain to disable: " domain

    local zone_id
    zone_id="$(zone_id_for "${domain}")"
    [[ -n "${zone_id}" ]] || die "Zone not found for ${domain}"

    step "Pausing Cloudflare for ${domain}"
    local resp
    resp="$(cf POST "/zones/${zone_id}/pause" '{}')"
    cf_ok "${resp}" "Pause zone" && ok "Cloudflare is now paused for ${domain}"
    info "Traffic will bypass Cloudflare (DNS-only). Re-enable with: ${C_CYAN}${SCRIPT_NAME} enable ${domain}${C_RESET}"
}

cmd_enable() {
    require_config; verify_token
    local domain="${1:-}"
    [[ -z "${domain}" ]] && read -r -p "Domain to enable: " domain

    local zone_id
    zone_id="$(zone_id_for "${domain}")"
    [[ -n "${zone_id}" ]] || die "Zone not found for ${domain}"

    step "Re-enabling Cloudflare for ${domain}"
    local resp
    resp="$(cf POST "/zones/${zone_id}/unpause" '{}')"
    cf_ok "${resp}" "Unpause zone" && ok "Cloudflare is now active for ${domain}"
}

###############################################################################
# 7) UNINSTALL
###############################################################################

cmd_uninstall() {
    step "Uninstalling Cloudflare Manager"

    cat <<EOF

${C_YELLOW}This will remove:${C_RESET}
  • ${INSTALL_PATH}
  • ${CONFIG_DIR}  (credentials, domain list, backups)
  • ${LOG_FILE}
  • Cloudflare firewall rules (UFW / firewalld / iptables)

${C_YELLOW}This will NOT touch:${C_RESET}
  • Your Cloudflare account or zones (they remain protected)
  • SSL certificates under /etc/ssl/cloudflare/ (kept by default)

EOF

    confirm "Continue?" N || { info "Cancelled."; return 0; }

    # Optional: also remove certs
    if confirm "Also delete origin certificates in /etc/ssl/cloudflare/?" N; then
        rm -rf /etc/ssl/cloudflare
        ok "Certificates removed."
    fi

    # Firewall cleanup
    step "Cleaning firewall rules"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        # Remove all rules with the "CF" or "Cloudflare" comment
        while ufw status numbered | grep -E "Cloudflare|CF" | head -1 | grep -qoE '\[[ 0-9]+\]'; do
            local num
            num="$(ufw status numbered | grep -E "Cloudflare|CF" | head -1 | grep -oE '[0-9]+' | head -1)"
            yes | ufw delete "${num}" >/dev/null 2>&1 || break
        done
        ok "UFW rules cleared."
    fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --get-zones 2>/dev/null | grep -qw cloudflare; then
        firewall-cmd --permanent --delete-zone=cloudflare >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "firewalld zone removed."
    fi
    if iptables -L CLOUDFLARE -n >/dev/null 2>&1; then
        iptables -D INPUT -p tcp -m multiport --dports 80,443 -j CLOUDFLARE 2>/dev/null || true
        iptables -D INPUT -p tcp -m multiport --dports 80,443 -j DROP 2>/dev/null || true
        iptables -F CLOUDFLARE 2>/dev/null || true
        iptables -X CLOUDFLARE 2>/dev/null || true
        ok "iptables chain removed."
    fi

    # Files
    rm -rf "${CONFIG_DIR}"
    rm -f  "${LOG_FILE}"
    rm -f  "${INSTALL_PATH}"

    echo
    ok "Cloudflare Manager has been completely removed."
    info "Your Cloudflare account and DNS zones are untouched on cloudflare.com."
}

###############################################################################
# HELP
###############################################################################

cmd_help() {
    cat <<EOF

${C_BOLD}Cloudflare Manager${C_RESET}  v${SCRIPT_VERSION}

${C_BOLD}USAGE${C_RESET}
  sudo bash $0                       interactive menu
  sudo ${SCRIPT_NAME} <command> [arg]       after installation

${C_BOLD}COMMANDS${C_RESET}
  ${C_CYAN}install${C_RESET}                 install dependencies and copy script to ${INSTALL_PATH}
  ${C_CYAN}setup${C_RESET}                   save Cloudflare API credentials (no domain needed)
  ${C_CYAN}add-domain [DOMAIN]${C_RESET}     add a domain to your Cloudflare account
  ${C_CYAN}status${C_RESET}                  show health of installation, credentials and zones
  ${C_CYAN}disable [DOMAIN]${C_RESET}        pause Cloudflare for a domain (traffic bypasses CF)
  ${C_CYAN}enable  [DOMAIN]${C_RESET}        un-pause Cloudflare for a domain
  ${C_CYAN}uninstall${C_RESET}               remove the tool, config and firewall rules
  ${C_CYAN}help${C_RESET}                    show this message

${C_BOLD}FILES${C_RESET}
  ${INSTALL_PATH}     the installed binary
  ${CONFIG_FILE}      credentials (mode 600)
  ${DOMAINS_FILE}     list of protected domains
  ${LOG_FILE}         action log

${C_DIM}─────────────────────────────────────────────────${C_RESET}
${C_DIM}  Author : Eng. Sherif Hassan Elkhouly${C_RESET}
${C_DIM}  Company: Dylanu  —  https://dylanu.com${C_RESET}
${C_DIM}  License: MIT  ·  © 2026${C_RESET}

EOF
}

###############################################################################
# INTERACTIVE MENU
###############################################################################

menu() {
    banner

    # Show current state at top of menu
    if load_config && [[ -n "${CF_API_TOKEN}" ]]; then
        echo -e "  Status: ${C_GREEN}credentials configured${C_RESET}"
        local count
        count="$(grep -c . "${DOMAINS_FILE}" 2>/dev/null || echo 0)"
        echo -e "  Domains tracked: ${count}"
    else
        echo -e "  Status: ${C_YELLOW}not configured${C_RESET}"
    fi

    cat <<EOF

  ${C_BOLD}1)${C_RESET} Install (system-wide)
  ${C_BOLD}2)${C_RESET} Setup credentials  ${C_DIM}(no domain required)${C_RESET}
  ${C_BOLD}3)${C_RESET} Add / protect a domain
  ${C_BOLD}4)${C_RESET} Check status
  ${C_BOLD}5)${C_RESET} Disable (pause) a domain
  ${C_BOLD}6)${C_RESET} Enable (unpause) a domain
  ${C_BOLD}7)${C_RESET} Uninstall
  ${C_BOLD}8)${C_RESET} Help
  ${C_BOLD}0)${C_RESET} Exit

EOF
    read -r -p "Select an option [0-8]: " choice
    echo
    case "${choice}" in
        1) cmd_install ;;
        2) cmd_setup ;;
        3) cmd_add_domain ;;
        4) cmd_status ;;
        5) cmd_disable ;;
        6) cmd_enable ;;
        7) cmd_uninstall ;;
        8) cmd_help ;;
        0) exit 0 ;;
        *) warn "Invalid choice."; sleep 1; menu ;;
    esac
}

###############################################################################
# ENTRY POINT
###############################################################################

main() {
    local cmd="${1:-menu}"

    # `help` is the only command that doesn't need root.
    if [[ "${cmd}" == "help" || "${cmd}" == "--help" || "${cmd}" == "-h" ]]; then
        cmd_help
        exit 0
    fi

    require_root
    detect_os
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

    shift || true

    case "${cmd}" in
        install)         cmd_install ;;
        setup)           install_deps; prepare_dirs; cmd_setup ;;
        add-domain|add)  install_deps; prepare_dirs; cmd_add_domain "$@" ;;
        status)          cmd_status ;;
        disable|pause)   cmd_disable "$@" ;;
        enable|unpause)  cmd_enable "$@" ;;
        uninstall|remove)cmd_uninstall ;;
        menu|"")         install_deps; prepare_dirs; menu ;;
        *)               err "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
