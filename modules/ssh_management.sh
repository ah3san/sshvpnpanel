#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - SSH User Management Module
# =============================================================================
# Handles creation, deletion, modification of SSH user accounts,
# bandwidth limits, expiration dates, SSH keys, and connection monitoring.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# SSH USER DATABASE
# =============================================================================
# User data is stored in ${USER_DATA_DIR}/<username>/ssh.conf
# Format: KEY=VALUE per line

SSH_USER_DB_DIR="${USER_DATA_DIR:-/etc/sshvpnpanel/users}"

# Initialize SSH management
init_ssh_management() {
    mkdir -p "${SSH_USER_DB_DIR}" 2>/dev/null
    chmod 700 "${SSH_USER_DB_DIR}" 2>/dev/null
}

# Get SSH user data file
ssh_user_file() {
    local username="$1"
    echo "${SSH_USER_DB_DIR}/${username}/ssh.conf"
}

# Check if SSH user exists in the panel
ssh_user_exists() {
    local username="$1"
    [[ -f "$(ssh_user_file "${username}")" ]]
}

# =============================================================================
# CREATE SSH USER
# =============================================================================

create_ssh_user() {
    local username="$1"
    local password="$2"
    local expiry_days="${3:-${DEFAULT_SSH_EXPIRY_DAYS:-30}}"
    local bandwidth_limit="${4:-${DEFAULT_BANDWIDTH_LIMIT:-0}}"
    local max_logins="${5:-${MAX_CONNECTIONS_PER_USER:-2}}"

    require_root || return 1

    # Validate inputs
    validate_username "${username}" || return 1

    if id "${username}" &>/dev/null 2>&1; then
        print_error "System user '${username}' already exists"
        return 1
    fi

    if ssh_user_exists "${username}"; then
        print_error "SSH panel user '${username}' already exists"
        return 1
    fi

    print_info "Creating SSH user: ${username}"

    # Create system user
    local shell="${VPN_USER_SHELL:-/bin/false}"
    local expiry_date
    expiry_date="$(calc_expiry_date "${expiry_days}")"

    if useradd -m -s "${shell}" -c "VPN User" "${username}" 2>/dev/null; then
        log_info "Created system user: ${username}"
    else
        print_error "Failed to create system user: ${username}"
        return 1
    fi

    # Set password
    if echo "${username}:${password}" | chpasswd 2>/dev/null; then
        log_info "Set password for user: ${username}"
    else
        print_error "Failed to set password for: ${username}"
        userdel -r "${username}" 2>/dev/null
        return 1
    fi

    # Set account expiration
    if [[ "${expiry_days}" -gt 0 && "${expiry_date}" != "never" ]]; then
        chage -E "${expiry_date}" "${username}" 2>/dev/null || true
    fi

    # Create panel data directory
    local user_dir="${SSH_USER_DB_DIR}/${username}"
    mkdir -p "${user_dir}" 2>/dev/null
    chmod 700 "${user_dir}" 2>/dev/null

    # Save user configuration
    cat > "$(ssh_user_file "${username}")" << EOF
# SSH Panel User Configuration
USERNAME=${username}
CREATED=$(get_timestamp)
EXPIRY_DATE=${expiry_date}
EXPIRY_DAYS=${expiry_days}
BANDWIDTH_LIMIT=${bandwidth_limit}
MAX_LOGINS=${max_logins}
STATUS=active
BYTES_SENT=0
BYTES_RECV=0
LAST_LOGIN=never
LOGIN_COUNT=0
NOTES=
EOF
    chmod 600 "$(ssh_user_file "${username}")"

    print_success "SSH user '${username}' created successfully"
    print_info "  Expiry: ${expiry_date}"
    print_info "  Bandwidth limit: $([ "${bandwidth_limit}" -eq 0 ] && echo "unlimited" || echo "${bandwidth_limit} KB/s")"
    print_info "  Max logins: ${max_logins}"

    log_audit "ssh_user_create" "username=${username},expiry=${expiry_date}"
    return 0
}

# =============================================================================
# DELETE SSH USER
# =============================================================================

delete_ssh_user() {
    local username="$1"
    local force="${2:-no}"

    require_root || return 1

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    if [[ "${force}" != "yes" ]]; then
        confirm "Delete SSH user '${username}'? This cannot be undone" "no" || return 0
    fi

    print_info "Deleting SSH user: ${username}"

    # Kill active sessions
    local sessions
    sessions="$(get_user_ssh_sessions "${username}")"
    if [[ -n "${sessions}" ]]; then
        print_warning "Terminating active sessions for ${username}..."
        pkill -u "${username}" -9 2>/dev/null || true
    fi

    # Remove system user
    if id "${username}" &>/dev/null 2>&1; then
        userdel -r "${username}" 2>/dev/null || userdel "${username}" 2>/dev/null
    fi

    # Remove panel data
    rm -rf "${SSH_USER_DB_DIR}/${username}" 2>/dev/null

    print_success "SSH user '${username}' deleted successfully"
    log_audit "ssh_user_delete" "username=${username}"
    return 0
}

# =============================================================================
# MODIFY SSH USER
# =============================================================================

modify_ssh_user() {
    local username="$1"

    require_root || return 1

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local user_file
    user_file="$(ssh_user_file "${username}")"

    clear_screen
    print_header "Modify SSH User: ${username}"

    echo -e "\n${C_BOLD}What would you like to modify?${C_RESET}"
    echo "  1. Change password"
    echo "  2. Change expiry date"
    echo "  3. Change bandwidth limit"
    echo "  4. Change max logins"
    echo "  5. Change status (active/suspended)"
    echo "  6. Update notes"
    echo "  7. Back"
    echo

    local choice
    choice="$(read_int "Select option" 1 7)"

    case "${choice}" in
        1) _modify_ssh_password "${username}" ;;
        2) _modify_ssh_expiry "${username}" "${user_file}" ;;
        3) _modify_ssh_bandwidth "${username}" "${user_file}" ;;
        4) _modify_ssh_max_logins "${username}" "${user_file}" ;;
        5) _modify_ssh_status "${username}" "${user_file}" ;;
        6) _modify_ssh_notes "${username}" "${user_file}" ;;
        7) return 0 ;;
    esac
}

_modify_ssh_password() {
    local username="$1"
    local new_pass
    read_password "Enter new password for ${username}" new_pass
    local confirm_pass
    read_password "Confirm new password" confirm_pass

    if [[ "${new_pass}" != "${confirm_pass}" ]]; then
        print_error "Passwords do not match"
        return 1
    fi

    validate_password "${new_pass}" || return 1

    if echo "${username}:${new_pass}" | chpasswd 2>/dev/null; then
        print_success "Password changed for ${username}"
        log_audit "ssh_user_password_change" "username=${username}"
    else
        print_error "Failed to change password"
        return 1
    fi
}

_modify_ssh_expiry() {
    local username="$1"
    local user_file="$2"

    local days
    days="$(read_int "New expiry in days (0=never)" 0 3650)"

    local expiry_date
    expiry_date="$(calc_expiry_date "${days}")"

    if [[ "${days}" -gt 0 ]]; then
        chage -E "${expiry_date}" "${username}" 2>/dev/null || true
    else
        chage -E -1 "${username}" 2>/dev/null || true
    fi

    config_set "${user_file}" "EXPIRY_DATE" "${expiry_date}"
    config_set "${user_file}" "EXPIRY_DAYS" "${days}"

    print_success "Expiry updated to: ${expiry_date}"
    log_audit "ssh_user_expiry_change" "username=${username},expiry=${expiry_date}"
}

_modify_ssh_bandwidth() {
    local username="$1"
    local user_file="$2"

    local limit
    limit="$(read_int "Bandwidth limit in KB/s (0=unlimited)" 0 100000)"
    config_set "${user_file}" "BANDWIDTH_LIMIT" "${limit}"
    print_success "Bandwidth limit updated to: $([ "${limit}" -eq 0 ] && echo "unlimited" || echo "${limit} KB/s")"
    log_audit "ssh_user_bandwidth_change" "username=${username},limit=${limit}"
}

_modify_ssh_max_logins() {
    local username="$1"
    local user_file="$2"

    local max
    max="$(read_int "Max simultaneous logins" 1 50)"
    config_set "${user_file}" "MAX_LOGINS" "${max}"
    print_success "Max logins updated to: ${max}"
    log_audit "ssh_user_maxlogins_change" "username=${username},max=${max}"
}

_modify_ssh_status() {
    local username="$1"
    local user_file="$2"

    local current_status
    current_status="$(config_get "${user_file}" "STATUS" "active")"

    echo "Current status: ${current_status}"
    echo "  1. Active"
    echo "  2. Suspended"

    local choice
    choice="$(read_int "Select status" 1 2)"

    if [[ "${choice}" -eq 1 ]]; then
        usermod -U "${username}" 2>/dev/null || true
        config_set "${user_file}" "STATUS" "active"
        print_success "User ${username} is now active"
        log_audit "ssh_user_status_change" "username=${username},status=active"
    else
        usermod -L "${username}" 2>/dev/null || true
        config_set "${user_file}" "STATUS" "suspended"
        print_success "User ${username} is now suspended"
        log_audit "ssh_user_status_change" "username=${username},status=suspended"
    fi
}

_modify_ssh_notes() {
    local username="$1"
    local user_file="$2"

    local notes
    read_input "Notes for ${username}" "" notes
    config_set "${user_file}" "NOTES" "${notes}"
    print_success "Notes updated"
}

# =============================================================================
# VIEW SSH USERS
# =============================================================================

list_ssh_users() {
    clear_screen
    print_header "SSH Users"

    local users=()
    if [[ -d "${SSH_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            local username
            username="$(basename "${user_dir}")"
            [[ -f "$(ssh_user_file "${username}")" ]] && users+=("${username}")
        done < <(find "${SSH_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if [[ ${#users[@]} -eq 0 ]]; then
        print_info "No SSH users found"
        return
    fi

    print_table_header "Username" "Status" "Expiry" "Sessions" "Bandwidth"

    for username in "${users[@]}"; do
        local user_file
        user_file="$(ssh_user_file "${username}")"
        local status
        status="$(config_get "${user_file}" "STATUS" "active")"
        local expiry
        expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"
        local sessions
        sessions="$(get_user_ssh_sessions "${username}" | wc -l)"
        local bandwidth
        bandwidth="$(config_get "${user_file}" "BANDWIDTH_LIMIT" "0")"
        local bw_display
        bw_display="$([ "${bandwidth}" -eq 0 ] && echo "unlimited" || echo "${bandwidth}KB/s")"

        # Color code status
        local status_color="${C_SUCCESS}"
        [[ "${status}" == "suspended" ]] && status_color="${C_WARNING}"
        is_expired "${expiry}" 2>/dev/null && status_color="${C_ERROR}" && status="expired"

        printf "  ${C_BOLD}%-18s${C_RESET} ${status_color}%-12s${C_RESET} %-14s %-10s %s\n" \
            "${username}" "${status}" "${expiry}" "${sessions}" "${bw_display}"
    done

    echo
    print_info "Total users: ${#users[@]}"
}

show_ssh_user_detail() {
    local username="$1"

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local user_file
    user_file="$(ssh_user_file "${username}")"

    clear_screen
    print_header "SSH User Detail: ${username}"

    echo -e "\n${C_BOLD}Account Information${C_RESET}"
    print_separator 40

    local fields=(
        "Username:$(config_get "${user_file}" "USERNAME")"
        "Status:$(config_get "${user_file}" "STATUS" "active")"
        "Created:$(config_get "${user_file}" "CREATED")"
        "Expiry Date:$(config_get "${user_file}" "EXPIRY_DATE" "never")"
        "Days Until Expiry:$(days_until_expiry "$(config_get "${user_file}" "EXPIRY_DATE" "never")")"
        "Max Logins:$(config_get "${user_file}" "MAX_LOGINS" "2")"
        "Last Login:$(config_get "${user_file}" "LAST_LOGIN" "never")"
        "Login Count:$(config_get "${user_file}" "LOGIN_COUNT" "0")"
    )

    for field in "${fields[@]}"; do
        local key="${field%%:*}"
        local val="${field#*:}"
        printf "  ${C_BOLD}%-22s${C_RESET} %s\n" "${key}:" "${val}"
    done

    echo -e "\n${C_BOLD}Bandwidth & Traffic${C_RESET}"
    print_separator 40
    local bw
    bw="$(config_get "${user_file}" "BANDWIDTH_LIMIT" "0")"
    local bytes_sent
    bytes_sent="$(config_get "${user_file}" "BYTES_SENT" "0")"
    local bytes_recv
    bytes_recv="$(config_get "${user_file}" "BYTES_RECV" "0")"

    printf "  ${C_BOLD}%-22s${C_RESET} %s\n" "Bandwidth Limit:" \
        "$([ "${bw}" -eq 0 ] && echo "unlimited" || echo "${bw} KB/s")"
    printf "  ${C_BOLD}%-22s${C_RESET} %s\n" "Data Sent:" "$(bytes_to_human "${bytes_sent}")"
    printf "  ${C_BOLD}%-22s${C_RESET} %s\n" "Data Received:" "$(bytes_to_human "${bytes_recv}")"

    echo -e "\n${C_BOLD}Active Sessions${C_RESET}"
    print_separator 40
    local sessions
    sessions="$(get_user_ssh_sessions "${username}")"
    if [[ -n "${sessions}" ]]; then
        echo "${sessions}" | while IFS= read -r line; do
            echo "  ${line}"
        done
    else
        echo "  No active sessions"
    fi

    local notes
    notes="$(config_get "${user_file}" "NOTES" "")"
    if [[ -n "${notes}" ]]; then
        echo -e "\n${C_BOLD}Notes${C_RESET}"
        print_separator 40
        echo "  ${notes}"
    fi
}

# =============================================================================
# SSH KEY MANAGEMENT
# =============================================================================

generate_ssh_key() {
    local username="$1"
    local key_type="${2:-ed25519}"
    local key_comment="${3:-${username}@sshvpnpanel}"

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    require_root || return 1

    local key_dir="${SSH_USER_DB_DIR}/${username}/keys"
    mkdir -p "${key_dir}" 2>/dev/null
    chmod 700 "${key_dir}" 2>/dev/null

    local key_file="${key_dir}/${username}_${key_type}"

    print_info "Generating ${key_type} SSH key for ${username}..."

    if ssh-keygen -t "${key_type}" -f "${key_file}" -N "" -C "${key_comment}" 2>/dev/null; then
        chmod 600 "${key_file}"
        chmod 644 "${key_file}.pub"

        # Install public key for the user
        local user_home
        user_home="$(getent passwd "${username}" | cut -d: -f6)"
        if [[ -n "${user_home}" && -d "${user_home}" ]]; then
            local auth_keys="${user_home}/.ssh/authorized_keys"
            mkdir -p "${user_home}/.ssh" 2>/dev/null
            chmod 700 "${user_home}/.ssh" 2>/dev/null
            cat "${key_file}.pub" >> "${auth_keys}"
            chmod 600 "${auth_keys}" 2>/dev/null
            chown -R "${username}:${username}" "${user_home}/.ssh" 2>/dev/null
        fi

        print_success "SSH key generated: ${key_file}"
        print_info "Public key:"
        cat "${key_file}.pub"
        print_info "\nPrivate key location: ${key_file}"
        print_warning "Save the private key securely - it will not be shown again!"

        log_audit "ssh_key_generate" "username=${username},type=${key_type}"
        return 0
    else
        print_error "Failed to generate SSH key"
        return 1
    fi
}

add_ssh_authorized_key() {
    local username="$1"
    local public_key="$2"

    require_root || return 1

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local user_home
    user_home="$(getent passwd "${username}" | cut -d: -f6)"
    if [[ -z "${user_home}" ]]; then
        print_error "Cannot find home directory for ${username}"
        return 1
    fi

    local auth_keys="${user_home}/.ssh/authorized_keys"
    mkdir -p "${user_home}/.ssh" 2>/dev/null
    chmod 700 "${user_home}/.ssh" 2>/dev/null

    echo "${public_key}" >> "${auth_keys}"
    chmod 600 "${auth_keys}"
    chown -R "${username}:${username}" "${user_home}/.ssh" 2>/dev/null

    print_success "Public key added for ${username}"
    log_audit "ssh_key_add" "username=${username}"
}

list_ssh_keys() {
    local username="$1"

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local user_home
    user_home="$(getent passwd "${username}" | cut -d: -f6)"
    local auth_keys="${user_home}/.ssh/authorized_keys"

    clear_screen
    print_header "SSH Keys: ${username}"

    if [[ -f "${auth_keys}" ]]; then
        local count=0
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == "#"* ]] && continue
            (( count++ ))
            local key_type
            key_type="$(echo "${line}" | awk '{print $1}')"
            local key_comment
            key_comment="$(echo "${line}" | awk '{print $3}')"
            echo -e "  ${C_BOLD}${count}.${C_RESET} ${key_type} ... ${key_comment}"
        done < "${auth_keys}"
        echo
        print_info "Total keys: ${count}"
    else
        print_info "No authorized keys found"
    fi
}

revoke_ssh_key() {
    local username="$1"
    local key_index="${2:-1}"

    require_root || return 1

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local user_home
    user_home="$(getent passwd "${username}" | cut -d: -f6)"
    local auth_keys="${user_home}/.ssh/authorized_keys"

    if [[ ! -f "${auth_keys}" ]]; then
        print_error "No authorized keys file found"
        return 1
    fi

    # Remove the nth key
    local tmp_file="${auth_keys}.tmp.$$"
    awk -v idx="${key_index}" '
        /^[^#]/ { count++; if (count != idx) print; next }
        { print }
    ' "${auth_keys}" > "${tmp_file}" && mv "${tmp_file}" "${auth_keys}"

    chmod 600 "${auth_keys}"
    print_success "Key #${key_index} revoked for ${username}"
    log_audit "ssh_key_revoke" "username=${username},key_index=${key_index}"
}

# =============================================================================
# SSH CONNECTION MONITORING
# =============================================================================

get_user_ssh_sessions() {
    local username="$1"
    who 2>/dev/null | grep "^${username} " || \
    w -h 2>/dev/null | awk -v user="${username}" '$1==user {print}' || \
    true
}

get_all_ssh_sessions() {
    clear_screen
    print_header "Active SSH Sessions"

    local sessions
    sessions="$(who 2>/dev/null)"

    if [[ -z "${sessions}" ]]; then
        print_info "No active SSH sessions"
        return
    fi

    print_table_header "User" "Terminal" "Login Time" "From IP"

    while IFS= read -r line; do
        local user tty date time ip
        user="$(echo "${line}" | awk '{print $1}')"
        tty="$(echo "${line}" | awk '{print $2}')"
        date="$(echo "${line}" | awk '{print $3}')"
        time="$(echo "${line}" | awk '{print $4}')"
        ip="$(echo "${line}" | awk '{print $5}' | tr -d '()')"

        printf "  ${C_BOLD}%-16s${C_RESET} %-12s %-12s %-8s %s\n" \
            "${user}" "${tty}" "${date}" "${time}" "${ip:-local}"
    done <<< "${sessions}"

    echo
    print_info "Total sessions: $(echo "${sessions}" | wc -l)"
}

terminate_user_sessions() {
    local username="$1"

    require_root || return 1

    if ! ssh_user_exists "${username}"; then
        print_error "SSH user '${username}' not found"
        return 1
    fi

    local session_count
    session_count="$(get_user_ssh_sessions "${username}" | wc -l)"

    if [[ "${session_count}" -eq 0 ]]; then
        print_info "No active sessions for ${username}"
        return 0
    fi

    confirm "Terminate all ${session_count} sessions for '${username}'?" "no" || return 0

    pkill -u "${username}" -TERM 2>/dev/null || true
    sleep 1
    pkill -u "${username}" -KILL 2>/dev/null || true

    print_success "Terminated ${session_count} sessions for ${username}"
    log_audit "ssh_sessions_terminate" "username=${username},count=${session_count}"
}

# =============================================================================
# SSH QUOTA ENFORCEMENT
# =============================================================================

check_user_quota() {
    local username="$1"

    if ! ssh_user_exists "${username}"; then
        return 1
    fi

    local user_file
    user_file="$(ssh_user_file "${username}")"
    local max_logins
    max_logins="$(config_get "${user_file}" "MAX_LOGINS" "2")"
    local current_sessions
    current_sessions="$(get_user_ssh_sessions "${username}" | wc -l)"

    if [[ "${current_sessions}" -ge "${max_logins}" ]]; then
        log_warn "User ${username} exceeded max login quota (${current_sessions}/${max_logins})"
        return 1
    fi
    return 0
}

enforce_ssh_quotas() {
    require_root || return 1
    print_info "Enforcing SSH quotas..."

    local users=()
    if [[ -d "${SSH_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            users+=("$(basename "${user_dir}")")
        done < <(find "${SSH_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    local enforced=0
    for username in "${users[@]}"; do
        local user_file
        user_file="$(ssh_user_file "${username}")"

        # Check expiration
        local expiry
        expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"
        if is_expired "${expiry}" 2>/dev/null; then
            local status
            status="$(config_get "${user_file}" "STATUS" "active")"
            if [[ "${status}" == "active" ]]; then
                print_warning "User ${username} has expired - suspending"
                usermod -L "${username}" 2>/dev/null || true
                config_set "${user_file}" "STATUS" "expired"
                terminate_user_sessions "${username}" <<< "yes"
                (( enforced++ ))
            fi
        fi

        # Check login quota
        if ! check_user_quota "${username}"; then
            local max_logins
            max_logins="$(config_get "${user_file}" "MAX_LOGINS" "2")"
            print_warning "User ${username} exceeded quota - terminating excess sessions"
            # Keep only the most recent session
            local pids
            pids="$(pgrep -u "${username}" sshd 2>/dev/null | head -n -"${max_logins}")"
            for pid in ${pids}; do
                kill -TERM "${pid}" 2>/dev/null || true
            done
            (( enforced++ ))
        fi
    done

    print_success "Quota enforcement complete. Acted on ${enforced} users."
}

# =============================================================================
# CLEANUP EXPIRED USERS
# =============================================================================

cleanup_expired_ssh_users() {
    require_root || return 1
    print_info "Checking for expired SSH users..."

    local users=()
    if [[ -d "${SSH_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            users+=("$(basename "${user_dir}")")
        done < <(find "${SSH_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    local cleaned=0
    for username in "${users[@]}"; do
        local user_file
        user_file="$(ssh_user_file "${username}")"
        local expiry
        expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"

        if is_expired "${expiry}" 2>/dev/null; then
            print_warning "Expired user: ${username} (expired: ${expiry})"
            if [[ "${AUTO_CLEANUP_EXPIRED:-yes}" == "yes" ]]; then
                delete_ssh_user "${username}" "yes"
                (( cleaned++ ))
            fi
        fi
    done

    print_success "Cleanup complete. Removed ${cleaned} expired users."
}

# =============================================================================
# SSH MANAGEMENT MENU
# =============================================================================

ssh_management_menu() {
    while true; do
        clear_screen
        print_header "SSH User Management"

        echo -e "${C_BOLD}Options:${C_RESET}"
        echo "  1. Create SSH User"
        echo "  2. Delete SSH User"
        echo "  3. Modify SSH User"
        echo "  4. List SSH Users"
        echo "  5. View User Details"
        echo "  6. SSH Key Management"
        echo "  7. Active Sessions"
        echo "  8. Terminate User Sessions"
        echo "  9. Enforce Quotas"
        echo " 10. Cleanup Expired Users"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 10)"

        case "${choice}" in
            1) _menu_create_ssh_user ;;
            2) _menu_delete_ssh_user ;;
            3) _menu_modify_ssh_user ;;
            4) list_ssh_users; read -rp $'\nPress Enter to continue...' ;;
            5) _menu_show_ssh_user_detail ;;
            6) _menu_ssh_key_management ;;
            7) get_all_ssh_sessions; read -rp $'\nPress Enter to continue...' ;;
            8) _menu_terminate_sessions ;;
            9) enforce_ssh_quotas; read -rp $'\nPress Enter to continue...' ;;
            10) cleanup_expired_ssh_users; read -rp $'\nPress Enter to continue...' ;;
            0) return 0 ;;
        esac
    done
}

_menu_create_ssh_user() {
    clear_screen
    print_header "Create SSH User"

    local username
    while true; do
        read_input "Username" "" username
        validate_username "${username}" && break
    done

    local password
    while true; do
        read_password "Password" password
        local confirm_pass
        read_password "Confirm Password" confirm_pass
        if [[ "${password}" == "${confirm_pass}" ]]; then
            validate_password "${password}" && break
        else
            print_error "Passwords do not match"
        fi
    done

    local expiry_days
    expiry_days="$(read_int "Expiry in days (0=never)" 0 3650 "${DEFAULT_SSH_EXPIRY_DAYS:-30}")"
    local bandwidth
    bandwidth="$(read_int "Bandwidth limit KB/s (0=unlimited)" 0 100000 "0")"
    local max_logins
    max_logins="$(read_int "Max simultaneous logins" 1 50 "${MAX_CONNECTIONS_PER_USER:-2}")"

    echo
    create_ssh_user "${username}" "${password}" "${expiry_days}" "${bandwidth}" "${max_logins}"
    read -rp $'\nPress Enter to continue...'
}

_menu_delete_ssh_user() {
    clear_screen
    print_header "Delete SSH User"
    list_ssh_users

    echo
    local username
    read_input "Enter username to delete (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    delete_ssh_user "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_modify_ssh_user() {
    clear_screen
    print_header "Modify SSH User"
    list_ssh_users

    echo
    local username
    read_input "Enter username to modify (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    modify_ssh_user "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_show_ssh_user_detail() {
    clear_screen
    local username
    read_input "Enter username" "" username
    [[ -z "${username}" ]] && return

    show_ssh_user_detail "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_ssh_key_management() {
    while true; do
        clear_screen
        print_header "SSH Key Management"
        echo "  1. Generate Key for User"
        echo "  2. Add Public Key for User"
        echo "  3. List User Keys"
        echo "  4. Revoke User Key"
        echo "  0. Back"
        echo

        local choice
        choice="$(read_int "Select option" 0 4)"

        local username
        case "${choice}" in
            1)
                read_input "Username" "" username
                [[ -z "${username}" ]] && continue
                echo "Key types: 1.ed25519  2.rsa  3.ecdsa"
                local ktype
                ktype="$(read_int "Select key type" 1 3 "1")"
                local key_types=("ed25519" "rsa" "ecdsa")
                generate_ssh_key "${username}" "${key_types[$((ktype-1))]}"
                ;;
            2)
                read_input "Username" "" username
                [[ -z "${username}" ]] && continue
                echo -ne "${C_INPUT}Paste public key: ${C_RESET}"
                local pub_key
                read -r pub_key
                add_ssh_authorized_key "${username}" "${pub_key}"
                ;;
            3)
                read_input "Username" "" username
                [[ -z "${username}" ]] && continue
                list_ssh_keys "${username}"
                ;;
            4)
                read_input "Username" "" username
                [[ -z "${username}" ]] && continue
                list_ssh_keys "${username}"
                local idx
                idx="$(read_int "Key number to revoke" 1 100)"
                revoke_ssh_key "${username}" "${idx}"
                ;;
            0) return ;;
        esac
        read -rp $'\nPress Enter to continue...'
    done
}

_menu_terminate_sessions() {
    clear_screen
    print_header "Terminate User Sessions"
    get_all_ssh_sessions

    echo
    local username
    read_input "Enter username to terminate sessions (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    terminate_user_sessions "${username}"
    read -rp $'\nPress Enter to continue...'
}
