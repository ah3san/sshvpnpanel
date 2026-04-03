#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - TLS/SNI Configuration Module
# =============================================================================
# Handles Server Name Indication (SNI), multi-domain certificates,
# automatic certificate renewal, TLS routing and forwarding.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# SNI CONFIGURATION
# =============================================================================

TLS_CERTS_DIR="${CERT_DIR:-/etc/sshvpnpanel/certs}"
SNI_ROUTES_FILE="${SNI_CONFIG:-/etc/sshvpnpanel/sni_routes.conf}"
SNI_DB_DIR="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/sni"
ACME_DIR="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/acme"
WEBROOT_DIR="/var/www/html/.well-known/acme-challenge"

# Initialize TLS/SNI management
init_tls_sni() {
    mkdir -p "${TLS_CERTS_DIR}" 2>/dev/null
    chmod 700 "${TLS_CERTS_DIR}" 2>/dev/null
    mkdir -p "${SNI_DB_DIR}" 2>/dev/null
    mkdir -p "${ACME_DIR}" 2>/dev/null
    touch "${SNI_ROUTES_FILE}" 2>/dev/null
}

# =============================================================================
# SNI ROUTE MANAGEMENT
# =============================================================================

add_sni_route() {
    local domain="$1"
    local backend="$2"
    local cert_file="${3:-}"
    local key_file="${4:-}"
    local tls_version="${5:-${DEFAULT_TLS_VERSION:-1.3}}"

    require_root || return 1

    # Validate domain
    validate_domain "${domain}" || {
        print_error "Invalid domain: ${domain}"
        return 1
    }

    # Validate backend (host:port)
    if [[ ! "${backend}" =~ ^.+:[0-9]+$ ]]; then
        print_error "Invalid backend. Format: host:port"
        return 1
    fi

    # Check for existing route
    if grep -q "^DOMAIN=${domain}$" "${SNI_ROUTES_FILE}" 2>/dev/null; then
        print_error "SNI route for '${domain}' already exists"
        return 1
    fi

    # Generate certificate if not provided
    if [[ -z "${cert_file}" ]] || [[ ! -f "${cert_file}" ]]; then
        cert_file="${TLS_CERTS_DIR}/${domain}.crt"
        key_file="${TLS_CERTS_DIR}/${domain}.key"

        if [[ ! -f "${cert_file}" ]]; then
            print_info "Generating certificate for ${domain}..."
            generate_tls_cert "${domain}" "${cert_file}" "${key_file}" || return 1
        fi
    fi

    # Add route to database
    local route_file="${SNI_DB_DIR}/${domain}.route"
    cat > "${route_file}" << EOF
DOMAIN=${domain}
BACKEND=${backend}
CERT=${cert_file}
KEY=${key_file}
TLS_VERSION=TLSv${tls_version}
ENABLED=yes
CREATED=$(get_timestamp)
EOF
    chmod 600 "${route_file}"

    # Append to routes config
    cat >> "${SNI_ROUTES_FILE}" << EOF

# Route: ${domain} -> ${backend}
DOMAIN=${domain}
BACKEND=${backend}
CERT=${cert_file}
KEY=${key_file}
TLS_VERSION=TLSv${tls_version}
ENABLED=yes
EOF

    print_success "SNI route added: ${domain} -> ${backend}"
    log_audit "sni_route_add" "domain=${domain},backend=${backend}"

    # Ask to regenerate stunnel config
    if confirm "Regenerate and reload Stunnel configuration?" "yes"; then
        generate_sni_stunnel_config && stunnel_reload 2>/dev/null || true
    fi
}

remove_sni_route() {
    local domain="$1"

    require_root || return 1

    if [[ ! -f "${SNI_DB_DIR}/${domain}.route" ]]; then
        print_error "SNI route for '${domain}' not found"
        return 1
    fi

    confirm "Remove SNI route for '${domain}'?" "no" || return 0

    rm -f "${SNI_DB_DIR}/${domain}.route"

    # Remove from routes file (remove domain block)
    if [[ -f "${SNI_ROUTES_FILE}" ]]; then
        local tmp="${SNI_ROUTES_FILE}.tmp.$$"
        awk -v domain="${domain}" '
            /^# Route: / && index($0, domain) > 0 { skip=1; next }
            /^$/ && skip { skip=0; next }
            skip { next }
            { print }
        ' "${SNI_ROUTES_FILE}" > "${tmp}"
        mv "${tmp}" "${SNI_ROUTES_FILE}"
    fi

    print_success "SNI route for '${domain}' removed"
    log_audit "sni_route_remove" "domain=${domain}"
}

list_sni_routes() {
    clear_screen
    print_header "SNI Routes"

    if [[ ! -d "${SNI_DB_DIR}" ]] || [[ -z "$(ls -A "${SNI_DB_DIR}" 2>/dev/null)" ]]; then
        print_info "No SNI routes configured"
        return
    fi

    print_table_header "Domain" "Backend" "TLS" "Cert Expiry" "Status"

    for route_file in "${SNI_DB_DIR}"/*.route; do
        [[ -f "${route_file}" ]] || continue

        local domain
        domain="$(config_get "${route_file}" "DOMAIN")"
        local backend
        backend="$(config_get "${route_file}" "BACKEND")"
        local tls
        tls="$(config_get "${route_file}" "TLS_VERSION" "TLSv1.3")"
        local cert
        cert="$(config_get "${route_file}" "CERT")"
        local enabled
        enabled="$(config_get "${route_file}" "ENABLED" "yes")"

        local cert_expiry="N/A"
        if [[ -f "${cert}" ]]; then
            local expiry_str
            expiry_str="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)"
            cert_expiry="$(date -d "${expiry_str}" '+%Y-%m-%d' 2>/dev/null || echo "${expiry_str}")"
        fi

        local status_color="${C_SUCCESS}"
        [[ "${enabled}" != "yes" ]] && status_color="${C_DIM}"

        printf "  ${C_BOLD}%-24s${C_RESET} %-20s %-10s %-14s ${status_color}%s${C_RESET}\n" \
            "${domain}" "${backend}" "${tls}" "${cert_expiry}" \
            "$([ "${enabled}" == "yes" ] && echo "active" || echo "disabled")"
    done
}

enable_sni_route() {
    local domain="$1"
    local route_file="${SNI_DB_DIR}/${domain}.route"

    [[ -f "${route_file}" ]] || { print_error "Route not found"; return 1; }
    config_set "${route_file}" "ENABLED" "yes"
    _update_routes_file_status "${domain}" "yes"
    print_success "SNI route '${domain}' enabled"
    log_audit "sni_route_enable" "domain=${domain}"
}

disable_sni_route() {
    local domain="$1"
    local route_file="${SNI_DB_DIR}/${domain}.route"

    [[ -f "${route_file}" ]] || { print_error "Route not found"; return 1; }
    config_set "${route_file}" "ENABLED" "no"
    _update_routes_file_status "${domain}" "no"
    print_success "SNI route '${domain}' disabled"
    log_audit "sni_route_disable" "domain=${domain}"
}

_update_routes_file_status() {
    local domain="$1"
    local status="$2"
    if [[ -f "${SNI_ROUTES_FILE}" ]]; then
        sed -i "/^DOMAIN=${domain}$/,/^ENABLED=/ s|^ENABLED=.*|ENABLED=${status}|" \
            "${SNI_ROUTES_FILE}" 2>/dev/null || true
    fi
}

# =============================================================================
# TLS CERTIFICATE MANAGEMENT
# =============================================================================

generate_tls_cert() {
    local domain="$1"
    local cert_file="${2:-${TLS_CERTS_DIR}/${domain}.crt}"
    local key_file="${3:-${TLS_CERTS_DIR}/${domain}.key}"
    local days="${4:-${DEFAULT_CERT_DAYS:-365}}"

    require_root || return 1

    if ! command_exists openssl; then
        print_error "openssl is required"
        return 1
    fi

    mkdir -p "${TLS_CERTS_DIR}" 2>/dev/null

    print_info "Generating TLS certificate for ${domain}..."

    # Create SAN extension config
    local san_config="${TMP_DIR:-/tmp/sshvpnpanel}/san_${domain}.cnf"
    cat > "${san_config}" << EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF

    # Generate private key
    openssl genrsa -out "${key_file}" 4096 2>/dev/null || {
        print_error "Failed to generate private key"
        rm -f "${san_config}"
        return 1
    }
    chmod 600 "${key_file}"

    # Generate self-signed certificate with SAN
    openssl req -x509 -new -key "${key_file}" \
        -out "${cert_file}" -days "${days}" -nodes \
        -subj "/CN=${domain}/O=SSH VPN Panel" \
        -extensions v3_req -config "${san_config}" 2>/dev/null || {
        print_error "Failed to generate certificate"
        rm -f "${san_config}" "${key_file}"
        return 1
    }
    chmod 644 "${cert_file}"
    rm -f "${san_config}"

    print_success "TLS certificate generated for ${domain}"
    print_info "  Certificate: ${cert_file}"
    print_info "  Private Key: ${key_file}"

    # Show expiry
    local expiry
    expiry="$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)"
    print_info "  Expires:     ${expiry}"

    log_audit "tls_cert_generate" "domain=${domain}"
    return 0
}

# Request Let's Encrypt certificate using certbot
request_letsencrypt_cert() {
    local domain="$1"
    local email="${2:-${ACME_EMAIL:-}}"

    require_root || return 1

    if ! command_exists certbot; then
        print_warning "certbot not found. Attempting to install..."
        install_package certbot || {
            print_error "Failed to install certbot"
            return 1
        }
    fi

    if [[ -z "${email}" ]]; then
        read_input "Email for Let's Encrypt notifications" "" email
        [[ -z "${email}" ]] && email="--register-unsafely-without-email"
        validate_email "${email}" 2>/dev/null && email="--email ${email}" || \
            email="--register-unsafely-without-email"
    else
        email="--email ${email}"
    fi

    print_info "Requesting Let's Encrypt certificate for ${domain}..."

    # Create webroot directory for challenge
    mkdir -p "${WEBROOT_DIR}" 2>/dev/null

    certbot certonly --webroot -w /var/www/html \
        ${email} \
        --agree-tos --non-interactive \
        -d "${domain}" 2>&1

    local exit_code=$?

    if [[ "${exit_code}" -eq 0 ]]; then
        local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
        local le_key="/etc/letsencrypt/live/${domain}/privkey.pem"

        if [[ -f "${le_cert}" ]]; then
            print_success "Let's Encrypt certificate obtained for ${domain}"
            print_info "  Certificate: ${le_cert}"
            print_info "  Private Key: ${le_key}"

            # Create symlinks in panel cert directory
            ln -sf "${le_cert}" "${TLS_CERTS_DIR}/${domain}.crt" 2>/dev/null
            ln -sf "${le_key}" "${TLS_CERTS_DIR}/${domain}.key" 2>/dev/null

            log_audit "letsencrypt_cert" "domain=${domain}"
            return 0
        fi
    fi

    print_error "Failed to obtain Let's Encrypt certificate"
    return 1
}

# Renew a specific domain's certificate
renew_domain_cert() {
    local domain="$1"

    require_root || return 1

    # Check if it's a Let's Encrypt cert
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        print_info "Renewing Let's Encrypt certificate for ${domain}..."
        certbot renew --cert-name "${domain}" --non-interactive 2>&1
        if [[ $? -eq 0 ]]; then
            print_success "Certificate renewed for ${domain}"
            # Reload stunnel
            if [[ "$(stunnel_service_status 2>/dev/null)" == "running" ]]; then
                stunnel_reload 2>/dev/null || true
            fi
            log_audit "cert_renew" "domain=${domain}"
            return 0
        fi
    fi

    # Try self-signed renewal
    local cert_file="${TLS_CERTS_DIR}/${domain}.crt"
    local key_file="${TLS_CERTS_DIR}/${domain}.key"

    if [[ -f "${cert_file}" ]]; then
        # Backup existing
        local bak_dir="${BACKUP_DIR:-/var/backups/sshvpnpanel}/certs"
        mkdir -p "${bak_dir}" 2>/dev/null
        cp "${cert_file}" "${bak_dir}/${domain}_$(date +%Y%m%d).crt.bak" 2>/dev/null

        generate_tls_cert "${domain}" "${cert_file}" "${key_file}" || return 1

        # Reload stunnel if running
        if [[ "$(stunnel_service_status 2>/dev/null)" == "running" ]]; then
            stunnel_reload 2>/dev/null || true
        fi
        return 0
    fi

    print_error "No certificate found for ${domain}"
    return 1
}

# Check all certificates for upcoming expiry and auto-renew
auto_renew_certificates() {
    local threshold="${CERT_RENEW_DAYS:-30}"
    print_info "Checking certificates for renewal (threshold: ${threshold} days)..."

    local renewed=0

    # Check SNI routes
    if [[ -d "${SNI_DB_DIR}" ]]; then
        for route_file in "${SNI_DB_DIR}"/*.route; do
            [[ -f "${route_file}" ]] || continue
            local domain
            domain="$(config_get "${route_file}" "DOMAIN")"
            local cert
            cert="$(config_get "${route_file}" "CERT")"

            if [[ -f "${cert}" ]]; then
                local expiry_str
                expiry_str="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)"
                local expiry_date
                expiry_date="$(date -d "${expiry_str}" '+%Y-%m-%d' 2>/dev/null || echo "")"
                local days_left
                days_left="$(days_until_expiry "${expiry_date}")"

                if [[ "${days_left}" =~ ^-?[0-9]+$ ]] && [[ "${days_left}" -lt "${threshold}" ]]; then
                    print_warning "Renewing expiring cert for ${domain} (${days_left} days left)..."
                    renew_domain_cert "${domain}" && (( renewed++ ))
                fi
            fi
        done
    fi

    print_success "Auto-renewal check complete. Renewed ${renewed} certificate(s)."
}

# =============================================================================
# SNI STUNNEL CONFIG GENERATION
# =============================================================================

generate_sni_stunnel_config() {
    require_root || return 1

    local routes=()
    if [[ -d "${SNI_DB_DIR}" ]]; then
        for route_file in "${SNI_DB_DIR}"/*.route; do
            [[ -f "${route_file}" ]] || continue
            local enabled
            enabled="$(config_get "${route_file}" "ENABLED" "yes")"
            [[ "${enabled}" == "yes" ]] && routes+=("${route_file}")
        done
    fi

    if [[ ${#routes[@]} -eq 0 ]]; then
        print_info "No active SNI routes to configure"
        return 0
    fi

    print_info "Generating SNI-based Stunnel configuration..."

    local sni_config_file="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/sni_stunnel.conf"
    local tmp_config="${sni_config_file}.tmp.$$"

    # Global settings
    cat > "${tmp_config}" << EOF
; SNI Stunnel Configuration - Generated by SSH VPN Panel
; Generated: $(get_timestamp)

setuid = stunnel4
setgid = stunnel4
pid = ${STUNNEL_PID_FILE:-/var/run/stunnel4/stunnel4.pid}
output = ${STUNNEL_LOG_FILE:-/var/log/stunnel4/stunnel4.log}
debug = 5

; SNI dispatcher
[sni-router]
accept = 0.0.0.0:${STUNNEL_SSL_PORT:-443}
protocol = sni

EOF

    # Add each SNI-routed service
    local i=0
    for route_file in "${routes[@]}"; do
        local domain
        domain="$(config_get "${route_file}" "DOMAIN")"
        local backend
        backend="$(config_get "${route_file}" "BACKEND")"
        local cert
        cert="$(config_get "${route_file}" "CERT")"
        local key
        key="$(config_get "${route_file}" "KEY")"
        local tls
        tls="$(config_get "${route_file}" "TLS_VERSION" "TLSv1.3")"
        local local_port=$(( 9000 + i ))

        cat >> "${tmp_config}" << EOF
; SNI service: ${domain}
[sni-${domain//[^a-zA-Z0-9]/-}]
accept  = 127.0.0.1:${local_port}
connect = ${backend}
cert    = ${cert}
key     = ${key}
sslVersion = ${tls}
sniNames = ${domain}
TIMEOUTclose = 0

EOF
        (( i++ ))
    done

    mv "${tmp_config}" "${sni_config_file}"
    chmod 600 "${sni_config_file}"

    print_success "SNI Stunnel config generated: ${sni_config_file}"
    return 0
}

# =============================================================================
# TLS VERSION SELECTION
# =============================================================================

configure_tls_version() {
    local target="${1:-global}"

    clear_screen
    print_header "TLS Version Configuration"
    print_info "Current default: TLSv${DEFAULT_TLS_VERSION:-1.3}"

    echo
    echo "  1. TLS 1.2 only (legacy compatibility)"
    echo "  2. TLS 1.3 only (most secure, recommended)"
    echo "  3. TLS 1.2 and 1.3 (best compatibility)"
    echo "  4. Back"
    echo

    local choice
    choice="$(read_int "Select TLS version" 1 4)"

    local version
    case "${choice}" in
        1) version="1.2" ;;
        2) version="1.3" ;;
        3) version="1.2,1.3" ;;
        4) return 0 ;;
    esac

    if [[ "${target}" == "global" ]]; then
        # Update global config
        local panel_conf="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/sshvpnpanel.conf"
        if [[ -f "${panel_conf}" ]]; then
            config_set "${panel_conf}" "DEFAULT_TLS_VERSION" "${version}"
            DEFAULT_TLS_VERSION="${version}"
        fi
        print_success "Default TLS version set to: ${version}"
    fi

    log_audit "tls_version_change" "target=${target},version=${version}"
}

# =============================================================================
# TLS/SNI STATUS OVERVIEW
# =============================================================================

show_tls_sni_status() {
    clear_screen
    print_header "TLS/SNI Status Overview"

    echo -e "\n${C_BOLD}Configuration${C_RESET}"
    print_separator 40
    printf "  %-28s %s\n" "Default TLS Version:" "TLSv${DEFAULT_TLS_VERSION:-1.3}"
    printf "  %-28s %s\n" "SNI Enabled:" "${ENABLE_SNI:-yes}"
    printf "  %-28s %s\n" "Cert Renewal Threshold:" "${CERT_RENEW_DAYS:-30} days"
    printf "  %-28s %s\n" "Cert Directory:" "${TLS_CERTS_DIR}"

    echo -e "\n${C_BOLD}Certificate Inventory${C_RESET}"
    print_separator 40
    local cert_count=0
    local expiring_count=0
    if [[ -d "${TLS_CERTS_DIR}" ]]; then
        while IFS= read -r -d '' cert_file; do
            (( cert_count++ ))
            local expiry_str
            expiry_str="$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)"
            local expiry_date
            expiry_date="$(date -d "${expiry_str}" '+%Y-%m-%d' 2>/dev/null || echo "")"
            if [[ -n "${expiry_date}" ]]; then
                local days_left
                days_left="$(days_until_expiry "${expiry_date}")"
                if [[ "${days_left}" =~ ^-?[0-9]+$ ]] && \
                   [[ "${days_left}" -lt "${CERT_RENEW_DAYS:-30}" ]]; then
                    (( expiring_count++ ))
                fi
            fi
        done < <(find "${TLS_CERTS_DIR}" -name "*.crt" -print0 2>/dev/null)
    fi
    printf "  %-28s %s\n" "Total Certificates:" "${cert_count}"
    local expiry_color="${C_SUCCESS}"
    [[ "${expiring_count}" -gt 0 ]] && expiry_color="${C_WARNING}"
    printf "  %-28s ${expiry_color}%s${C_RESET}\n" "Expiring Soon:" "${expiring_count}"

    echo -e "\n${C_BOLD}SNI Routes${C_RESET}"
    print_separator 40
    local route_count=0
    local active_routes=0
    if [[ -d "${SNI_DB_DIR}" ]]; then
        for route_file in "${SNI_DB_DIR}"/*.route; do
            [[ -f "${route_file}" ]] || continue
            (( route_count++ ))
            local enabled
            enabled="$(config_get "${route_file}" "ENABLED" "yes")"
            [[ "${enabled}" == "yes" ]] && (( active_routes++ ))
        done
    fi
    printf "  %-28s %s\n" "Total Routes:" "${route_count}"
    printf "  %-28s %s\n" "Active Routes:" "${active_routes}"
}

# =============================================================================
# TLS/SNI MENU
# =============================================================================

tls_sni_menu() {
    while true; do
        clear_screen
        print_header "TLS/SNI Configuration"

        echo -e "${C_BOLD}SNI Routes:${C_RESET}"
        echo "  1. Add SNI Route"
        echo "  2. Remove SNI Route"
        echo "  3. Enable/Disable Route"
        echo "  4. List SNI Routes"
        echo
        echo -e "${C_BOLD}Certificates:${C_RESET}"
        echo "  5. Generate TLS Certificate"
        echo "  6. Request Let's Encrypt Certificate"
        echo "  7. Renew Certificate"
        echo "  8. Auto-Renew Expiring Certificates"
        echo "  9. List Certificates"
        echo
        echo -e "${C_BOLD}Configuration:${C_RESET}"
        echo " 10. TLS Version Settings"
        echo " 11. Generate SNI Stunnel Config"
        echo " 12. TLS/SNI Status Overview"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 12)"

        case "${choice}" in
            1) _menu_add_sni_route ;;
            2) _menu_remove_sni_route ;;
            3) _menu_toggle_sni_route ;;
            4) list_sni_routes; read -rp $'\nPress Enter to continue...' ;;
            5) _menu_gen_tls_cert ;;
            6) _menu_request_letsencrypt ;;
            7) _menu_renew_domain_cert ;;
            8) auto_renew_certificates; read -rp $'\nPress Enter to continue...' ;;
            9) list_certificates 2>/dev/null || list_sni_routes; \
               read -rp $'\nPress Enter to continue...' ;;
            10) configure_tls_version "global"; \
                read -rp $'\nPress Enter to continue...' ;;
            11) generate_sni_stunnel_config; \
                read -rp $'\nPress Enter to continue...' ;;
            12) show_tls_sni_status; read -rp $'\nPress Enter to continue...' ;;
            0) return 0 ;;
        esac
    done
}

_menu_add_sni_route() {
    clear_screen
    print_header "Add SNI Route"

    local domain
    while true; do
        read_input "Domain name (e.g., ssh.example.com)" "" domain
        [[ -z "${domain}" ]] && return
        validate_domain "${domain}" && break
        print_error "Invalid domain name"
    done

    local backend
    read_input "Backend (host:port, e.g., 127.0.0.1:22)" "127.0.0.1:22" backend
    backend="${backend:-127.0.0.1:22}"

    echo "TLS versions: 1.TLS 1.2  2.TLS 1.3  3.Both"
    local tls_choice
    tls_choice="$(read_int "TLS version" 1 3 "2")"
    local tls_arr=("1.2" "1.3" "1.2,1.3")
    local tls="${tls_arr[$((tls_choice-1))]}"

    local cert_file
    read_input "Certificate file (empty to auto-generate)" "" cert_file

    echo
    add_sni_route "${domain}" "${backend}" "${cert_file}" "" "${tls}"
    read -rp $'\nPress Enter to continue...'
}

_menu_remove_sni_route() {
    list_sni_routes
    echo
    local domain
    read_input "Domain to remove (or 'cancel')" "" domain
    [[ "${domain}" == "cancel" || -z "${domain}" ]] && return
    remove_sni_route "${domain}"
    read -rp $'\nPress Enter to continue...'
}

_menu_toggle_sni_route() {
    list_sni_routes
    echo
    local domain
    read_input "Domain to toggle" "" domain
    [[ -z "${domain}" ]] && return

    local route_file="${SNI_DB_DIR}/${domain}.route"
    if [[ -f "${route_file}" ]]; then
        local enabled
        enabled="$(config_get "${route_file}" "ENABLED" "yes")"
        if [[ "${enabled}" == "yes" ]]; then
            disable_sni_route "${domain}"
        else
            enable_sni_route "${domain}"
        fi
    else
        print_error "Route not found for ${domain}"
    fi
    read -rp $'\nPress Enter to continue...'
}

_menu_gen_tls_cert() {
    clear_screen
    print_header "Generate TLS Certificate"

    local domain
    while true; do
        read_input "Domain name" "" domain
        [[ -z "${domain}" ]] && return
        validate_domain "${domain}" 2>/dev/null && break
        # Allow IPs too
        validate_ip "${domain}" 2>/dev/null && break
        # Allow simple hostnames
        break
    done

    local days
    days="$(read_int "Validity in days" 1 3650 "${DEFAULT_CERT_DAYS:-365}")"

    generate_tls_cert "${domain}" "" "" "${days}"
    read -rp $'\nPress Enter to continue...'
}

_menu_request_letsencrypt() {
    clear_screen
    print_header "Request Let's Encrypt Certificate"

    print_warning "Ensure your domain's DNS points to this server and port 80 is accessible."
    echo

    local domain
    while true; do
        read_input "Domain name" "" domain
        [[ -z "${domain}" ]] && return
        validate_domain "${domain}" && break
        print_error "Invalid domain name"
    done

    local email
    read_input "Email for notifications" "${ACME_EMAIL:-}" email

    request_letsencrypt_cert "${domain}" "${email}"
    read -rp $'\nPress Enter to continue...'
}

_menu_renew_domain_cert() {
    list_sni_routes
    echo
    local domain
    read_input "Domain to renew certificate for" "" domain
    [[ -z "${domain}" ]] && return
    renew_domain_cert "${domain}"
    read -rp $'\nPress Enter to continue...'
}
