#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - Stunnel Configuration Module
# Manages per-user Stunnel SSL/TLS tunnel configurations
################################################################################

[[ -n "${_STUNNEL_CONFIG_LOADED:-}" ]] && return 0
_STUNNEL_CONFIG_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

STUNNEL_CONFIG_DIR="${STUNNEL_CONFIG_DIR:-/etc/stunnel}"
STUNNEL_CERT_DIR="${STUNNEL_CERT_DIR:-/etc/stunnel/certs}"
STUNNEL_SERVICE="${STUNNEL_SERVICE:-stunnel4}"
STUNNEL_PORT_RANGE_START="${STUNNEL_PORT_RANGE_START:-10443}"
STUNNEL_PORT_RANGE_END="${STUNNEL_PORT_RANGE_END:-20443}"
STUNNEL_DEFAULT_PORT="${STUNNEL_DEFAULT_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Stunnel service helpers
# ---------------------------------------------------------------------------

stunnel_is_installed() {
    command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1
}

stunnel_service_name() {
    if systemctl list-units --type=service 2>/dev/null | grep -q "stunnel4"; then
        echo "stunnel4"
    elif systemctl list-units --type=service 2>/dev/null | grep -q "stunnel"; then
        echo "stunnel"
    else
        echo "$STUNNEL_SERVICE"
    fi
}

stunnel_reload() {
    local svc
    svc="$(stunnel_service_name)"
    log_info "Reloading Stunnel service (${svc})..."
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || {
        log_warn "Could not reload/restart stunnel; configuration will take effect on next restart."
    }
}

# ---------------------------------------------------------------------------
# Certificate management for Stunnel
# ---------------------------------------------------------------------------

# Generate a self-signed certificate for a user / domain
# Usage: stunnel_gen_cert USERNAME DOMAIN [days]
stunnel_gen_cert() {
    local username="$1"
    local domain="${2:-${SNI_DEFAULT_DOMAIN:-vpn.example.com}}"
    local days="${3:-${TLS_DEFAULT_DAYS:-365}}"
    local cert_dir="${STUNNEL_CERT_DIR}/${username}"
    local cert_file="${cert_dir}/${username}.pem"
    local key_file="${cert_dir}/${username}.key"

    check_command "openssl" || return 1
    ensure_dir "$cert_dir" 700 root

    log_info "Generating TLS certificate for user '${username}' (domain: ${domain})..."

    openssl req -x509 -newkey rsa:4096 -keyout "$key_file" -out "$cert_file" \
        -days "$days" -nodes -subj "/CN=${domain}/O=SSH VPN Panel/OU=${username}" \
        -addext "subjectAltName=DNS:${domain}" \
        2>/dev/null || {
        log_error "Failed to generate TLS certificate for ${username}"
        return 1
    }

    # Combine cert+key into a PEM for stunnel
    local combined="${cert_dir}/${username}-combined.pem"
    cat "$cert_file" "$key_file" > "$combined"
    chmod 600 "$cert_file" "$key_file" "$combined"

    log_audit "STUNNEL_CERT_CREATED" "$username" "domain=${domain} days=${days} cert=${cert_file}"
    print_success "TLS certificate created: ${cert_file}"
    return 0
}

# Remove certificates for a user
stunnel_remove_cert() {
    local username="$1"
    local cert_dir="${STUNNEL_CERT_DIR}/${username}"
    if [[ -d "$cert_dir" ]]; then
        rm -rf "$cert_dir"
        log_info "Removed TLS certificates for user: ${username}"
        log_audit "STUNNEL_CERT_REMOVED" "$username"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Per-user Stunnel configuration
# ---------------------------------------------------------------------------

# Create a stunnel tunnel configuration for a user
# Usage: stunnel_add_user USERNAME [port] [domain] [sni_enabled]
stunnel_add_user() {
    local username="$1"
    local port="${2:-}"
    local domain="${3:-${SNI_DEFAULT_DOMAIN:-vpn.example.com}}"
    local sni_enabled="${4:-true}"
    local config_file="${STUNNEL_CONFIG_DIR}/users/${username}.conf"

    check_root || return 1

    ensure_dir "${STUNNEL_CONFIG_DIR}/users" 750 root

    # Pick a free port if not specified
    if [[ -z "$port" ]]; then
        port="$(get_free_port "$STUNNEL_PORT_RANGE_START" "$STUNNEL_PORT_RANGE_END")" || return 1
    fi

    validate_port "$port" || return 1

    # Generate TLS certificate
    stunnel_gen_cert "$username" "$domain" || return 1

    local combined_cert="${STUNNEL_CERT_DIR}/${username}/${username}-combined.pem"

    log_info "Creating Stunnel configuration for user '${username}' on port ${port}..."

    cat > "$config_file" << EOF
# SSH VPN Panel - Stunnel config for user: ${username}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

[ssh-${username}]
accept  = ${port}
connect = 127.0.0.1:${SSH_PORT}
cert    = ${combined_cert}
verify  = 0
EOF

    if [[ "$sni_enabled" == "true" ]]; then
        echo "sni     = ${domain}:${port}" >> "$config_file"
    fi

    # Ensure the global stunnel config includes the users directory
    local main_conf="${STUNNEL_CONFIG_DIR}/stunnel.conf"
    if [[ -f "$main_conf" ]] && ! grep -q "include ${STUNNEL_CONFIG_DIR}/users/" "$main_conf" 2>/dev/null; then
        echo -e "\ninclude = ${STUNNEL_CONFIG_DIR}/users/" >> "$main_conf"
        log_info "Added 'include' directive to ${main_conf}"
    fi

    # Store user's stunnel port in the panel data store
    local user_data_dir="${PANEL_DATA_DIR}/users/${username}"
    ensure_dir "$user_data_dir" 750 root
    echo "STUNNEL_PORT=${port}" >> "${user_data_dir}/stunnel.conf"
    echo "STUNNEL_DOMAIN=${domain}" >> "${user_data_dir}/stunnel.conf"
    echo "STUNNEL_SNI=${sni_enabled}" >> "${user_data_dir}/stunnel.conf"

    stunnel_reload

    log_audit "STUNNEL_USER_ADDED" "$username" "port=${port} domain=${domain} sni=${sni_enabled}"
    print_success "Stunnel tunnel configured for '${username}' on port ${port}."
    return 0
}

# Remove stunnel configuration for a user
stunnel_remove_user() {
    local username="$1"
    local config_file="${STUNNEL_CONFIG_DIR}/users/${username}.conf"

    check_root || return 1

    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        log_info "Removed Stunnel config file: ${config_file}"
    else
        log_warn "No Stunnel config found for user: ${username}"
    fi

    stunnel_remove_cert "$username"

    # Remove panel data
    rm -f "${PANEL_DATA_DIR}/users/${username}/stunnel.conf" 2>/dev/null || true

    stunnel_reload

    log_audit "STUNNEL_USER_REMOVED" "$username"
    print_success "Stunnel tunnel removed for '${username}'."
    return 0
}

# Get stunnel port for a user
stunnel_get_user_port() {
    local username="$1"
    local user_data="${PANEL_DATA_DIR}/users/${username}/stunnel.conf"
    if [[ -f "$user_data" ]]; then
        grep 'STUNNEL_PORT=' "$user_data" | cut -d= -f2
    else
        echo ""
    fi
}

# Display stunnel info for a user
stunnel_user_info() {
    local username="$1"
    local user_data="${PANEL_DATA_DIR}/users/${username}/stunnel.conf"
    print_section "Stunnel Info: ${username}"
    if [[ -f "$user_data" ]]; then
        local port domain sni
        port="$(grep 'STUNNEL_PORT=' "$user_data" 2>/dev/null | cut -d= -f2)"
        domain="$(grep 'STUNNEL_DOMAIN=' "$user_data" 2>/dev/null | cut -d= -f2)"
        sni="$(grep 'STUNNEL_SNI=' "$user_data" 2>/dev/null | cut -d= -f2)"
        print_table_row "Port" "${port:-N/A}"
        print_table_row "Domain" "${domain:-N/A}"
        print_table_row "SNI Enabled" "${sni:-false}"
        print_table_row "Config File" "${STUNNEL_CONFIG_DIR}/users/${username}.conf"
        print_table_row "Cert File" "${STUNNEL_CERT_DIR}/${username}/${username}.pem"
    else
        print_warning "No Stunnel configuration found for user '${username}'."
    fi
}

# List all user stunnel configurations
stunnel_list_users() {
    local users_dir="${STUNNEL_CONFIG_DIR}/users"
    print_section "Stunnel User Configurations"
    printf "  %-20s %-8s %-35s %-10s\n" "USERNAME" "PORT" "DOMAIN" "SNI"
    printf "  %-20s %-8s %-35s %-10s\n" "--------" "----" "------" "---"

    if [[ ! -d "$users_dir" ]]; then
        print_info "No Stunnel user configurations found."
        return 0
    fi

    local found=0
    for conf in "${users_dir}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local username port domain sni
        username="$(basename "$conf" .conf)"
        local user_data="${PANEL_DATA_DIR}/users/${username}/stunnel.conf"
        port="$(grep 'STUNNEL_PORT=' "$user_data" 2>/dev/null | cut -d= -f2 || echo "?")"
        domain="$(grep 'STUNNEL_DOMAIN=' "$user_data" 2>/dev/null | cut -d= -f2 || echo "?")"
        sni="$(grep 'STUNNEL_SNI=' "$user_data" 2>/dev/null | cut -d= -f2 || echo "?")"
        printf "  %-20s %-8s %-35s %-10s\n" "$username" "$port" "$domain" "$sni"
        ((found++))
    done

    [[ "$found" -eq 0 ]] && print_info "No Stunnel user configurations found."
}
