#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - User Add Module
# Comprehensive user creation with full service integration:
#   SSH account, Stunnel tunnel, TLS/SNI certs, firewall rules,
#   VPN profile, bandwidth monitoring, logging
################################################################################

[[ -n "${_USER_ADD_LOADED:-}" ]] && return 0
_USER_ADD_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"
# shellcheck source=modules/ssh_management.sh
source "${SCRIPT_DIR}/ssh_management.sh"
# shellcheck source=modules/stunnel_config.sh
source "${SCRIPT_DIR}/stunnel_config.sh"
# shellcheck source=modules/tls_sni.sh
source "${SCRIPT_DIR}/tls_sni.sh"
# shellcheck source=modules/security.sh
source "${SCRIPT_DIR}/security.sh"
# shellcheck source=modules/vpn_users.sh
source "${SCRIPT_DIR}/vpn_users.sh"
# shellcheck source=modules/monitoring.sh
source "${SCRIPT_DIR}/monitoring.sh"

# ---------------------------------------------------------------------------
# Single user add
# ---------------------------------------------------------------------------

# Add a single user with all service integrations
# Usage: user_add USERNAME PASSWORD [options...]
#
# Options (environment variables or args):
#   EXPIRE_DAYS         - account expiry in days (default: 30)
#   QUOTA_MB            - disk quota in MB (default: 1024)
#   BANDWIDTH_LIMIT_MB  - bandwidth limit in MB (default: 10240)
#   MAX_CONNECTIONS     - max SSH sessions (default: 2)
#   CUSTOM_SHELL        - user shell (default: /bin/bash)
#   STUNNEL_ENABLED     - enable Stunnel tunnel (default: true)
#   STUNNEL_PORT        - Stunnel port (default: auto)
#   STUNNEL_DOMAIN      - SNI domain (default: from config)
#   TLS_ENABLED         - issue TLS cert (default: true)
#   TLS_DOMAIN          - TLS domain (default: from config)
#   TLS_DAYS            - TLS cert validity days (default: 365)
#   FIREWALL_WHITELIST  - add to firewall whitelist (default: true)
#   FIREWALL_RATE_LIMIT - apply rate limiting (default: true)
#   VPN_ENABLED         - create VPN profile (default: true)
#   MONITORING_ENABLED  - set up monitoring (default: true)
#   SSH_GEN_KEYS        - generate SSH key pair (default: true)
#   SSH_KEY_TYPE        - SSH key type: ed25519 or rsa (default: ed25519)
#   SNI_DOMAIN          - SNI domain to assign (default: STUNNEL_DOMAIN)
#   SEND_WELCOME_EMAIL  - send welcome email (default: false)
#   USER_EMAIL          - email address for notifications
#   TEMPLATE_FILE       - path to user template file
user_add() {
    local username="$1"
    local password="$2"

    # ----- Validate inputs -------------------------------------------------
    check_root || return 1
    validate_username "$username" || return 1

    # If password not provided, generate one
    if [[ -z "$password" ]]; then
        password="$(generate_password 16)"
        print_info "Auto-generated password for '${username}'."
    else
        validate_password "$password" || return 1
    fi

    # Load template defaults if provided
    if [[ -n "${TEMPLATE_FILE:-}" && -f "${TEMPLATE_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${TEMPLATE_FILE}"
        log_info "Loaded user template: ${TEMPLATE_FILE}"
    fi

    # Apply defaults
    local expire_days="${EXPIRE_DAYS:-${SSH_DEFAULT_EXPIRE_DAYS:-30}}"
    local expire_date
    expire_date="$(calc_expiry_date "$expire_days")"
    local quota_mb="${QUOTA_MB:-${SSH_DEFAULT_QUOTA_MB:-1024}}"
    local bandwidth_mb="${BANDWIDTH_LIMIT_MB:-${BANDWIDTH_LIMIT_DEFAULT_MB:-10240}}"
    local max_conn="${MAX_CONNECTIONS:-${SSH_MAX_SESSIONS:-2}}"
    local shell="${CUSTOM_SHELL:-${USER_SHELL_DEFAULT:-/bin/bash}}"
    local stunnel_enabled="${STUNNEL_ENABLED:-true}"
    local stunnel_port="${STUNNEL_PORT:-}"
    local stunnel_domain="${STUNNEL_DOMAIN:-${SNI_DEFAULT_DOMAIN:-vpn.example.com}}"
    local tls_enabled="${TLS_ENABLED:-true}"
    local tls_domain="${TLS_DOMAIN:-${stunnel_domain}}"
    local tls_days="${TLS_DAYS:-${TLS_DEFAULT_DAYS:-365}}"
    local firewall_wl="${FIREWALL_WHITELIST:-true}"
    local firewall_rl="${FIREWALL_RATE_LIMIT:-true}"
    local vpn_enabled="${VPN_ENABLED:-true}"
    local monitoring_enabled="${MONITORING_ENABLED:-true}"
    local ssh_gen_keys="${SSH_GEN_KEYS:-true}"
    local ssh_key_type="${SSH_KEY_TYPE:-ed25519}"
    local sni_domain="${SNI_DOMAIN:-${stunnel_domain}}"
    local user_email="${USER_EMAIL:-}"
    local send_welcome="${SEND_WELCOME_EMAIL:-false}"

    print_header "Adding User: ${username}"

    local step=1
    local errors=0

    # ------------------------------------------------------------------ Step 1: SSH account
    print_step "$((step++))" "Creating SSH system account..."
    if ! ssh_create_user "$username" "$password" "$shell" "$expire_date"; then
        print_error "Failed to create SSH account. Aborting."
        return 1
    fi
    print_success "SSH account created (expires: ${expire_date})"

    # ------------------------------------------------------------------ Step 2: SSH keys
    if [[ "$ssh_gen_keys" == "true" ]]; then
        print_step "$((step++))" "Generating SSH key pair (${ssh_key_type})..."
        ssh_generate_keys "$username" "$ssh_key_type" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 3: Session limits
    print_step "$((step++))" "Configuring SSH session limits (max: ${max_conn})..."
    ssh_set_max_sessions "$username" "$max_conn" || ((errors++))

    # ------------------------------------------------------------------ Step 4: TLS certificate
    if [[ "$tls_enabled" == "true" ]]; then
        print_step "$((step++))" "Issuing TLS certificate (domain: ${tls_domain})..."
        tls_issue_cert "$username" "$tls_domain" "$tls_days" || {
            log_warn "TLS cert issuance failed; continuing..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 5: SNI domain
    print_step "$((step++))" "Assigning SNI domain: ${sni_domain}..."
    sni_add_domain "$username" "$sni_domain" || ((errors++))

    # ------------------------------------------------------------------ Step 6: Stunnel tunnel
    if [[ "$stunnel_enabled" == "true" ]]; then
        print_step "$((step++))" "Configuring Stunnel tunnel..."
        stunnel_add_user "$username" "$stunnel_port" "$stunnel_domain" "true" || {
            log_warn "Stunnel setup failed; continuing..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 7: Firewall whitelist
    if [[ "$firewall_wl" == "true" ]]; then
        print_step "$((step++))" "Adding firewall whitelist entry..."
        firewall_add_user "$username" "ANY" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 8: Rate limiting
    if [[ "$firewall_rl" == "true" ]]; then
        print_step "$((step++))" "Applying firewall rate limits..."
        firewall_add_rate_limit "$username" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 9: Fail2ban jail
    print_step "$((step++))" "Configuring fail2ban protection..."
    fail2ban_add_user_jail "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 10: VPN profile
    if [[ "$vpn_enabled" == "true" ]]; then
        print_step "$((step++))" "Creating VPN profile..."
        vpn_add_user "$username" "$quota_mb" "$bandwidth_mb" "$expire_date" || {
            log_warn "VPN profile creation failed; continuing..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 11: Monitoring
    if [[ "$monitoring_enabled" == "true" ]]; then
        print_step "$((step++))" "Setting up monitoring and logging..."
        monitoring_add_user "$username" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 12: User directories
    print_step "$((step++))" "Creating user directories..."
    _user_setup_directories "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 13: Welcome email
    if [[ "$send_welcome" == "true" && -n "$user_email" ]]; then
        print_step "$((step++))" "Sending welcome email to ${user_email}..."
        _user_send_welcome_email "$username" "$user_email" "$password" "$expire_date" \
            "$(stunnel_get_user_port "$username")" "$stunnel_domain" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 14: Final audit
    log_audit "USER_ADDED" "$username" \
        "expire=${expire_date} quota=${quota_mb}MB bw=${bandwidth_mb}MB stunnel=${stunnel_enabled} tls=${tls_enabled} errors=${errors}"

    echo ""
    print_header "User Add Summary: ${username}"
    print_table_row "Username"       "$username"
    print_table_row "Password"       "${password}"
    print_table_row "Expires"        "$expire_date"
    print_table_row "Shell"          "$shell"
    print_table_row "Max Sessions"   "$max_conn"
    print_table_row "Quota"          "${quota_mb} MB"
    print_table_row "BW Limit"       "${bandwidth_mb} MB"
    print_table_row "SSH Keys"       "$([[ "$ssh_gen_keys" == "true" ]] && echo "generated" || echo "none")"
    if [[ "$stunnel_enabled" == "true" ]]; then
        local actual_port
        actual_port="$(stunnel_get_user_port "$username")"
        print_table_row "Stunnel Port"   "${actual_port:-N/A}"
        print_table_row "Stunnel Domain" "$stunnel_domain"
    fi
    print_table_row "TLS Cert"       "$([[ "$tls_enabled" == "true" ]] && echo "issued" || echo "none")"
    print_table_row "SNI Domain"     "$sni_domain"
    print_table_row "Firewall"       "whitelist=$firewall_wl, rate-limit=$firewall_rl"
    print_table_row "VPN Profile"    "$vpn_enabled"
    print_table_row "Monitoring"     "$monitoring_enabled"

    if [[ "$errors" -gt 0 ]]; then
        print_warning "User added with ${errors} non-fatal error(s). Review logs for details."
    else
        print_success "User '${username}' added successfully with all services configured."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Interactive user add (prompts for all settings)
# ---------------------------------------------------------------------------

user_add_interactive() {
    print_header "Interactive User Add"
    check_root || return 1

    local username password expire_days quota_mb bandwidth_mb max_conn
    local stunnel_enabled tls_enabled vpn_enabled user_email send_welcome

    prompt_input username "Username"
    validate_username "$username" || return 1

    if user_exists "$username"; then
        print_error "User '${username}' already exists."
        return 1
    fi

    prompt_password password "Password (leave blank to auto-generate)"
    if [[ -z "$password" ]]; then
        password="$(generate_password 16)"
        print_info "Auto-generated password: ${password}"
    fi

    prompt_input expire_days "Expiry (days)" "30"
    prompt_input quota_mb "Disk quota (MB)" "1024"
    prompt_input bandwidth_mb "Bandwidth limit (MB)" "10240"
    prompt_input max_conn "Max simultaneous connections" "2"

    if prompt_confirm "Enable Stunnel tunnel?" "y"; then
        stunnel_enabled=true
    else
        stunnel_enabled=false
    fi

    if prompt_confirm "Issue TLS certificate?" "y"; then
        tls_enabled=true
    else
        tls_enabled=false
    fi

    if prompt_confirm "Create VPN profile?" "y"; then
        vpn_enabled=true
    else
        vpn_enabled=false
    fi

    if prompt_confirm "Send welcome email?" "n"; then
        send_welcome=true
        prompt_input user_email "Email address" ""
    else
        send_welcome=false
    fi

    # Export as environment variables for user_add to pick up
    EXPIRE_DAYS="$expire_days" \
    QUOTA_MB="$quota_mb" \
    BANDWIDTH_LIMIT_MB="$bandwidth_mb" \
    MAX_CONNECTIONS="$max_conn" \
    STUNNEL_ENABLED="$stunnel_enabled" \
    TLS_ENABLED="$tls_enabled" \
    VPN_ENABLED="$vpn_enabled" \
    SEND_WELCOME_EMAIL="$send_welcome" \
    USER_EMAIL="${user_email:-}" \
        user_add "$username" "$password"
}

# ---------------------------------------------------------------------------
# Batch user add from CSV or JSON
# ---------------------------------------------------------------------------

# Add multiple users from a CSV file
# CSV format: username,password,expire_days,quota_mb,bandwidth_mb,max_conn,email
# Usage: user_add_batch_csv /path/to/users.csv
user_add_batch_csv() {
    local csv_file="$1"

    if [[ ! -f "$csv_file" ]]; then
        log_error "CSV file not found: ${csv_file}"
        return 1
    fi

    check_root || return 1
    print_header "Batch User Add (CSV)"

    local success=0 failure=0 total=0 lineno=0

    while IFS=',' read -r username password expire_days quota_mb bandwidth_mb max_conn email; do
        ((lineno++))
        # Skip header/comments
        [[ "$username" == \#* || "$username" == "username" || -z "$username" ]] && continue
        ((total++))

        # Trim whitespace
        username="${username// /}"
        email="${email// /}"

        log_info "Processing CSV line ${lineno}: ${username}"

        EXPIRE_DAYS="${expire_days:-30}" \
        QUOTA_MB="${quota_mb:-1024}" \
        BANDWIDTH_LIMIT_MB="${bandwidth_mb:-10240}" \
        MAX_CONNECTIONS="${max_conn:-2}" \
        USER_EMAIL="${email}" \
        SEND_WELCOME_EMAIL="$([[ -n "$email" ]] && echo "true" || echo "false")" \
            user_add "$username" "$password"

        if [[ $? -eq 0 ]]; then
            ((success++))
        else
            ((failure++))
            log_error "Failed to add user: ${username}"
        fi
    done < "$csv_file"

    echo ""
    print_section "Batch Add Results"
    print_table_row "Total" "$total"
    print_table_row "Success" "$success"
    print_table_row "Failed" "$failure"

    log_audit "BATCH_USER_ADD" "SYSTEM" "csv=${csv_file} total=${total} success=${success} failed=${failure}"
    return "$([[ "$failure" -eq 0 ]] && echo 0 || echo 1)"
}

# Add multiple users from a JSON file
# JSON format: [{"username":"...","password":"...","expire_days":30,...},...]
# Requires jq
user_add_batch_json() {
    local json_file="$1"

    if [[ ! -f "$json_file" ]]; then
        log_error "JSON file not found: ${json_file}"
        return 1
    fi

    check_root || return 1
    check_command "jq" || return 1
    print_header "Batch User Add (JSON)"

    local total success failure
    total=0; success=0; failure=0

    while IFS= read -r user_json; do
        local username password expire_days quota_mb bandwidth_mb email
        username="$(echo "$user_json" | jq -r '.username // empty')"
        password="$(echo "$user_json" | jq -r '.password // empty')"
        expire_days="$(echo "$user_json" | jq -r '.expire_days // 30')"
        quota_mb="$(echo "$user_json" | jq -r '.quota_mb // 1024')"
        bandwidth_mb="$(echo "$user_json" | jq -r '.bandwidth_mb // 10240')"
        email="$(echo "$user_json" | jq -r '.email // empty')"

        [[ -z "$username" ]] && continue
        ((total++))

        EXPIRE_DAYS="$expire_days" \
        QUOTA_MB="$quota_mb" \
        BANDWIDTH_LIMIT_MB="$bandwidth_mb" \
        USER_EMAIL="$email" \
        SEND_WELCOME_EMAIL="$([[ -n "$email" ]] && echo "true" || echo "false")" \
            user_add "$username" "$password"

        if [[ $? -eq 0 ]]; then
            ((success++))
        else
            ((failure++))
        fi
    done < <(jq -c '.[]' "$json_file" 2>/dev/null)

    echo ""
    print_section "Batch JSON Add Results"
    print_table_row "Total" "$total"
    print_table_row "Success" "$success"
    print_table_row "Failed" "$failure"

    log_audit "BATCH_USER_ADD_JSON" "SYSTEM" "json=${json_file} total=${total} success=${success} failed=${failure}"
    return "$([[ "$failure" -eq 0 ]] && echo 0 || echo 1)"
}

# ---------------------------------------------------------------------------
# Create temporary/trial user
# ---------------------------------------------------------------------------

# Create a trial user with short expiry (default 7 days)
# Usage: user_add_trial USERNAME [days]
user_add_trial() {
    local username="$1"
    local days="${2:-7}"
    local password
    password="$(generate_password 12)"

    print_info "Creating trial user '${username}' (${days} days)..."

    EXPIRE_DAYS="$days" \
    QUOTA_MB="512" \
    BANDWIDTH_LIMIT_MB="2048" \
    MAX_CONNECTIONS="1" \
    SSH_GEN_KEYS="false" \
    STUNNEL_ENABLED="true" \
    TLS_ENABLED="false" \
    VPN_ENABLED="true" \
    MONITORING_ENABLED="true" \
        user_add "$username" "$password"

    log_audit "TRIAL_USER_ADDED" "$username" "days=${days}"
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Create user-specific directories
_user_setup_directories() {
    local username="$1"
    local home_dir
    home_dir="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || echo "/home/${username}")"

    local dirs=("${home_dir}/vpn" "${home_dir}/.config/sshvpnpanel")
    for dir in "${dirs[@]}"; do
        ensure_dir "$dir" 750 root
        chown "$username" "$dir" 2>/dev/null || true
        chmod 700 "$dir" 2>/dev/null || true
    done
    return 0
}

# Send a welcome email with credentials
_user_send_welcome_email() {
    local username="$1"
    local email="$2"
    local password="$3"
    local expire_date="$4"
    local stunnel_port="$5"
    local stunnel_domain="$6"

    validate_email "$email" || return 1

    local subject="Your SSH VPN Panel Account"
    local body
    body="$(cat << EOF
Welcome to SSH VPN Panel!

Your account has been created. Please find your credentials below:

  Username    : ${username}
  Password    : ${password}
  Expires     : ${expire_date}

SSH Connection:
  Host        : $(hostname -f 2>/dev/null || hostname)
  Port        : ${SSH_PORT:-22}

Stunnel/TLS Connection:
  Host        : ${stunnel_domain}
  Port        : ${stunnel_port:-443}

Please change your password after your first login.

This is an automated message from SSH VPN Panel.
EOF
)"
    send_email "$email" "$subject" "$body"
}
