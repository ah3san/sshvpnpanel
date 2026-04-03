#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - VPN User Management Module
# =============================================================================
# Handles VPN user creation/deletion, bandwidth allocation, expiration dates,
# user activity logging, online/offline tracking, and connection history.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# VPN USER DATABASE
# =============================================================================

VPN_USER_DB_DIR="${USER_DATA_DIR:-/etc/sshvpnpanel/users}"
VPN_ACTIVITY_LOG="${LOG_DIR:-/var/log/sshvpnpanel}/vpn_activity.log"
VPN_CONNECTIONS_DB="${PANEL_BASE_DIR:-/etc/sshvpnpanel}/vpn_connections.db"

# Initialize VPN user management
init_vpn_management() {
    mkdir -p "${VPN_USER_DB_DIR}" 2>/dev/null
    touch "${VPN_ACTIVITY_LOG}" 2>/dev/null
    touch "${VPN_CONNECTIONS_DB}" 2>/dev/null
}

# Get VPN user config file
vpn_user_file() {
    local username="$1"
    echo "${VPN_USER_DB_DIR}/${username}/vpn.conf"
}

# Check if VPN user exists
vpn_user_exists() {
    local username="$1"
    [[ -f "$(vpn_user_file "${username}")" ]]
}

# =============================================================================
# CREATE VPN USER
# =============================================================================

create_vpn_user() {
    local username="$1"
    local password="$2"
    local expiry_days="${3:-${DEFAULT_VPN_EXPIRY_DAYS:-30}}"
    local bandwidth_limit="${4:-${DEFAULT_BANDWIDTH_LIMIT:-0}}"
    local max_logins="${5:-${MAX_CONNECTIONS_PER_USER:-2}}"
    local protocol="${6:-ssh}"   # ssh, stunnel, both

    require_root || return 1

    validate_username "${username}" || return 1

    if vpn_user_exists "${username}"; then
        print_error "VPN user '${username}' already exists"
        return 1
    fi

    # If SSH user doesn't exist, create it
    if ! id "${username}" &>/dev/null 2>&1; then
        print_info "Creating system account for VPN user ${username}..."
        create_ssh_user "${username}" "${password}" "${expiry_days}" \
            "${bandwidth_limit}" "${max_logins}" || return 1
    fi

    # Calculate expiry
    local expiry_date
    expiry_date="$(calc_expiry_date "${expiry_days}")"

    # Create VPN user data directory and config
    local user_dir="${VPN_USER_DB_DIR}/${username}"
    mkdir -p "${user_dir}" 2>/dev/null
    chmod 700 "${user_dir}" 2>/dev/null

    cat > "$(vpn_user_file "${username}")" << EOF
# VPN User Configuration
USERNAME=${username}
PROTOCOL=${protocol}
CREATED=$(get_timestamp)
EXPIRY_DATE=${expiry_date}
EXPIRY_DAYS=${expiry_days}
BANDWIDTH_LIMIT=${bandwidth_limit}
BANDWIDTH_USED=0
MAX_LOGINS=${max_logins}
STATUS=active
ONLINE=no
LAST_SEEN=never
LAST_IP=none
CONNECTION_COUNT=0
TOTAL_BYTES_IN=0
TOTAL_BYTES_OUT=0
NOTES=
EOF
    chmod 600 "$(vpn_user_file "${username}")"

    # Log activity
    _log_vpn_activity "${username}" "created" "protocol=${protocol},expiry=${expiry_date}"

    print_success "VPN user '${username}' created successfully"
    print_info "  Protocol:   ${protocol}"
    print_info "  Expiry:     ${expiry_date}"
    print_info "  Bandwidth:  $([ "${bandwidth_limit}" -eq 0 ] && echo "unlimited" || echo "${bandwidth_limit} KB/s")"
    print_info "  Max logins: ${max_logins}"

    log_audit "vpn_user_create" "username=${username},protocol=${protocol},expiry=${expiry_date}"
    return 0
}

# =============================================================================
# DELETE VPN USER
# =============================================================================

delete_vpn_user() {
    local username="$1"
    local force="${2:-no}"
    local remove_system="${3:-yes}"  # Also remove system user

    require_root || return 1

    if ! vpn_user_exists "${username}"; then
        print_error "VPN user '${username}' not found"
        return 1
    fi

    if [[ "${force}" != "yes" ]]; then
        confirm "Delete VPN user '${username}'? This cannot be undone" "no" || return 0
    fi

    print_info "Deleting VPN user: ${username}"

    # Terminate active connections
    terminate_vpn_user_connections "${username}" "yes"

    # Remove VPN config
    rm -f "$(vpn_user_file "${username}")"

    # Remove system user if requested
    if [[ "${remove_system}" == "yes" ]]; then
        if id "${username}" &>/dev/null 2>&1; then
            userdel -r "${username}" 2>/dev/null || userdel "${username}" 2>/dev/null
        fi
        rm -rf "${VPN_USER_DB_DIR}/${username}" 2>/dev/null
    fi

    _log_vpn_activity "${username}" "deleted" ""

    print_success "VPN user '${username}' deleted"
    log_audit "vpn_user_delete" "username=${username}"
}

# =============================================================================
# MODIFY VPN USER
# =============================================================================

modify_vpn_user() {
    local username="$1"

    require_root || return 1

    if ! vpn_user_exists "${username}"; then
        print_error "VPN user '${username}' not found"
        return 1
    fi

    local user_file
    user_file="$(vpn_user_file "${username}")"

    clear_screen
    print_header "Modify VPN User: ${username}"

    echo "  1. Change password"
    echo "  2. Change expiry date"
    echo "  3. Change bandwidth limit"
    echo "  4. Change max logins"
    echo "  5. Change protocol"
    echo "  6. Change status (active/suspended)"
    echo "  7. Reset bandwidth counter"
    echo "  8. Update notes"
    echo "  0. Back"
    echo

    local choice
    choice="$(read_int "Select option" 0 8)"

    case "${choice}" in
        1)
            # Delegate to SSH management
            _modify_ssh_password "${username}"
            ;;
        2)
            local days
            days="$(read_int "New expiry in days (0=never)" 0 3650)"
            local expiry_date
            expiry_date="$(calc_expiry_date "${days}")"
            config_set "${user_file}" "EXPIRY_DATE" "${expiry_date}"
            config_set "${user_file}" "EXPIRY_DAYS" "${days}"
            if [[ "${days}" -gt 0 ]]; then
                chage -E "${expiry_date}" "${username}" 2>/dev/null || true
            else
                chage -E -1 "${username}" 2>/dev/null || true
            fi
            print_success "Expiry updated to: ${expiry_date}"
            log_audit "vpn_user_expiry_change" "username=${username},expiry=${expiry_date}"
            ;;
        3)
            local limit
            limit="$(read_int "Bandwidth limit KB/s (0=unlimited)" 0 100000)"
            config_set "${user_file}" "BANDWIDTH_LIMIT" "${limit}"
            print_success "Bandwidth limit updated"
            log_audit "vpn_user_bandwidth_change" "username=${username},limit=${limit}"
            ;;
        4)
            local max
            max="$(read_int "Max simultaneous logins" 1 50)"
            config_set "${user_file}" "MAX_LOGINS" "${max}"
            print_success "Max logins updated"
            ;;
        5)
            echo "  1. SSH only"
            echo "  2. Stunnel only"
            echo "  3. Both"
            local proto_choice
            proto_choice="$(read_int "Select protocol" 1 3)"
            local protocols=("ssh" "stunnel" "both")
            config_set "${user_file}" "PROTOCOL" "${protocols[$((proto_choice-1))]}"
            print_success "Protocol updated"
            ;;
        6)
            local current_status
            current_status="$(config_get "${user_file}" "STATUS" "active")"
            if [[ "${current_status}" == "active" ]]; then
                usermod -L "${username}" 2>/dev/null || true
                config_set "${user_file}" "STATUS" "suspended"
                print_success "User suspended"
            else
                usermod -U "${username}" 2>/dev/null || true
                config_set "${user_file}" "STATUS" "active"
                print_success "User activated"
            fi
            log_audit "vpn_user_status_change" "username=${username},status=$(config_get "${user_file}" "STATUS")"
            ;;
        7)
            config_set "${user_file}" "BANDWIDTH_USED" "0"
            config_set "${user_file}" "TOTAL_BYTES_IN" "0"
            config_set "${user_file}" "TOTAL_BYTES_OUT" "0"
            print_success "Bandwidth counter reset"
            log_audit "vpn_user_bw_reset" "username=${username}"
            ;;
        8)
            local notes
            read_input "Notes" "" notes
            config_set "${user_file}" "NOTES" "${notes}"
            print_success "Notes updated"
            ;;
        0) return 0 ;;
    esac
}

# =============================================================================
# VPN USER LISTING
# =============================================================================

list_vpn_users() {
    clear_screen
    print_header "VPN Users"

    local users=()
    if [[ -d "${VPN_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            local username
            username="$(basename "${user_dir}")"
            [[ -f "$(vpn_user_file "${username}")" ]] && users+=("${username}")
        done < <(find "${VPN_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if [[ ${#users[@]} -eq 0 ]]; then
        print_info "No VPN users found"
        return
    fi

    print_table_header "Username" "Protocol" "Status" "Expiry" "BW Used" "Online"

    for username in "${users[@]}"; do
        local user_file
        user_file="$(vpn_user_file "${username}")"

        local protocol
        protocol="$(config_get "${user_file}" "PROTOCOL" "ssh")"
        local status
        status="$(config_get "${user_file}" "STATUS" "active")"
        local expiry
        expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"
        local bw_used
        bw_used="$(config_get "${user_file}" "BANDWIDTH_USED" "0")"
        local bw_limit
        bw_limit="$(config_get "${user_file}" "BANDWIDTH_LIMIT" "0")"
        local online
        online="$(config_get "${user_file}" "ONLINE" "no")"

        # Auto-detect online status
        if get_user_ssh_sessions "${username}" 2>/dev/null | grep -q "."; then
            online="yes"
            config_set "${user_file}" "ONLINE" "yes"
        fi

        local status_color="${C_SUCCESS}"
        is_expired "${expiry}" 2>/dev/null && { status="${C_ERROR}expired${C_RESET}"; status_color="${C_ERROR}"; }
        [[ "${status}" == "suspended" ]] && status_color="${C_WARNING}"

        local bw_display
        bw_display="$(bytes_to_human "${bw_used}")"
        [[ "${bw_limit}" -gt 0 ]] && bw_display+="/$(bytes_to_human $((bw_limit * 1024)))"

        local online_color="${C_DIM}"
        [[ "${online}" == "yes" ]] && online_color="${C_SUCCESS}"

        printf "  ${C_BOLD}%-18s${C_RESET} %-10s ${status_color}%-12s${C_RESET} %-14s %-12s ${online_color}%s${C_RESET}\n" \
            "${username}" "${protocol}" "${status}" "${expiry}" \
            "${bw_display}" "$([ "${online}" == "yes" ] && echo "●" || echo "○")"
    done

    echo
    print_info "Total VPN users: ${#users[@]}"
    local online_count=0
    for username in "${users[@]}"; do
        local user_file
        user_file="$(vpn_user_file "${username}")"
        [[ "$(config_get "${user_file}" "ONLINE" "no")" == "yes" ]] && (( online_count++ ))
    done
    print_info "Online: ${online_count}"
}

show_vpn_user_detail() {
    local username="$1"

    if ! vpn_user_exists "${username}"; then
        print_error "VPN user '${username}' not found"
        return 1
    fi

    local user_file
    user_file="$(vpn_user_file "${username}")"

    clear_screen
    print_header "VPN User Detail: ${username}"

    echo -e "\n${C_BOLD}Account Information${C_RESET}"
    print_separator 40

    local keys=(USERNAME PROTOCOL STATUS CREATED EXPIRY_DATE
                MAX_LOGINS LAST_SEEN LAST_IP CONNECTION_COUNT NOTES)
    local labels=("Username" "Protocol" "Status" "Created" "Expiry Date"
                  "Max Logins" "Last Seen" "Last IP" "Connection Count" "Notes")

    for i in "${!keys[@]}"; do
        local val
        val="$(config_get "${user_file}" "${keys[${i}]}" "N/A")"
        printf "  ${C_BOLD}%-24s${C_RESET} %s\n" "${labels[${i}]}:" "${val}"
    done

    echo -e "\n${C_BOLD}Days Until Expiry${C_RESET}"
    print_separator 40
    local expiry
    expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"
    local days_left
    days_left="$(days_until_expiry "${expiry}")"
    local days_color="${C_SUCCESS}"
    if [[ "${days_left}" =~ ^-?[0-9]+$ ]]; then
        [[ "${days_left}" -lt 7 ]] && days_color="${C_WARNING}"
        [[ "${days_left}" -lt 0 ]] && days_color="${C_ERROR}"
    fi
    printf "  ${days_color}%s days${C_RESET}\n" "${days_left}"

    echo -e "\n${C_BOLD}Bandwidth Usage${C_RESET}"
    print_separator 40
    local bw_used
    bw_used="$(config_get "${user_file}" "BANDWIDTH_USED" "0")"
    local bw_limit
    bw_limit="$(config_get "${user_file}" "BANDWIDTH_LIMIT" "0")"
    local bytes_in
    bytes_in="$(config_get "${user_file}" "TOTAL_BYTES_IN" "0")"
    local bytes_out
    bytes_out="$(config_get "${user_file}" "TOTAL_BYTES_OUT" "0")"

    printf "  ${C_BOLD}%-24s${C_RESET} %s\n" "Used:" "$(bytes_to_human "${bw_used}")"
    printf "  ${C_BOLD}%-24s${C_RESET} %s\n" "Limit:" \
        "$([ "${bw_limit}" -eq 0 ] && echo "unlimited" || echo "$(bytes_to_human $((bw_limit * 1024)))")"
    printf "  ${C_BOLD}%-24s${C_RESET} %s\n" "Data In:" "$(bytes_to_human "${bytes_in}")"
    printf "  ${C_BOLD}%-24s${C_RESET} %s\n" "Data Out:" "$(bytes_to_human "${bytes_out}")"

    if [[ "${bw_limit}" -gt 0 ]]; then
        local bw_pct=$(( bw_used * 100 / (bw_limit * 1024) ))
        [[ "${bw_pct}" -gt 100 ]] && bw_pct=100
        echo -ne "  "
        print_progress "${bw_pct}" 100 30
    fi

    echo -e "\n${C_BOLD}Active Sessions${C_RESET}"
    print_separator 40
    local sessions
    sessions="$(get_user_ssh_sessions "${username}" 2>/dev/null)"
    if [[ -n "${sessions}" ]]; then
        echo "${sessions}" | while IFS= read -r line; do
            echo "  ${line}"
        done
    else
        echo "  No active sessions"
    fi
}

# =============================================================================
# CONNECTION TRACKING
# =============================================================================

log_vpn_connection() {
    local username="$1"
    local action="${2:-connect}"    # connect/disconnect
    local ip="${3:-unknown}"
    local protocol="${4:-ssh}"

    local user_file
    user_file="$(vpn_user_file "${username}")"
    [[ -f "${user_file}" ]] || return

    local timestamp
    timestamp="$(get_timestamp)"

    if [[ "${action}" == "connect" ]]; then
        config_set "${user_file}" "ONLINE" "yes"
        config_set "${user_file}" "LAST_SEEN" "${timestamp}"
        config_set "${user_file}" "LAST_IP" "${ip}"
        local conn_count
        conn_count="$(config_get "${user_file}" "CONNECTION_COUNT" "0")"
        config_set "${user_file}" "CONNECTION_COUNT" "$((conn_count + 1))"
    else
        config_set "${user_file}" "ONLINE" "no"
        config_set "${user_file}" "LAST_SEEN" "${timestamp}"
    fi

    # Log to activity file
    _log_vpn_activity "${username}" "${action}" "ip=${ip},protocol=${protocol}"

    # Log to connections database
    echo "${timestamp}|${username}|${action}|${ip}|${protocol}" \
        >> "${VPN_CONNECTIONS_DB}" 2>/dev/null
}

_log_vpn_activity() {
    local username="$1"
    local action="$2"
    local detail="${3:-}"
    local timestamp
    timestamp="$(get_timestamp)"
    echo "[${timestamp}] [${action}] user=${username} ${detail}" \
        >> "${VPN_ACTIVITY_LOG}" 2>/dev/null
}

terminate_vpn_user_connections() {
    local username="$1"
    local force="${2:-no}"

    require_root || return 1

    if ! vpn_user_exists "${username}"; then
        print_error "VPN user '${username}' not found"
        return 1
    fi

    local session_count
    session_count="$(get_user_ssh_sessions "${username}" 2>/dev/null | wc -l)"

    if [[ "${session_count}" -eq 0 ]]; then
        print_info "No active sessions for ${username}"
        return 0
    fi

    if [[ "${force}" != "yes" ]]; then
        confirm "Terminate all ${session_count} sessions for '${username}'?" "no" || return 0
    fi

    pkill -u "${username}" -TERM 2>/dev/null || true
    sleep 1
    pkill -u "${username}" -KILL 2>/dev/null || true

    log_vpn_connection "${username}" "disconnect" "forced" "admin"
    print_success "Terminated ${session_count} sessions for ${username}"
    log_audit "vpn_sessions_terminate" "username=${username},count=${session_count}"
}

# =============================================================================
# BANDWIDTH MONITORING
# =============================================================================

update_user_bandwidth() {
    local username="$1"
    local bytes_in="${2:-0}"
    local bytes_out="${3:-0}"

    local user_file
    user_file="$(vpn_user_file "${username}")"
    [[ -f "${user_file}" ]] || return

    # Update totals
    local current_in
    current_in="$(config_get "${user_file}" "TOTAL_BYTES_IN" "0")"
    local current_out
    current_out="$(config_get "${user_file}" "TOTAL_BYTES_OUT" "0")"
    local current_used
    current_used="$(config_get "${user_file}" "BANDWIDTH_USED" "0")"

    config_set "${user_file}" "TOTAL_BYTES_IN" "$((current_in + bytes_in))"
    config_set "${user_file}" "TOTAL_BYTES_OUT" "$((current_out + bytes_out))"
    config_set "${user_file}" "BANDWIDTH_USED" \
        "$((current_used + bytes_in + bytes_out))"

    # Check bandwidth limit
    local bw_limit
    bw_limit="$(config_get "${user_file}" "BANDWIDTH_LIMIT" "0")"
    if [[ "${bw_limit}" -gt 0 ]]; then
        local total_used
        total_used="$(config_get "${user_file}" "BANDWIDTH_USED" "0")"
        local limit_bytes=$(( bw_limit * 1024 * 1024 ))  # Convert MB to bytes
        if [[ "${total_used}" -ge "${limit_bytes}" ]]; then
            print_warning "User ${username} has exceeded bandwidth limit"
            log_audit "vpn_bw_exceeded" "username=${username},used=${total_used},limit=${limit_bytes}"
            # Suspend user
            usermod -L "${username}" 2>/dev/null || true
            config_set "${user_file}" "STATUS" "suspended"
        fi
    fi
}

# =============================================================================
# ONLINE STATUS TRACKING
# =============================================================================

update_online_status() {
    if [[ ! -d "${VPN_USER_DB_DIR}" ]]; then return; fi

    while IFS= read -r -d '' user_dir; do
        local username
        username="$(basename "${user_dir}")"
        local user_file
        user_file="$(vpn_user_file "${username}")"
        [[ -f "${user_file}" ]] || continue

        local was_online
        was_online="$(config_get "${user_file}" "ONLINE" "no")"
        local is_online="no"

        # Check if user has active SSH session
        if get_user_ssh_sessions "${username}" 2>/dev/null | grep -q "."; then
            is_online="yes"
        fi

        # Update status if changed
        if [[ "${was_online}" != "${is_online}" ]]; then
            config_set "${user_file}" "ONLINE" "${is_online}"
            if [[ "${is_online}" == "yes" ]]; then
                config_set "${user_file}" "LAST_SEEN" "$(get_timestamp)"
                _log_vpn_activity "${username}" "connect" "detected"
            else
                _log_vpn_activity "${username}" "disconnect" "session-ended"
            fi
        fi
    done < <(find "${VPN_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

show_online_users() {
    clear_screen
    print_header "Online VPN Users"

    update_online_status

    local online_count=0
    local users=()

    if [[ -d "${VPN_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            local username
            username="$(basename "${user_dir}")"
            local user_file
            user_file="$(vpn_user_file "${username}")"
            [[ -f "${user_file}" ]] || continue

            if [[ "$(config_get "${user_file}" "ONLINE" "no")" == "yes" ]]; then
                users+=("${username}")
                (( online_count++ ))
            fi
        done < <(find "${VPN_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    if [[ "${online_count}" -eq 0 ]]; then
        print_info "No users currently online"
        return
    fi

    print_table_header "Username" "Protocol" "Last IP" "Last Seen" "Sessions"

    for username in "${users[@]}"; do
        local user_file
        user_file="$(vpn_user_file "${username}")"
        local protocol
        protocol="$(config_get "${user_file}" "PROTOCOL" "ssh")"
        local last_ip
        last_ip="$(config_get "${user_file}" "LAST_IP" "unknown")"
        local last_seen
        last_seen="$(config_get "${user_file}" "LAST_SEEN" "never")"
        local sessions
        sessions="$(get_user_ssh_sessions "${username}" 2>/dev/null | wc -l)"

        printf "  ${C_SUCCESS}●${C_RESET} ${C_BOLD}%-18s${C_RESET} %-10s %-18s %-20s %s\n" \
            "${username}" "${protocol}" "${last_ip}" "${last_seen}" "${sessions}"
    done

    echo
    print_info "Online users: ${online_count}"
}

# =============================================================================
# CONNECTION HISTORY
# =============================================================================

show_connection_history() {
    local username="${1:-}"
    local lines="${2:-50}"

    clear_screen
    print_header "VPN Connection History"

    if [[ ! -f "${VPN_CONNECTIONS_DB}" ]]; then
        print_info "No connection history available"
        return
    fi

    local filter_cmd
    if [[ -n "${username}" ]]; then
        filter_cmd="grep \"|${username}|\""
        print_info "Showing history for user: ${username}"
    else
        filter_cmd="cat"
    fi

    print_table_header "Timestamp" "User" "Action" "IP" "Protocol"

    tail -"${lines}" "${VPN_CONNECTIONS_DB}" | eval "${filter_cmd}" 2>/dev/null | \
    while IFS='|' read -r ts user action ip proto; do
        local color="${C_DIM}"
        [[ "${action}" == "connect" ]] && color="${C_SUCCESS}"
        [[ "${action}" == "disconnect" ]] && color="${C_INFO}"

        printf "  %-22s %-16s ${color}%-14s${C_RESET} %-18s %s\n" \
            "${ts}" "${user}" "${action}" "${ip}" "${proto}"
    done
}

# =============================================================================
# USER ACTIVITY REPORT
# =============================================================================

generate_user_report() {
    local username="${1:-}"
    local period="${2:-daily}"

    clear_screen
    print_header "VPN User Activity Report"
    print_info "Period: ${period}"
    [[ -n "${username}" ]] && print_info "User: ${username}"
    echo

    local date_filter
    case "${period}" in
        daily)  date_filter="$(date '+%Y-%m-%d')" ;;
        weekly) date_filter="$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m')" ;;
        monthly) date_filter="$(date '+%Y-%m')" ;;
        *) date_filter="" ;;
    esac

    if [[ -f "${VPN_ACTIVITY_LOG}" ]]; then
        local entries
        if [[ -n "${date_filter}" ]]; then
            entries="$(grep "${date_filter}" "${VPN_ACTIVITY_LOG}" 2>/dev/null)"
        else
            entries="$(cat "${VPN_ACTIVITY_LOG}")"
        fi

        if [[ -n "${username}" ]]; then
            entries="$(echo "${entries}" | grep "user=${username}")"
        fi

        local total_events
        total_events="$(echo "${entries}" | grep -c "." 2>/dev/null || echo "0")"
        local creates
        creates="$(echo "${entries}" | grep -c "\[created\]" || echo "0")"
        local connects
        connects="$(echo "${entries}" | grep -c "\[connect\]" || echo "0")"
        local disconnects
        disconnects="$(echo "${entries}" | grep -c "\[disconnect\]" || echo "0")"

        printf "  %-28s %s\n" "Total Events:" "${total_events}"
        printf "  %-28s %s\n" "Connections:" "${connects}"
        printf "  %-28s %s\n" "Disconnections:" "${disconnects}"
        printf "  %-28s %s\n" "User Created:" "${creates}"

        echo -e "\n${C_BOLD}Recent Activity:${C_RESET}"
        print_separator 60
        echo "${entries}" | tail -20 | while IFS= read -r line; do
            echo "  ${line}"
        done
    else
        print_info "No activity log found"
    fi
}

# =============================================================================
# CLEANUP EXPIRED VPN USERS
# =============================================================================

cleanup_expired_vpn_users() {
    require_root || return 1
    print_info "Checking for expired VPN users..."

    local users=()
    if [[ -d "${VPN_USER_DB_DIR}" ]]; then
        while IFS= read -r -d '' user_dir; do
            users+=("$(basename "${user_dir}")")
        done < <(find "${VPN_USER_DB_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    local cleaned=0
    for username in "${users[@]}"; do
        local user_file
        user_file="$(vpn_user_file "${username}")"
        [[ -f "${user_file}" ]] || continue

        local expiry
        expiry="$(config_get "${user_file}" "EXPIRY_DATE" "never")"

        if is_expired "${expiry}" 2>/dev/null; then
            print_warning "Expired VPN user: ${username} (expired: ${expiry})"
            if [[ "${AUTO_CLEANUP_EXPIRED:-yes}" == "yes" ]]; then
                delete_vpn_user "${username}" "yes" "yes"
                (( cleaned++ ))
            else
                # Just suspend
                config_set "${user_file}" "STATUS" "expired"
                usermod -L "${username}" 2>/dev/null || true
                terminate_vpn_user_connections "${username}" "yes"
            fi
        fi
    done

    print_success "Cleanup complete. Processed ${cleaned} expired users."
}

# =============================================================================
# VPN MANAGEMENT MENU
# =============================================================================

vpn_management_menu() {
    while true; do
        clear_screen
        print_header "VPN User Management"

        echo -e "${C_BOLD}User Management:${C_RESET}"
        echo "  1. Create VPN User"
        echo "  2. Delete VPN User"
        echo "  3. Modify VPN User"
        echo "  4. List VPN Users"
        echo "  5. User Details"
        echo
        echo -e "${C_BOLD}Monitoring:${C_RESET}"
        echo "  6. Online Users"
        echo "  7. Active Connections"
        echo "  8. Connection History"
        echo "  9. User Activity Report"
        echo
        echo -e "${C_BOLD}Management:${C_RESET}"
        echo " 10. Terminate User Connections"
        echo " 11. Reset User Bandwidth"
        echo " 12. Cleanup Expired Users"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 12)"

        case "${choice}" in
            1) _menu_create_vpn_user ;;
            2) _menu_delete_vpn_user ;;
            3) _menu_modify_vpn_user ;;
            4) list_vpn_users; read -rp $'\nPress Enter to continue...' ;;
            5) _menu_vpn_user_detail ;;
            6) show_online_users; read -rp $'\nPress Enter to continue...' ;;
            7) get_all_ssh_sessions 2>/dev/null; read -rp $'\nPress Enter to continue...' ;;
            8) _menu_connection_history ;;
            9) _menu_activity_report ;;
            10) _menu_terminate_vpn_connections ;;
            11) _menu_reset_bandwidth ;;
            12) cleanup_expired_vpn_users; read -rp $'\nPress Enter to continue...' ;;
            0) return 0 ;;
        esac
    done
}

_menu_create_vpn_user() {
    clear_screen
    print_header "Create VPN User"

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
        if [[ "${password}" == "${confirm_pass}" ]]; then
            validate_password "${password}" && break
        else
            print_error "Passwords do not match"
        fi
    done

    echo "Protocol: 1.SSH only  2.Stunnel only  3.Both"
    local proto_choice
    proto_choice="$(read_int "Select protocol" 1 3 "3")"
    local protocols=("ssh" "stunnel" "both")
    local protocol="${protocols[$((proto_choice-1))]}"

    local expiry_days
    expiry_days="$(read_int "Expiry in days (0=never)" 0 3650 "${DEFAULT_VPN_EXPIRY_DAYS:-30}")"
    local bandwidth
    bandwidth="$(read_int "Bandwidth limit KB/s (0=unlimited)" 0 100000 "0")"
    local max_logins
    max_logins="$(read_int "Max simultaneous logins" 1 50 "${MAX_CONNECTIONS_PER_USER:-2}")"

    echo
    create_vpn_user "${username}" "${password}" "${expiry_days}" "${bandwidth}" \
        "${max_logins}" "${protocol}"
    read -rp $'\nPress Enter to continue...'
}

_menu_delete_vpn_user() {
    clear_screen
    print_header "Delete VPN User"
    list_vpn_users

    echo
    local username
    read_input "Enter username to delete (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    delete_vpn_user "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_modify_vpn_user() {
    clear_screen
    list_vpn_users
    echo
    local username
    read_input "Enter username to modify (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    modify_vpn_user "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_vpn_user_detail() {
    local username
    read_input "Enter username" "" username
    [[ -z "${username}" ]] && return
    show_vpn_user_detail "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_connection_history() {
    clear_screen
    local username
    read_input "Username filter (empty for all)" "" username
    local lines
    lines="$(read_int "Lines to show" 1 1000 "50")"
    show_connection_history "${username}" "${lines}"
    read -rp $'\nPress Enter to continue...'
}

_menu_activity_report() {
    clear_screen
    local username
    read_input "Username filter (empty for all)" "" username

    echo "Period: 1.Daily  2.Weekly  3.Monthly  4.All"
    local period_choice
    period_choice="$(read_int "Select period" 1 4 "1")"
    local periods=("daily" "weekly" "monthly" "all")

    generate_user_report "${username}" "${periods[$((period_choice-1))]}"
    read -rp $'\nPress Enter to continue...'
}

_menu_terminate_vpn_connections() {
    show_online_users
    echo
    local username
    read_input "Username to terminate (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return
    terminate_vpn_user_connections "${username}"
    read -rp $'\nPress Enter to continue...'
}

_menu_reset_bandwidth() {
    list_vpn_users
    echo
    local username
    read_input "Username to reset bandwidth (or 'cancel')" "" username
    [[ "${username}" == "cancel" || -z "${username}" ]] && return

    if vpn_user_exists "${username}"; then
        local user_file
        user_file="$(vpn_user_file "${username}")"
        config_set "${user_file}" "BANDWIDTH_USED" "0"
        config_set "${user_file}" "TOTAL_BYTES_IN" "0"
        config_set "${user_file}" "TOTAL_BYTES_OUT" "0"
        print_success "Bandwidth reset for ${username}"
        log_audit "vpn_bw_reset" "username=${username}"
    else
        print_error "VPN user not found"
    fi
    read -rp $'\nPress Enter to continue...'
}
