#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - Security Module
# Manages firewall rules, fail2ban, rate limiting, and IP whitelisting
################################################################################

[[ -n "${_SECURITY_LOADED:-}" ]] && return 0
_SECURITY_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

FIREWALL_BACKEND="${FIREWALL_BACKEND:-iptables}"
FIREWALL_WHITELIST_FILE="${FIREWALL_WHITELIST_FILE:-/etc/sshvpnpanel/firewall_whitelist.conf}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Firewall helpers
# ---------------------------------------------------------------------------

firewall_is_ufw() {
    [[ "$FIREWALL_BACKEND" == "ufw" ]] && command -v ufw >/dev/null 2>&1
}

firewall_is_iptables() {
    command -v iptables >/dev/null 2>&1
}

# Apply default firewall rules for the SSH VPN Panel
firewall_apply_defaults() {
    check_root || return 1

    log_info "Applying default firewall rules..."

    if firewall_is_ufw; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "${SSH_PORT}/tcp" comment "SSH VPN Panel - SSH"
        ufw allow "80/tcp"  comment "HTTP"
        ufw allow "443/tcp" comment "HTTPS/Stunnel"
        ufw --force enable
    elif firewall_is_iptables; then
        # Flush existing rules
        iptables -F INPUT 2>/dev/null || true
        iptables -F FORWARD 2>/dev/null || true

        # Default policies
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        # Allow loopback
        iptables -A INPUT -i lo -j ACCEPT

        # Allow established/related connections
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # Allow SSH
        iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT

        # Allow HTTP/HTTPS
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    fi

    log_audit "FIREWALL_DEFAULTS_APPLIED" "SYSTEM"
    print_success "Default firewall rules applied."
}

# ---------------------------------------------------------------------------
# Per-user firewall rules
# ---------------------------------------------------------------------------

# Add firewall whitelist entry for a user
# Usage: firewall_add_user USERNAME [ip_address]
firewall_add_user() {
    local username="$1"
    local ip_address="${2:-ANY}"

    check_root || return 1
    ensure_dir "$(dirname "$FIREWALL_WHITELIST_FILE")" 750 root

    # Record in whitelist file
    local entry
    entry="${username}:${ip_address}:$(date '+%Y-%m-%d %H:%M:%S')"
    if ! grep -q "^${username}:" "$FIREWALL_WHITELIST_FILE" 2>/dev/null; then
        echo "$entry" >> "$FIREWALL_WHITELIST_FILE"
    fi

    # If a specific IP, add an iptables allow rule
    if [[ "$ip_address" != "ANY" ]]; then
        validate_ip "$ip_address" || { log_warn "Invalid IP ${ip_address}; whitelist file updated but no iptables rule added."; return 0; }
        if firewall_is_iptables; then
            # Check if rule already exists
            if ! iptables -C INPUT -s "$ip_address" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -s "$ip_address" -m comment --comment "sshvpnpanel:user:${username}" -j ACCEPT
                log_info "Added firewall allow rule for IP ${ip_address} (user: ${username})"
            fi
        elif firewall_is_ufw; then
            ufw allow from "$ip_address" comment "sshvpnpanel:user:${username}" 2>/dev/null || true
        fi
    fi

    log_audit "FIREWALL_USER_ADDED" "$username" "ip=${ip_address}"
    print_success "Firewall whitelist entry added for '${username}' (IP: ${ip_address})."
    return 0
}

# Remove firewall rules for a user
firewall_remove_user() {
    local username="$1"

    check_root || return 1

    # Remove from whitelist file
    if [[ -f "$FIREWALL_WHITELIST_FILE" ]]; then
        sed -i "/^${username}:/d" "$FIREWALL_WHITELIST_FILE"
    fi

    # Remove iptables rules for this user
    if firewall_is_iptables; then
        # Remove all rules matching this user's comment
        while iptables -D INPUT -m comment --comment "sshvpnpanel:user:${username}" -j ACCEPT 2>/dev/null; do
            true  # keep deleting until no more matches
        done
        log_info "Removed iptables rules for user: ${username}"
    elif firewall_is_ufw; then
        # ufw doesn't easily support deletion by comment; log warning
        log_warn "UFW: Manual removal of rules for user '${username}' may be required."
    fi

    log_audit "FIREWALL_USER_REMOVED" "$username"
    print_success "Firewall rules removed for '${username}'."
    return 0
}

# Add a rate-limiting rule for SSH connections from a user's IP
firewall_add_rate_limit() {
    local username="$1"
    local rate="${2:-5}"     # connections per minute
    local burst="${3:-10}"

    check_root || return 1

    if firewall_is_iptables; then
        local chain="SSHVPN_RATELIMIT_${username^^}"
        # Create a user-specific chain if needed
        iptables -N "$chain" 2>/dev/null || true
        iptables -F "$chain" 2>/dev/null || true

        iptables -A "$chain" -m recent --name "ssh_${username}" --update \
            --seconds 60 --hitcount "$burst" -j DROP
        iptables -A "$chain" -m recent --name "ssh_${username}" --set -j ACCEPT

        # Insert jump into INPUT if not already there
        if ! iptables -C INPUT -p tcp --dport "${SSH_PORT}" \
               -m comment --comment "sshvpnpanel:ratelimit:${username}" -j "$chain" 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "${SSH_PORT}" \
                -m comment --comment "sshvpnpanel:ratelimit:${username}" -j "$chain"
        fi

        log_audit "FIREWALL_RATE_LIMIT_ADDED" "$username" "rate=${rate}/min burst=${burst}"
        print_success "Rate limit added for '${username}': ${rate}/min (burst ${burst})."
    else
        log_warn "Rate limiting via iptables is not available with backend: ${FIREWALL_BACKEND}"
    fi
    return 0
}

# Remove rate-limiting rules for a user
firewall_remove_rate_limit() {
    local username="$1"

    if firewall_is_iptables; then
        local chain="SSHVPN_RATELIMIT_${username^^}"
        # Remove jump rule from INPUT
        iptables -D INPUT -p tcp --dport "${SSH_PORT}" \
            -m comment --comment "sshvpnpanel:ratelimit:${username}" -j "$chain" 2>/dev/null || true
        # Flush and remove the chain
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true

        log_info "Rate limit rules removed for user: ${username}"
        log_audit "FIREWALL_RATE_LIMIT_REMOVED" "$username"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Fail2ban integration
# ---------------------------------------------------------------------------

# Create a fail2ban jail for a user (banning on repeated failures)
fail2ban_add_user_jail() {
    local username="$1"
    local jail_dir="/etc/fail2ban/jail.d"
    local jail_file="${jail_dir}/sshvpnpanel-${username}.conf"

    command -v fail2ban-client >/dev/null 2>&1 || { log_warn "fail2ban not installed; skipping."; return 0; }
    ensure_dir "$jail_dir" 755 root

    cat > "$jail_file" << EOF
[sshvpnpanel-${username}]
enabled  = true
filter   = sshd
logpath  = /var/log/auth.log
maxretry = ${FAIL2BAN_SSH_MAXRETRY:-3}
findtime = ${FAIL2BAN_SSH_FINDTIME:-600}
bantime  = ${FAIL2BAN_SSH_BANTIME:-3600}
EOF

    fail2ban-client reload 2>/dev/null || true
    log_audit "FAIL2BAN_JAIL_ADDED" "$username"
    return 0
}

# Remove fail2ban jail for a user
fail2ban_remove_user_jail() {
    local username="$1"
    local jail_file="/etc/fail2ban/jail.d/sshvpnpanel-${username}.conf"

    if [[ -f "$jail_file" ]]; then
        rm -f "$jail_file"
        fail2ban-client reload 2>/dev/null || true
        log_audit "FAIL2BAN_JAIL_REMOVED" "$username"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------

# Apply SSH hardening settings to sshd_config
ssh_apply_hardening() {
    check_root || return 1
    local sshd_config="${SSH_CONFIG:-/etc/ssh/sshd_config}"
    backup_file "$sshd_config"

    log_info "Applying SSH hardening settings..."

    local settings=(
        "PermitEmptyPasswords no"
        "X11Forwarding no"
        "TCPKeepAlive yes"
        "ClientAliveInterval 300"
        "ClientAliveCountMax 3"
        "MaxAuthTries ${SECURITY_MAX_AUTH_TRIES:-3}"
        "LoginGraceTime ${SECURITY_LOGIN_GRACE_TIME:-30}"
        "PermitRootLogin ${SECURITY_PERMIT_ROOT_LOGIN:-no}"
        "PasswordAuthentication ${SECURITY_PASSWORD_AUTH:-yes}"
        "PubkeyAuthentication ${SECURITY_PUBKEY_AUTH:-yes}"
    )

    for setting in "${settings[@]}"; do
        local key value
        key="${setting%% *}"
        value="${setting#* }"
        if grep -q "^${key}" "$sshd_config"; then
            sed -i "s/^${key}.*/${key} ${value}/" "$sshd_config"
        else
            echo "${key} ${value}" >> "$sshd_config"
        fi
    done

    log_audit "SSH_HARDENING_APPLIED" "SYSTEM"
    print_success "SSH hardening settings applied."
}

# ---------------------------------------------------------------------------
# Whitelist display
# ---------------------------------------------------------------------------

firewall_list_users() {
    print_section "Firewall Whitelist"
    if [[ -f "$FIREWALL_WHITELIST_FILE" ]] && [[ -s "$FIREWALL_WHITELIST_FILE" ]]; then
        printf "  %-20s %-20s %-20s\n" "USERNAME" "IP" "ADDED"
        printf "  %-20s %-20s %-20s\n" "--------" "--" "-----"
        while IFS=':' read -r user ip ts; do
            [[ -z "$user" ]] && continue
            printf "  %-20s %-20s %-20s\n" "$user" "$ip" "$ts"
        done < "$FIREWALL_WHITELIST_FILE"
    else
        print_info "Firewall whitelist is empty."
    fi
}
