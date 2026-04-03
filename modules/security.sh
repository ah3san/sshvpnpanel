#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - Security Module
# =============================================================================
# Handles firewall management, IP whitelist/blacklist, failed login tracking,
# audit logging, rate limiting, and admin authentication.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# AUTHENTICATION
# =============================================================================

ADMIN_DB_DIR="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/admins"
SESSION_FILE="${TMP_DIR:-/tmp/sshvpnpanel}/session"
FAILED_LOGINS_FILE="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/failed_logins.db"
LOCKOUT_FILE="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/lockouts.db"

# Initialize security subsystem
init_security() {
    mkdir -p "${ADMIN_DB_DIR}" 2>/dev/null
    chmod 700 "${ADMIN_DB_DIR}" 2>/dev/null
    touch "${FAILED_LOGINS_FILE}" 2>/dev/null
    touch "${LOCKOUT_FILE}" 2>/dev/null

    # Create default admin if none exists
    if [[ ! -f "${ADMIN_DB_DIR}/admin.conf" ]]; then
        _create_default_admin
    fi
}

_create_default_admin() {
    local default_hash
    default_hash="${ADMIN_PASSWORD_HASH:-240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9}"
    cat > "${ADMIN_DB_DIR}/admin.conf" << EOF
USERNAME=admin
PASSWORD_HASH=${default_hash}
ROLE=admin
CREATED=$(get_timestamp)
LAST_LOGIN=never
LOGIN_COUNT=0
ENABLED=yes
REQUIRE_CHANGE=yes
EOF
    chmod 600 "${ADMIN_DB_DIR}/admin.conf"
}

# Check if an IP is locked out
is_locked_out() {
    local identifier="${1:-}"
    [[ -z "${identifier}" ]] && return 1

    if [[ -f "${LOCKOUT_FILE}" ]]; then
        local lockout_entry
        lockout_entry="$(grep "^${identifier}:" "${LOCKOUT_FILE}" 2>/dev/null)"
        if [[ -n "${lockout_entry}" ]]; then
            local lockout_time="${lockout_entry##*:}"
            local lockout_duration="${LOCKOUT_DURATION:-30}"
            local now
            now="$(date +%s)"
            local unlock_time=$(( lockout_time + lockout_duration * 60 ))
            if [[ "${now}" -lt "${unlock_time}" ]]; then
                return 0  # Still locked out
            else
                # Lockout expired, remove it
                sed -i "/^${identifier}:/d" "${LOCKOUT_FILE}" 2>/dev/null
            fi
        fi
    fi
    return 1
}

# Record a failed login attempt
record_failed_login() {
    local identifier="${1:-unknown}"
    local timestamp
    timestamp="$(date +%s)"

    echo "${identifier}:${timestamp}" >> "${FAILED_LOGINS_FILE}" 2>/dev/null

    # Count recent failures
    local window
    window=$(( timestamp - 600 ))  # Last 10 minutes
    local recent_failures=0
    if [[ -f "${FAILED_LOGINS_FILE}" ]]; then
        while IFS=: read -r id ts; do
            [[ "${id}" == "${identifier}" && "${ts}" -gt "${window}" ]] && \
                (( recent_failures++ ))
        done < "${FAILED_LOGINS_FILE}"
    fi

    # Lockout if threshold exceeded
    if [[ "${recent_failures}" -ge "${MAX_LOGIN_ATTEMPTS:-5}" ]]; then
        echo "${identifier}:${timestamp}" >> "${LOCKOUT_FILE}" 2>/dev/null
        log_warn "Locked out ${identifier} after ${recent_failures} failed attempts"
        log_audit "lockout" "identifier=${identifier},attempts=${recent_failures}"
        return 1
    fi

    return 0
}

# Authenticate admin user
authenticate_admin() {
    local username="${1:-}"
    local password="${2:-}"

    # Check lockout
    local client_ip
    client_ip="${CLIENT_IP:-127.0.0.1}"
    if is_locked_out "${client_ip}"; then
        print_error "Too many failed login attempts. Please try again later."
        return 1
    fi

    # Find admin record
    local admin_file="${ADMIN_DB_DIR}/${username}.conf"
    if [[ ! -f "${admin_file}" ]]; then
        record_failed_login "${client_ip}"
        log_warn "Failed login: unknown user ${username} from ${client_ip}"
        return 1
    fi

    local enabled
    enabled="$(config_get "${admin_file}" "ENABLED" "yes")"
    if [[ "${enabled}" != "yes" ]]; then
        print_error "Account is disabled"
        return 1
    fi

    # Verify password hash
    local stored_hash
    stored_hash="$(config_get "${admin_file}" "PASSWORD_HASH")"
    local provided_hash
    provided_hash="$(hash_password "${password}")"

    if [[ "${stored_hash}" == "${provided_hash}" ]]; then
        # Successful login
        local timestamp
        timestamp="$(get_timestamp)"
        config_set "${admin_file}" "LAST_LOGIN" "${timestamp}"
        local count
        count="$(config_get "${admin_file}" "LOGIN_COUNT" "0")"
        config_set "${admin_file}" "LOGIN_COUNT" "$((count + 1))"

        # Set session
        local role
        role="$(config_get "${admin_file}" "ROLE" "admin")"
        CURRENT_USER="${username}"
        CURRENT_ROLE="${role}"
        echo "USERNAME=${username}" > "${SESSION_FILE}"
        echo "ROLE=${role}" >> "${SESSION_FILE}"
        echo "LOGIN_TIME=${timestamp}" >> "${SESSION_FILE}"
        echo "TOKEN=$(random_string 32)" >> "${SESSION_FILE}"
        chmod 600 "${SESSION_FILE}"

        log_audit "admin_login" "username=${username},role=${role}"

        # Check if password change required
        local require_change
        require_change="$(config_get "${admin_file}" "REQUIRE_CHANGE" "no")"
        if [[ "${require_change}" == "yes" && \
              "${REQUIRE_PASSWORD_CHANGE:-yes}" == "yes" ]]; then
            print_warning "You must change your password before continuing."
            change_admin_password "${username}"
        fi

        return 0
    else
        record_failed_login "${client_ip}"
        log_warn "Failed login: wrong password for ${username} from ${client_ip}"
        log_audit "admin_login_fail" "username=${username}"
        return 1
    fi
}

# Panel login prompt
panel_login() {
    clear_screen
    print_header "Panel Authentication"

    echo -e "\n  ${C_BOLD}Please log in to continue${C_RESET}\n"

    local attempts=0
    local max_attempts="${MAX_LOGIN_ATTEMPTS:-5}"

    while [[ "${attempts}" -lt "${max_attempts}" ]]; do
        local username
        read_input "Username" "" username
        [[ -z "${username}" ]] && continue

        local password
        read_password "Password" password

        if authenticate_admin "${username}" "${password}"; then
            print_success "Welcome, ${username}! (${CURRENT_ROLE})"
            sleep 1
            return 0
        else
            (( attempts++ ))
            local remaining=$(( max_attempts - attempts ))
            if [[ "${remaining}" -gt 0 ]]; then
                print_error "Invalid credentials. ${remaining} attempts remaining."
            else
                print_error "Maximum login attempts exceeded."
                return 1
            fi
        fi
    done

    return 1
}

# Logout and clear session
panel_logout() {
    rm -f "${SESSION_FILE}" 2>/dev/null
    CURRENT_USER=""
    CURRENT_ROLE=""
    log_audit "admin_logout" "username=${CURRENT_USER:-unknown}"
    print_success "Logged out successfully"
}

# Check if logged in and session is valid
check_session() {
    if [[ ! -f "${SESSION_FILE}" ]]; then
        return 1
    fi

    local login_time
    login_time="$(config_get "${SESSION_FILE}" "LOGIN_TIME")"
    local timeout="${SESSION_TIMEOUT:-30}"

    if [[ "${timeout}" -gt 0 && -n "${login_time}" ]]; then
        # Check session timeout (convert login time to epoch)
        local login_epoch
        login_epoch="$(date -d "${login_time}" +%s 2>/dev/null || echo 0)"
        local now_epoch
        now_epoch="$(date +%s)"
        local elapsed=$(( (now_epoch - login_epoch) / 60 ))

        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            rm -f "${SESSION_FILE}" 2>/dev/null
            print_warning "Session expired. Please log in again."
            return 1
        fi
    fi

    CURRENT_USER="$(config_get "${SESSION_FILE}" "USERNAME")"
    CURRENT_ROLE="$(config_get "${SESSION_FILE}" "ROLE" "admin")"
    return 0
}

# =============================================================================
# ADMIN MANAGEMENT
# =============================================================================

create_admin_user() {
    local username="$1"
    local password="$2"
    local role="${3:-operator}"

    require_root || return 1

    validate_username "${username}" || return 1
    validate_password "${password}" || return 1

    if [[ -f "${ADMIN_DB_DIR}/${username}.conf" ]]; then
        print_error "Admin user '${username}' already exists"
        return 1
    fi

    local password_hash
    password_hash="$(hash_password "${password}")"

    cat > "${ADMIN_DB_DIR}/${username}.conf" << EOF
USERNAME=${username}
PASSWORD_HASH=${password_hash}
ROLE=${role}
CREATED=$(get_timestamp)
LAST_LOGIN=never
LOGIN_COUNT=0
ENABLED=yes
REQUIRE_CHANGE=no
EOF
    chmod 600 "${ADMIN_DB_DIR}/${username}.conf"

    print_success "Admin user '${username}' created with role: ${role}"
    log_audit "admin_create" "username=${username},role=${role}"
}

delete_admin_user() {
    local username="$1"

    require_root || return 1

    if [[ "${username}" == "admin" ]]; then
        print_error "Cannot delete the primary admin account"
        return 1
    fi

    if [[ ! -f "${ADMIN_DB_DIR}/${username}.conf" ]]; then
        print_error "Admin user '${username}' not found"
        return 1
    fi

    confirm "Delete admin user '${username}'?" "no" || return 0
    rm -f "${ADMIN_DB_DIR}/${username}.conf"
    print_success "Admin user '${username}' deleted"
    log_audit "admin_delete" "username=${username}"
}

change_admin_password() {
    local username="${1:-${CURRENT_USER:-admin}}"

    local admin_file="${ADMIN_DB_DIR}/${username}.conf"
    if [[ ! -f "${admin_file}" ]]; then
        print_error "Admin user '${username}' not found"
        return 1
    fi

    local new_pass
    while true; do
        read_password "New password" new_pass
        local confirm_pass
        read_password "Confirm new password" confirm_pass
        if [[ "${new_pass}" == "${confirm_pass}" ]]; then
            validate_password "${new_pass}" && break
        else
            print_error "Passwords do not match"
        fi
    done

    local new_hash
    new_hash="$(hash_password "${new_pass}")"
    config_set "${admin_file}" "PASSWORD_HASH" "${new_hash}"
    config_set "${admin_file}" "REQUIRE_CHANGE" "no"

    print_success "Password changed for ${username}"
    log_audit "admin_password_change" "username=${username}"
}

list_admin_users() {
    clear_screen
    print_header "Admin Users"

    if [[ ! -d "${ADMIN_DB_DIR}" ]]; then
        print_info "No admin users found"
        return
    fi

    print_table_header "Username" "Role" "Status" "Last Login" "Login Count"

    for admin_file in "${ADMIN_DB_DIR}"/*.conf; do
        [[ -f "${admin_file}" ]] || continue
        local username
        username="$(config_get "${admin_file}" "USERNAME")"
        local role
        role="$(config_get "${admin_file}" "ROLE" "admin")"
        local enabled
        enabled="$(config_get "${admin_file}" "ENABLED" "yes")"
        local last_login
        last_login="$(config_get "${admin_file}" "LAST_LOGIN" "never")"
        local login_count
        login_count="$(config_get "${admin_file}" "LOGIN_COUNT" "0")"

        local role_color="${C_INFO}"
        [[ "${role}" == "admin" ]] && role_color="${C_ERROR}"
        [[ "${role}" == "viewer" ]] && role_color="${C_DIM}"

        printf "  ${C_BOLD}%-18s${C_RESET} ${role_color}%-12s${C_RESET} %-10s %-22s %s\n" \
            "${username}" "${role}" \
            "$([ "${enabled}" == "yes" ] && echo "active" || echo "disabled")" \
            "${last_login}" "${login_count}"
    done
}

# =============================================================================
# ROLE-BASED ACCESS CONTROL
# =============================================================================

# Check if current user has permission for an action
has_permission() {
    local required_role="${1:-admin}"
    local current="${CURRENT_ROLE:-admin}"

    case "${required_role}" in
        admin)
            [[ "${current}" == "admin" ]]
            ;;
        operator)
            [[ "${current}" == "admin" || "${current}" == "operator" ]]
            ;;
        viewer)
            [[ "${current}" == "admin" || "${current}" == "operator" || \
               "${current}" == "viewer" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# Require a specific role or exit
require_role() {
    local role="${1:-admin}"
    if ! has_permission "${role}"; then
        print_error "Insufficient permissions. Required role: ${role}"
        log_audit "permission_denied" "user=${CURRENT_USER},required=${role},has=${CURRENT_ROLE}"
        return 1
    fi
    return 0
}

# =============================================================================
# FIREWALL MANAGEMENT
# =============================================================================

init_firewall() {
    require_root || return 1

    if [[ "${ENABLE_FIREWALL:-yes}" != "yes" ]]; then
        print_info "Firewall management is disabled"
        return 0
    fi

    local backend="${FIREWALL_BACKEND:-iptables}"

    print_info "Initializing firewall (${backend})..."

    case "${backend}" in
        iptables)
            _init_iptables
            ;;
        ufw)
            _init_ufw
            ;;
        firewalld)
            _init_firewalld
            ;;
        *)
            print_error "Unknown firewall backend: ${backend}"
            return 1
            ;;
    esac

    log_audit "firewall_init" "backend=${backend}"
}

_init_iptables() {
    if ! command_exists iptables; then
        print_warning "iptables not found"
        return 1
    fi

    # Load security config
    local security_conf="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/config/security.conf"
    # shellcheck source=/dev/null
    [[ -f "${security_conf}" ]] && . "${security_conf}"

    print_info "Setting up iptables rules..."

    # Allow established and related connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null

    # Allow configured ports
    local ports=(
        "${SSH_PORT:-22}/tcp:SSH"
        "${STUNNEL_SSL_PORT:-443}/tcp:Stunnel"
        "80/tcp:HTTP"
    )

    for port_entry in "${ports[@]}"; do
        local port="${port_entry%%/*}"
        local proto="${port_entry#*/}"
        proto="${proto%%:*}"
        local label="${port_entry##*:}"

        iptables -A INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null
        print_info "  Allowed: ${label} (${port}/${proto})"
    done

    # Rate limit SSH
    local ssh_port="${SSH_PORT:-22}"
    iptables -A INPUT -p tcp --dport "${ssh_port}" \
        -m state --state NEW -m recent --set --name SSH 2>/dev/null
    iptables -A INPUT -p tcp --dport "${ssh_port}" \
        -m state --state NEW -m recent --update \
        --seconds 60 --hitcount "${SSH_RATE_LIMIT:-10}" \
        --name SSH -j DROP 2>/dev/null

    print_success "iptables rules applied"
}

_init_ufw() {
    if ! command_exists ufw; then
        print_warning "ufw not found"
        return 1
    fi

    ufw --force reset 2>/dev/null
    ufw default deny incoming 2>/dev/null
    ufw default allow outgoing 2>/dev/null
    ufw allow "${SSH_PORT:-22}/tcp" 2>/dev/null
    ufw allow "${STUNNEL_SSL_PORT:-443}/tcp" 2>/dev/null
    ufw allow "80/tcp" 2>/dev/null
    ufw --force enable 2>/dev/null

    print_success "UFW rules applied"
}

_init_firewalld() {
    if ! command_exists firewall-cmd; then
        print_warning "firewalld not found"
        return 1
    fi

    firewall-cmd --permanent --add-port="${SSH_PORT:-22}/tcp" 2>/dev/null
    firewall-cmd --permanent --add-port="${STUNNEL_SSL_PORT:-443}/tcp" 2>/dev/null
    firewall-cmd --permanent --add-service=http 2>/dev/null
    firewall-cmd --reload 2>/dev/null

    print_success "firewalld rules applied"
}

show_firewall_rules() {
    clear_screen
    print_header "Firewall Rules"

    local backend="${FIREWALL_BACKEND:-iptables}"
    echo -e "  Backend: ${C_BOLD}${backend}${C_RESET}\n"

    case "${backend}" in
        iptables)
            if command_exists iptables; then
                echo -e "${C_BOLD}INPUT Chain:${C_RESET}"
                iptables -L INPUT -n --line-numbers 2>/dev/null || \
                    print_info "Unable to read iptables rules (requires root)"
            fi
            ;;
        ufw)
            command_exists ufw && ufw status numbered 2>/dev/null || \
                print_info "Unable to read UFW rules (requires root)"
            ;;
        firewalld)
            command_exists firewall-cmd && \
                firewall-cmd --list-all 2>/dev/null || \
                print_info "Unable to read firewalld rules (requires root)"
            ;;
    esac
}

add_firewall_rule() {
    local port="$1"
    local proto="${2:-tcp}"
    local action="${3:-ACCEPT}"

    require_root || return 1

    validate_port "${port}" || {
        print_error "Invalid port: ${port}"
        return 1
    }

    case "${FIREWALL_BACKEND:-iptables}" in
        iptables)
            iptables -A INPUT -p "${proto}" --dport "${port}" -j "${action}" 2>/dev/null
            ;;
        ufw)
            if [[ "${action}" == "ACCEPT" ]]; then
                ufw allow "${port}/${proto}" 2>/dev/null
            else
                ufw deny "${port}/${proto}" 2>/dev/null
            fi
            ;;
        firewalld)
            if [[ "${action}" == "ACCEPT" ]]; then
                firewall-cmd --permanent --add-port="${port}/${proto}" 2>/dev/null
                firewall-cmd --reload 2>/dev/null
            fi
            ;;
    esac

    print_success "Firewall rule added: ${action} ${port}/${proto}"
    log_audit "firewall_rule_add" "port=${port},proto=${proto},action=${action}"
}

remove_firewall_rule() {
    local port="$1"
    local proto="${2:-tcp}"

    require_root || return 1

    case "${FIREWALL_BACKEND:-iptables}" in
        iptables)
            iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p "${proto}" --dport "${port}" -j DROP 2>/dev/null || true
            ;;
        ufw)
            ufw delete allow "${port}/${proto}" 2>/dev/null || true
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/${proto}" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null
            ;;
    esac

    print_success "Firewall rule removed: ${port}/${proto}"
    log_audit "firewall_rule_remove" "port=${port},proto=${proto}"
}

# =============================================================================
# IP WHITELIST/BLACKLIST
# =============================================================================

add_to_whitelist() {
    local ip="$1"

    if ! validate_ip "${ip}" && ! validate_cidr "${ip}"; then
        print_error "Invalid IP/CIDR: ${ip}"
        return 1
    fi

    require_root || return 1

    # Add to whitelist file
    echo "${ip}" >> "${IP_WHITELIST_FILE:-/etc/sshvpnpanel/ip_whitelist.conf}"

    # Add iptables rule (insert at top to take priority)
    iptables -I INPUT -s "${ip}" -j ACCEPT 2>/dev/null || true

    print_success "Added ${ip} to whitelist"
    log_audit "ip_whitelist_add" "ip=${ip}"
}

remove_from_whitelist() {
    local ip="$1"

    require_root || return 1

    local whitelist="${IP_WHITELIST_FILE:-/etc/sshvpnpanel/ip_whitelist.conf}"
    if [[ -f "${whitelist}" ]]; then
        sed -i "/^${ip//./\\.}$/d" "${whitelist}" 2>/dev/null
    fi

    iptables -D INPUT -s "${ip}" -j ACCEPT 2>/dev/null || true
    print_success "Removed ${ip} from whitelist"
    log_audit "ip_whitelist_remove" "ip=${ip}"
}

add_to_blacklist() {
    local ip="$1"
    local reason="${2:-manual}"

    if ! validate_ip "${ip}" && ! validate_cidr "${ip}"; then
        print_error "Invalid IP/CIDR: ${ip}"
        return 1
    fi

    require_root || return 1

    # Add to blacklist file
    echo "${ip}  # ${reason} $(date '+%Y-%m-%d')" \
        >> "${IP_BLACKLIST_FILE:-/etc/sshvpnpanel/ip_blacklist.conf}"

    # Block via iptables
    iptables -I INPUT -s "${ip}" -j DROP 2>/dev/null || true

    print_success "Blocked ${ip} (reason: ${reason})"
    log_audit "ip_blacklist_add" "ip=${ip},reason=${reason}"
}

remove_from_blacklist() {
    local ip="$1"

    require_root || return 1

    local blacklist="${IP_BLACKLIST_FILE:-/etc/sshvpnpanel/ip_blacklist.conf}"
    if [[ -f "${blacklist}" ]]; then
        sed -i "/^${ip//./\\.}/d" "${blacklist}" 2>/dev/null
    fi

    iptables -D INPUT -s "${ip}" -j DROP 2>/dev/null || true
    print_success "Removed ${ip} from blacklist"
    log_audit "ip_blacklist_remove" "ip=${ip}"
}

show_ip_lists() {
    clear_screen
    print_header "IP Whitelist / Blacklist"

    echo -e "\n${C_BOLD}Whitelist:${C_RESET}"
    print_separator 40
    local whitelist="${IP_WHITELIST_FILE:-/etc/sshvpnpanel/ip_whitelist.conf}"
    if [[ -f "${whitelist}" ]] && [[ -s "${whitelist}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == "#"* ]] && continue
            echo -e "  ${C_SUCCESS}✓${C_RESET} ${line}"
        done < "${whitelist}"
    else
        echo "  (empty)"
    fi

    echo -e "\n${C_BOLD}Blacklist:${C_RESET}"
    print_separator 40
    local blacklist="${IP_BLACKLIST_FILE:-/etc/sshvpnpanel/ip_blacklist.conf}"
    if [[ -f "${blacklist}" ]] && [[ -s "${blacklist}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == "#"* ]] && continue
            echo -e "  ${C_ERROR}✗${C_RESET} ${line}"
        done < "${blacklist}"
    else
        echo "  (empty)"
    fi
}

# =============================================================================
# FAIL2BAN INTEGRATION
# =============================================================================

setup_fail2ban() {
    require_root || return 1

    if ! command_exists fail2ban-server; then
        print_warning "fail2ban not found. Installing..."
        install_package fail2ban || {
            print_error "Failed to install fail2ban"
            return 1
        }
    fi

    print_info "Configuring fail2ban jails..."

    local jail_config="/etc/fail2ban/jail.d/sshvpnpanel.conf"
    mkdir -p "$(dirname "${jail_config}")" 2>/dev/null

    cat > "${jail_config}" << EOF
; SSH VPN Panel - fail2ban configuration
; Generated: $(get_timestamp)

[sshd]
enabled  = true
port     = ${SSH_PORT:-22}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = ${F2B_SSH_MAX_RETRY:-5}
findtime = ${F2B_SSH_FINDTIME:-600}
bantime  = ${F2B_SSH_BANTIME:-3600}

[stunnel]
enabled  = true
port     = ${STUNNEL_SSL_PORT:-443}
filter   = stunnel
logpath  = ${STUNNEL_LOG_FILE:-/var/log/stunnel4/stunnel4.log}
maxretry = ${F2B_STUNNEL_MAX_RETRY:-10}
findtime = ${F2B_STUNNEL_FINDTIME:-600}
bantime  = ${F2B_STUNNEL_BANTIME:-3600}
EOF

    service_restart fail2ban 2>/dev/null || service_start fail2ban 2>/dev/null
    print_success "fail2ban configured"
    log_audit "fail2ban_setup" ""
}

show_fail2ban_status() {
    clear_screen
    print_header "Fail2ban Status"

    if ! command_exists fail2ban-client; then
        print_info "fail2ban is not installed"
        return
    fi

    local status
    status="$(fail2ban-client status 2>/dev/null)"
    if [[ -n "${status}" ]]; then
        echo -e "\n${C_BOLD}Jails:${C_RESET}"
        echo "${status}"

        echo -e "\n${C_BOLD}SSH Jail Detail:${C_RESET}"
        fail2ban-client status sshd 2>/dev/null || print_info "SSH jail not active"
    else
        print_info "fail2ban is not running"
    fi
}

# =============================================================================
# LOCKED OUT IPs
# =============================================================================

show_locked_out() {
    clear_screen
    print_header "Locked Out IPs"

    if [[ ! -f "${LOCKOUT_FILE}" ]] || [[ ! -s "${LOCKOUT_FILE}" ]]; then
        print_info "No locked out IPs"
        return
    fi

    local now
    now="$(date +%s)"
    local lockout_duration="${LOCKOUT_DURATION:-30}"

    print_table_header "IP/Identifier" "Locked At" "Unlocks At" "Minutes Left"

    while IFS=: read -r identifier ts; do
        [[ -z "${identifier}" ]] && continue
        local unlock_time=$(( ts + lockout_duration * 60 ))
        local minutes_left=$(( (unlock_time - now) / 60 ))

        if [[ "${now}" -lt "${unlock_time}" ]]; then
            local locked_at
            locked_at="$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${ts}")"
            local unlocks_at
            unlocks_at="$(date -d "@${unlock_time}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"

            printf "  %-20s %-22s %-22s %s min\n" \
                "${identifier}" "${locked_at}" "${unlocks_at}" "${minutes_left}"
        fi
    done < "${LOCKOUT_FILE}"
}

unlock_ip() {
    local ip="$1"

    if [[ -f "${LOCKOUT_FILE}" ]]; then
        sed -i "/^${ip}/d" "${LOCKOUT_FILE}" 2>/dev/null
    fi

    # Also clear failed logins for this IP
    if [[ -f "${FAILED_LOGINS_FILE}" ]]; then
        sed -i "/^${ip}/d" "${FAILED_LOGINS_FILE}" 2>/dev/null
    fi

    print_success "Unlocked: ${ip}"
    log_audit "ip_unlock" "ip=${ip}"
}

# =============================================================================
# SECURITY OVERVIEW
# =============================================================================

show_security_status() {
    clear_screen
    print_header "Security Status"

    echo -e "\n${C_BOLD}Authentication${C_RESET}"
    print_separator 40
    printf "  %-30s %s\n" "Max Login Attempts:" "${MAX_LOGIN_ATTEMPTS:-5}"
    printf "  %-30s %s min\n" "Lockout Duration:" "${LOCKOUT_DURATION:-30}"

    local lockout_count=0
    if [[ -f "${LOCKOUT_FILE}" ]]; then
        local now
        now="$(date +%s)"
        while IFS=: read -r identifier ts; do
            local unlock_time=$(( ts + LOCKOUT_DURATION * 60 ))
            [[ "${now}" -lt "${unlock_time}" ]] && (( lockout_count++ ))
        done < "${LOCKOUT_FILE}" 2>/dev/null
    fi

    local lockout_color="${C_SUCCESS}"
    [[ "${lockout_count}" -gt 0 ]] && lockout_color="${C_WARNING}"
    printf "  %-30s ${lockout_color}%s${C_RESET}\n" "Currently Locked Out:" "${lockout_count}"

    echo -e "\n${C_BOLD}Firewall${C_RESET}"
    print_separator 40
    printf "  %-30s %s\n" "Enabled:" "${ENABLE_FIREWALL:-yes}"
    printf "  %-30s %s\n" "Backend:" "${FIREWALL_BACKEND:-iptables}"

    echo -e "\n${C_BOLD}IP Lists${C_RESET}"
    print_separator 40
    local whitelist_count=0
    local blacklist_count=0

    [[ -f "${IP_WHITELIST_FILE:-/etc/sshvpnpanel/ip_whitelist.conf}" ]] && \
        whitelist_count="$(grep -c '^[^#]' \
            "${IP_WHITELIST_FILE:-/etc/sshvpnpanel/ip_whitelist.conf}" 2>/dev/null || echo 0)"

    [[ -f "${IP_BLACKLIST_FILE:-/etc/sshvpnpanel/ip_blacklist.conf}" ]] && \
        blacklist_count="$(grep -c '^[^#]' \
            "${IP_BLACKLIST_FILE:-/etc/sshvpnpanel/ip_blacklist.conf}" 2>/dev/null || echo 0)"

    printf "  %-30s %s\n" "Whitelisted IPs:" "${whitelist_count}"
    printf "  %-30s %s\n" "Blacklisted IPs:" "${blacklist_count}"

    echo -e "\n${C_BOLD}Fail2ban${C_RESET}"
    print_separator 40
    printf "  %-30s %s\n" "Installed:" "$(command_exists fail2ban-server && echo "yes" || echo "no")"
    printf "  %-30s %s\n" "Status:" "$(service_status fail2ban 2>/dev/null || echo "not installed")"

    echo -e "\n${C_BOLD}Recent Failed Logins${C_RESET}"
    print_separator 40
    if [[ -f "${FAILED_LOGINS_FILE}" ]]; then
        local recent_count
        recent_count="$(wc -l < "${FAILED_LOGINS_FILE}" 2>/dev/null || echo "0")"
        printf "  %-30s %s\n" "Total Failed Logins:" "${recent_count}"
        echo "  Last 5:"
        tail -5 "${FAILED_LOGINS_FILE}" | while IFS=: read -r ip ts; do
            local ts_human
            ts_human="$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${ts}")"
            echo -e "    ${C_WARNING}${ip}${C_RESET} at ${ts_human}"
        done
    fi
}

# =============================================================================
# SECURITY MENU
# =============================================================================

security_menu() {
    while true; do
        clear_screen
        print_header "Security Management"

        echo -e "${C_BOLD}Admin Users:${C_RESET}"
        echo "  1. List Admin Users"
        echo "  2. Create Admin User"
        echo "  3. Delete Admin User"
        echo "  4. Change Admin Password"
        echo
        echo -e "${C_BOLD}Firewall:${C_RESET}"
        echo "  5. Initialize Firewall"
        echo "  6. Show Firewall Rules"
        echo "  7. Add Firewall Rule"
        echo "  8. Remove Firewall Rule"
        echo
        echo -e "${C_BOLD}IP Management:${C_RESET}"
        echo "  9. IP Whitelist/Blacklist"
        echo " 10. Add to Whitelist"
        echo " 11. Add to Blacklist"
        echo " 12. Remove from Lists"
        echo
        echo -e "${C_BOLD}Monitoring:${C_RESET}"
        echo " 13. Security Status Overview"
        echo " 14. Show Locked Out IPs"
        echo " 15. Unlock IP"
        echo " 16. Setup Fail2ban"
        echo " 17. Fail2ban Status"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 17)"

        case "${choice}" in
            1) list_admin_users; read -rp $'\nPress Enter to continue...' ;;
            2) _menu_create_admin ;;
            3) _menu_delete_admin ;;
            4)
                local uname
                read_input "Username (empty for current user)" \
                    "${CURRENT_USER:-admin}" uname
                uname="${uname:-${CURRENT_USER:-admin}}"
                change_admin_password "${uname}"
                read -rp $'\nPress Enter to continue...'
                ;;
            5) init_firewall; read -rp $'\nPress Enter to continue...' ;;
            6) show_firewall_rules; read -rp $'\nPress Enter to continue...' ;;
            7) _menu_add_firewall_rule ;;
            8) _menu_remove_firewall_rule ;;
            9) show_ip_lists; read -rp $'\nPress Enter to continue...' ;;
            10) _menu_add_whitelist ;;
            11) _menu_add_blacklist ;;
            12) _menu_remove_from_lists ;;
            13) show_security_status; read -rp $'\nPress Enter to continue...' ;;
            14) show_locked_out; read -rp $'\nPress Enter to continue...' ;;
            15)
                local ip
                read_input "IP to unlock" "" ip
                [[ -n "${ip}" ]] && unlock_ip "${ip}"
                read -rp $'\nPress Enter to continue...'
                ;;
            16) setup_fail2ban; read -rp $'\nPress Enter to continue...' ;;
            17) show_fail2ban_status; read -rp $'\nPress Enter to continue...' ;;
            0) return 0 ;;
        esac
    done
}

_menu_create_admin() {
    clear_screen
    print_header "Create Admin User"

    local username
    while true; do
        read_input "Username" "" username
        [[ -z "${username}" ]] && return
        validate_username "${username}" && break
    done

    local password
    while true; do
        read_password "Password" password
        local confirm_pass
        read_password "Confirm Password" confirm_pass
        [[ "${password}" == "${confirm_pass}" ]] && \
            validate_password "${password}" && break
        print_error "Passwords do not match or invalid"
    done

    echo "Roles: 1.admin  2.operator  3.viewer"
    local role_choice
    role_choice="$(read_int "Select role" 1 3 "2")"
    local roles=("admin" "operator" "viewer")
    local role="${roles[$((role_choice-1))]}"

    create_admin_user "${username}" "${password}" "${role}"
    read -rp $'\nPress Enter to continue...'
}

_menu_delete_admin() {
    list_admin_users
    echo
    local username
    read_input "Username to delete (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return
    delete_admin_user "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_add_firewall_rule() {
    local port proto action
    read_input "Port" "" port
    [[ -z "${port}" ]] && return
    read_input "Protocol" "tcp" proto
    proto="${proto:-tcp}"
    echo "Action: 1.ACCEPT  2.DROP  3.REJECT"
    local action_choice
    action_choice="$(read_int "Select action" 1 3 "1")"
    local actions=("ACCEPT" "DROP" "REJECT")
    action="${actions[$((action_choice-1))]}"
    add_firewall_rule "${port}" "${proto}" "${action}"
    read -rp $'\nPress Enter to continue...'
}

_menu_remove_firewall_rule() {
    local port proto
    read_input "Port to remove rule for" "" port
    [[ -z "${port}" ]] && return
    read_input "Protocol" "tcp" proto
    proto="${proto:-tcp}"
    remove_firewall_rule "${port}" "${proto}"
    read -rp $'\nPress Enter to continue...'
}

_menu_add_whitelist() {
    local ip
    read_input "IP address to whitelist" "" ip
    [[ -z "${ip}" ]] && return
    add_to_whitelist "${ip}"
    read -rp $'\nPress Enter to continue...'
}

_menu_add_blacklist() {
    local ip reason
    read_input "IP address to blacklist" "" ip
    [[ -z "${ip}" ]] && return
    read_input "Reason" "manual" reason
    add_to_blacklist "${ip}" "${reason:-manual}"
    read -rp $'\nPress Enter to continue...'
}

_menu_remove_from_lists() {
    show_ip_lists
    echo
    echo "  1. Remove from whitelist"
    echo "  2. Remove from blacklist"
    local choice
    choice="$(read_int "Select" 1 2)"
    local ip
    read_input "IP address" "" ip
    [[ -z "${ip}" ]] && return
    if [[ "${choice}" -eq 1 ]]; then
        remove_from_whitelist "${ip}"
    else
        remove_from_blacklist "${ip}"
    fi
    read -rp $'\nPress Enter to continue...'
}
