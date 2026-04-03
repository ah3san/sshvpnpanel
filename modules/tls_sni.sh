#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - TLS/SNI Management Module
# Manages TLS certificates and SNI domain routing for users
################################################################################

[[ -n "${_TLS_SNI_LOADED:-}" ]] && return 0
_TLS_SNI_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

TLS_CERT_DIR="${TLS_CERT_DIR:-/etc/ssl/sshvpnpanel}"
TLS_CA_FILE="${TLS_CA_FILE:-${TLS_CERT_DIR}/ca.pem}"
TLS_CA_KEY="${TLS_CA_KEY:-${TLS_CERT_DIR}/ca.key}"
TLS_DEFAULT_DAYS="${TLS_DEFAULT_DAYS:-365}"
TLS_KEY_SIZE="${TLS_KEY_SIZE:-4096}"
SNI_CONFIG_DIR="${PANEL_DATA_DIR:-/var/lib/sshvpnpanel}/sni"
SNI_DEFAULT_DOMAIN="${SNI_DEFAULT_DOMAIN:-vpn.example.com}"

# ---------------------------------------------------------------------------
# CA management
# ---------------------------------------------------------------------------

# Initialize the internal CA (run once during install)
tls_init_ca() {
    check_root || return 1
    check_command "openssl" || return 1

    ensure_dir "$TLS_CERT_DIR" 700 root

    if [[ -f "$TLS_CA_FILE" ]]; then
        print_info "CA already exists at ${TLS_CA_FILE}"
        return 0
    fi

    log_info "Creating internal CA for SSH VPN Panel..."

    # Generate CA key
    openssl genrsa -out "$TLS_CA_KEY" "$TLS_KEY_SIZE" 2>/dev/null || {
        log_error "Failed to generate CA key"
        return 1
    }

    # Generate CA certificate
    openssl req -new -x509 -days 3650 \
        -key "$TLS_CA_KEY" \
        -out "$TLS_CA_FILE" \
        -subj "/CN=SSH VPN Panel CA/O=SSH VPN Panel/OU=CA" \
        2>/dev/null || {
        log_error "Failed to generate CA certificate"
        return 1
    }

    chmod 600 "$TLS_CA_KEY"
    chmod 644 "$TLS_CA_FILE"

    log_audit "TLS_CA_INITIALIZED" "SYSTEM" "ca=${TLS_CA_FILE}"
    print_success "Internal CA created: ${TLS_CA_FILE}"
    return 0
}

# ---------------------------------------------------------------------------
# User certificate management
# ---------------------------------------------------------------------------

# Issue a TLS certificate for a user signed by the internal CA
# Usage: tls_issue_cert USERNAME DOMAIN [days]
tls_issue_cert() {
    local username="$1"
    local domain="${2:-${SNI_DEFAULT_DOMAIN}}"
    local days="${3:-${TLS_DEFAULT_DAYS}}"
    local user_cert_dir="${TLS_CERT_DIR}/users/${username}"

    check_root || return 1
    check_command "openssl" || return 1
    validate_domain "$domain" || { log_warn "Domain validation failed for '${domain}'; proceeding anyway."; }

    ensure_dir "$user_cert_dir" 700 root

    local key_file="${user_cert_dir}/${username}.key"
    local csr_file="${user_cert_dir}/${username}.csr"
    local cert_file="${user_cert_dir}/${username}.crt"
    local ext_file="${user_cert_dir}/${username}.ext"

    log_info "Issuing TLS certificate for '${username}' (domain: ${domain}, days: ${days})..."

    # Generate private key
    openssl genrsa -out "$key_file" "$TLS_KEY_SIZE" 2>/dev/null || {
        log_error "Failed to generate key for ${username}"
        return 1
    }

    # Generate CSR
    openssl req -new -key "$key_file" -out "$csr_file" \
        -subj "/CN=${domain}/O=SSH VPN Panel/OU=${username}" \
        2>/dev/null || {
        log_error "Failed to generate CSR for ${username}"
        return 1
    }

    # Extension file for SAN
    cat > "$ext_file" << EOF
[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = ${username}.${domain}
EOF

    # If CA exists, sign with CA; otherwise self-sign
    if [[ -f "$TLS_CA_FILE" && -f "$TLS_CA_KEY" ]]; then
        openssl x509 -req -days "$days" \
            -in "$csr_file" -CA "$TLS_CA_FILE" -CAkey "$TLS_CA_KEY" \
            -CAcreateserial -out "$cert_file" \
            -extfile "$ext_file" -extensions req_ext \
            2>/dev/null || {
            log_error "Failed to sign certificate for ${username}"
            return 1
        }
    else
        openssl x509 -req -days "$days" \
            -in "$csr_file" -signkey "$key_file" \
            -out "$cert_file" \
            -extfile "$ext_file" -extensions req_ext \
            2>/dev/null || {
            log_error "Failed to self-sign certificate for ${username}"
            return 1
        }
    fi

    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    rm -f "$csr_file" "$ext_file"

    # Record the cert issuance
    local user_data_dir="${PANEL_DATA_DIR}/users/${username}"
    ensure_dir "$user_data_dir" 750 root
    {
        echo "TLS_CERT=${cert_file}"
        echo "TLS_KEY=${key_file}"
        echo "TLS_DOMAIN=${domain}"
        echo "TLS_ISSUED=$(date '+%Y-%m-%d')"
        echo "TLS_EXPIRES=$(date -d "+${days} days" '+%Y-%m-%d')"
    } > "${user_data_dir}/tls.conf"

    log_audit "TLS_CERT_ISSUED" "$username" "domain=${domain} cert=${cert_file} expires=$(date -d "+${days} days" '+%Y-%m-%d')"
    print_success "TLS certificate issued for '${username}'."
    print_table_row "Certificate" "$cert_file"
    print_table_row "Key" "$key_file"
    print_table_row "Expires" "$(date -d "+${days} days" '+%Y-%m-%d')"
    return 0
}

# Revoke a user's TLS certificate
tls_revoke_cert() {
    local username="$1"
    local user_cert_dir="${TLS_CERT_DIR}/users/${username}"
    local cert_file="${user_cert_dir}/${username}.crt"

    check_root || return 1

    if [[ -f "$cert_file" && -f "$TLS_CA_FILE" && -f "$TLS_CA_KEY" ]]; then
        openssl ca -revoke "$cert_file" \
            -keyfile "$TLS_CA_KEY" -cert "$TLS_CA_FILE" \
            2>/dev/null || log_warn "Could not formally revoke cert (may not have CA db); removing files."
    fi

    # Remove cert files
    if [[ -d "$user_cert_dir" ]]; then
        rm -rf "$user_cert_dir"
        log_info "Removed TLS certificate directory: ${user_cert_dir}"
    fi

    rm -f "${PANEL_DATA_DIR}/users/${username}/tls.conf" 2>/dev/null || true

    log_audit "TLS_CERT_REVOKED" "$username"
    print_success "TLS certificate revoked for '${username}'."
    return 0
}

# ---------------------------------------------------------------------------
# SNI domain management
# ---------------------------------------------------------------------------

# Add SNI domain permission for a user
# Usage: sni_add_domain USERNAME DOMAIN
sni_add_domain() {
    local username="$1"
    local domain="$2"

    validate_domain "$domain" || return 1

    ensure_dir "$SNI_CONFIG_DIR" 750 root
    local sni_file="${SNI_CONFIG_DIR}/${username}.domains"

    if grep -qx "$domain" "$sni_file" 2>/dev/null; then
        print_info "Domain '${domain}' already assigned to user '${username}'."
        return 0
    fi

    echo "$domain" >> "$sni_file"
    log_audit "SNI_DOMAIN_ADDED" "$username" "domain=${domain}"
    print_success "SNI domain '${domain}' added for user '${username}'."
    return 0
}

# Remove a SNI domain for a user
sni_remove_domain() {
    local username="$1"
    local domain="$2"
    local sni_file="${SNI_CONFIG_DIR}/${username}.domains"

    if [[ -f "$sni_file" ]]; then
        sed -i "/^${domain}\$/d" "$sni_file"
        log_audit "SNI_DOMAIN_REMOVED" "$username" "domain=${domain}"
        print_success "SNI domain '${domain}' removed for user '${username}'."
    fi
    return 0
}

# Remove all SNI domains for a user
sni_remove_user() {
    local username="$1"
    local sni_file="${SNI_CONFIG_DIR}/${username}.domains"

    if [[ -f "$sni_file" ]]; then
        rm -f "$sni_file"
        log_audit "SNI_USER_REMOVED" "$username"
        print_success "All SNI domains removed for user '${username}'."
    fi
    return 0
}

# List SNI domains for a user
sni_list_domains() {
    local username="$1"
    local sni_file="${SNI_CONFIG_DIR}/${username}.domains"
    print_section "SNI Domains for: ${username}"
    if [[ -f "$sni_file" ]] && [[ -s "$sni_file" ]]; then
        while IFS= read -r domain; do
            [[ -z "$domain" ]] && continue
            echo "  - ${domain}"
        done < "$sni_file"
    else
        print_info "No SNI domains configured for '${username}'."
    fi
}

# Display TLS/SNI info for a user
tls_user_info() {
    local username="$1"
    local user_data="${PANEL_DATA_DIR}/users/${username}/tls.conf"
    print_section "TLS/SNI Info: ${username}"
    if [[ -f "$user_data" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            print_table_row "$(echo "$key" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')" "$value"
        done < "$user_data"
    else
        print_warning "No TLS configuration found for user '${username}'."
    fi
    sni_list_domains "$username"
}
