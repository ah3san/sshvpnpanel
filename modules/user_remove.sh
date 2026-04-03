#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - User Remove Module
# Comprehensive user removal with full service cleanup:
#   SSH account, Stunnel tunnel, TLS/SNI certs, firewall rules,
#   VPN profile, monitoring teardown, archival, audit report
################################################################################

[[ -n "${_USER_REMOVE_LOADED:-}" ]] && return 0
_USER_REMOVE_LOADED=1

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
# Single user remove
# ---------------------------------------------------------------------------

# Remove a user and clean up all associated service configurations
# Usage: user_remove USERNAME [options...]
#
# Options (environment variables):
#   PRESERVE_DATA   - archive user data instead of deleting (default: true)
#   SEND_REMOVAL_NOTIFICATION - send removal email (default: false)
#   USER_EMAIL      - email address for notifications
#   GENERATE_REPORT - generate final audit report (default: true)
user_remove() {
    local username="$1"

    check_root || return 1
    validate_username "$username" || return 1

    # Options
    local preserve_data="${PRESERVE_DATA:-true}"
    local send_notification="${SEND_REMOVAL_NOTIFICATION:-false}"
    local user_email="${USER_EMAIL:-}"
    local generate_report="${GENERATE_REPORT:-true}"

    # Check the user exists in at least one service
    local exists_in_system exists_in_stunnel exists_in_vpn
    exists_in_system="$(user_exists "$username" && echo true || echo false)"
    exists_in_stunnel="$([[ -f "${STUNNEL_CONFIG_DIR:-/etc/stunnel}/users/${username}.conf" ]] && echo true || echo false)"
    exists_in_vpn="$([[ -d "${VPN_CONFIG_DIR:-/etc/sshvpnpanel/vpn}/${username}" ]] && echo true || echo false)"

    if [[ "$exists_in_system" == "false" && "$exists_in_stunnel" == "false" && "$exists_in_vpn" == "false" ]]; then
        print_error "User '${username}' not found in any service."
        return 1
    fi

    print_header "Removing User: ${username}"

    local step=1
    local errors=0

    # ------------------------------------------------------------------ Step 1: Archive data
    if [[ "$preserve_data" == "true" ]]; then
        print_step "$((step++))" "Archiving user data..."
        _user_archive_all "$username" || {
            log_warn "Archival had errors; continuing removal..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 2: Kill sessions
    print_step "$((step++))" "Terminating active sessions..."
    _user_kill_sessions "$username"

    # ------------------------------------------------------------------ Step 3: SSH account removal
    if [[ "$exists_in_system" == "true" ]]; then
        print_step "$((step++))" "Removing SSH system account..."
        ssh_delete_user "$username" "$([[ "$preserve_data" == "true" ]] && echo "true" || echo "false")" || {
            log_warn "SSH account removal had errors; continuing..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 4: SSH config cleanup
    print_step "$((step++))" "Cleaning SSH configuration entries..."
    ssh_remove_user_config "$username" || ((errors++))
    ssh_revoke_keys "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 5: Stunnel removal
    print_step "$((step++))" "Removing Stunnel tunnel configuration..."
    stunnel_remove_user "$username" || {
        log_warn "Stunnel removal had errors; continuing..."
        ((errors++))
    }

    # ------------------------------------------------------------------ Step 6: TLS certificate revocation
    print_step "$((step++))" "Revoking TLS certificate..."
    tls_revoke_cert "$username" || {
        log_warn "TLS cert revocation had errors; continuing..."
        ((errors++))
    }

    # ------------------------------------------------------------------ Step 7: SNI domains removal
    print_step "$((step++))" "Removing SNI domain assignments..."
    sni_remove_user "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 8: Firewall rules
    print_step "$((step++))" "Removing firewall rules..."
    firewall_remove_user "$username" || ((errors++))
    firewall_remove_rate_limit "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 9: Fail2ban jail
    print_step "$((step++))" "Removing fail2ban configuration..."
    fail2ban_remove_user_jail "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 10: VPN profile
    if [[ "$exists_in_vpn" == "true" ]]; then
        print_step "$((step++))" "Removing VPN profile..."
        vpn_remove_user "$username" "false" || {
            log_warn "VPN profile removal had errors; continuing..."
            ((errors++))
        }
    fi

    # ------------------------------------------------------------------ Step 11: Monitoring teardown
    print_step "$((step++))" "Removing monitoring and log configuration..."
    monitoring_remove_user "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 12: Panel data cleanup
    print_step "$((step++))" "Cleaning up panel data..."
    _user_cleanup_panel_data "$username" || ((errors++))

    # ------------------------------------------------------------------ Step 13: Removal notification
    if [[ "$send_notification" == "true" && -n "$user_email" ]]; then
        print_step "$((step++))" "Sending removal notification to ${user_email}..."
        _user_send_removal_email "$username" "$user_email" || ((errors++))
    fi

    # ------------------------------------------------------------------ Step 14: Final audit report
    if [[ "$generate_report" == "true" ]]; then
        print_step "$((step++))" "Generating final audit report..."
        _user_generate_audit_report "$username" || ((errors++))
    fi

    # ------------------------------------------------------------------ Final audit log
    log_audit "USER_REMOVED" "$username" \
        "preserved=${preserve_data} errors=${errors}"

    echo ""
    print_header "User Remove Summary: ${username}"
    print_table_row "User" "$username"
    print_table_row "Data Preserved" "$preserve_data"
    print_table_row "SSH Account" "removed"
    print_table_row "SSH Keys" "revoked"
    print_table_row "Stunnel Tunnel" "removed"
    print_table_row "TLS Certificate" "revoked"
    print_table_row "SNI Domains" "removed"
    print_table_row "Firewall Rules" "removed"
    print_table_row "VPN Profile" "removed"
    print_table_row "Monitoring" "removed"
    if [[ "$preserve_data" == "true" ]]; then
        print_table_row "Archive Location" "${ARCHIVE_DIR:-/var/backups/sshvpnpanel/archived_users}/${username}"
    fi

    if [[ "$errors" -gt 0 ]]; then
        print_warning "User removed with ${errors} non-fatal error(s). Review logs for details."
    else
        print_success "User '${username}' fully removed and all services cleaned up."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Interactive user remove
# ---------------------------------------------------------------------------

user_remove_interactive() {
    print_header "Interactive User Remove"
    check_root || return 1

    local username
    prompt_input username "Username to remove"
    validate_username "$username" || return 1

    if ! user_exists "$username"; then
        local stunnel_conf="${STUNNEL_CONFIG_DIR:-/etc/stunnel}/users/${username}.conf"
        local vpn_dir="${VPN_CONFIG_DIR:-/etc/sshvpnpanel/vpn}/${username}"
        if [[ ! -f "$stunnel_conf" && ! -d "$vpn_dir" ]]; then
            print_error "User '${username}' not found in any service."
            return 1
        fi
    fi

    # Confirm
    if ! prompt_confirm "Are you sure you want to remove user '${username}'?" "n"; then
        print_info "User removal cancelled."
        return 0
    fi

    local preserve_data="true"
    local send_notification="false"
    local user_email=""

    if prompt_confirm "Preserve/archive user data?" "y"; then
        preserve_data=true
    else
        preserve_data=false
        if ! prompt_confirm "WARNING: All data will be permanently deleted. Continue?" "n"; then
            print_info "User removal cancelled."
            return 0
        fi
    fi

    if prompt_confirm "Send removal notification email?" "n"; then
        send_notification=true
        prompt_input user_email "User's email address" ""
    fi

    PRESERVE_DATA="$preserve_data" \
    SEND_REMOVAL_NOTIFICATION="$send_notification" \
    USER_EMAIL="$user_email" \
    GENERATE_REPORT="true" \
        user_remove "$username"
}

# ---------------------------------------------------------------------------
# Batch user remove
# ---------------------------------------------------------------------------

# Remove multiple users listed in a file (one username per line)
# Usage: user_remove_batch /path/to/userlist.txt [preserve_data=true]
user_remove_batch() {
    local list_file="$1"
    local preserve_data="${2:-true}"

    if [[ ! -f "$list_file" ]]; then
        log_error "User list file not found: ${list_file}"
        return 1
    fi

    check_root || return 1
    print_header "Batch User Remove"

    local success=0 failure=0 total=0

    while IFS= read -r username; do
        # Skip comments and blank lines
        [[ "$username" == \#* || -z "$username" ]] && continue
        username="${username// /}"
        ((total++))

        PRESERVE_DATA="$preserve_data" \
        GENERATE_REPORT="false" \
            user_remove "$username"

        if [[ $? -eq 0 ]]; then
            ((success++))
        else
            ((failure++))
            log_error "Failed to remove user: ${username}"
        fi
    done < "$list_file"

    echo ""
    print_section "Batch Remove Results"
    print_table_row "Total" "$total"
    print_table_row "Success" "$success"
    print_table_row "Failed" "$failure"

    log_audit "BATCH_USER_REMOVE" "SYSTEM" \
        "file=${list_file} total=${total} success=${success} failed=${failure}"
    return "$([[ "$failure" -eq 0 ]] && echo 0 || echo 1)"
}

# ---------------------------------------------------------------------------
# User suspension / reactivation
# ---------------------------------------------------------------------------

# Suspend a user (lock account and disable services without removing data)
user_suspend() {
    local username="$1"
    local reason="${2:-administrative action}"

    check_root || return 1

    if ! user_exists "$username"; then
        log_error "User '${username}' does not exist."
        return 1
    fi

    log_info "Suspending user: ${username}"

    # Lock the system account
    passwd -l "$username" 2>/dev/null || usermod -L "$username" 2>/dev/null || \
        log_warn "Could not lock account for ${username}"

    # Kill active sessions
    _user_kill_sessions "$username"

    # Update VPN profile status
    vpn_set_status "$username" "suspended" || true

    # Block firewall (comment-based removal without whitelist entry removal)
    if firewall_is_iptables 2>/dev/null; then
        iptables -I INPUT -m comment --comment "sshvpnpanel:block:${username}" \
            -m owner --uid-owner "$(id -u "$username" 2>/dev/null)" -j DROP 2>/dev/null || true
    fi

    log_audit "USER_SUSPENDED" "$username" "reason=${reason}"
    print_success "User '${username}' suspended."
    return 0
}

# Reactivate a previously suspended user
user_reactivate() {
    local username="$1"

    check_root || return 1

    if ! user_exists "$username"; then
        log_error "User '${username}' does not exist."
        return 1
    fi

    log_info "Reactivating user: ${username}"

    # Unlock the system account
    passwd -u "$username" 2>/dev/null || usermod -U "$username" 2>/dev/null || \
        log_warn "Could not unlock account for ${username}"

    # Update VPN profile status
    vpn_set_status "$username" "active" || true

    # Remove any blocking firewall rules
    if firewall_is_iptables 2>/dev/null; then
        while iptables -D INPUT -m comment \
                --comment "sshvpnpanel:block:${username}" -j DROP 2>/dev/null; do
            true
        done
    fi

    log_audit "USER_REACTIVATED" "$username"
    print_success "User '${username}' reactivated."
    return 0
}

# ---------------------------------------------------------------------------
# User export
# ---------------------------------------------------------------------------

# Export user list to CSV
# Usage: user_export_csv [output_file]
user_export_csv() {
    local output_file="${1:-/tmp/sshvpnpanel_users_$(date '+%Y%m%d_%H%M%S').csv}"
    local group="${USER_DEFAULT_GROUP:-sshvpn}"

    print_info "Exporting user list to: ${output_file}"

    echo "username,uid,home,shell,expires,stunnel_port,stunnel_domain,vpn_status,vpn_quota_mb,vpn_expires" \
        > "$output_file"

    local members
    members="$(getent group "$group" 2>/dev/null | cut -d: -f4 | tr ',' '\n')"

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local uid home shell expire stunnel_port stunnel_domain vpn_status vpn_quota vpn_exp
        uid="$(id -u "$user" 2>/dev/null || echo '')"
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || echo '')"
        shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || echo '')"
        expire="$(chage -l "$user" 2>/dev/null | grep 'Account expires' | cut -d: -f2 | xargs || echo 'never')"
        stunnel_port="$(stunnel_get_user_port "$user" 2>/dev/null || echo '')"
        stunnel_domain="$(grep 'STUNNEL_DOMAIN=' "${PANEL_DATA_DIR}/users/${user}/stunnel.conf" 2>/dev/null | cut -d= -f2 || echo '')"
        vpn_status="$(grep 'VPN_STATUS=' "${VPN_CONFIG_DIR}/${user}/profile.conf" 2>/dev/null | cut -d= -f2 || echo '')"
        vpn_quota="$(grep 'VPN_QUOTA_MB=' "${VPN_CONFIG_DIR}/${user}/profile.conf" 2>/dev/null | cut -d= -f2 || echo '')"
        vpn_exp="$(grep 'VPN_EXPIRE_DATE=' "${VPN_CONFIG_DIR}/${user}/profile.conf" 2>/dev/null | cut -d= -f2 || echo '')"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$user" "$uid" "$home" "$shell" "$expire" \
            "$stunnel_port" "$stunnel_domain" "$vpn_status" "$vpn_quota" "$vpn_exp" \
            >> "$output_file"
    done <<< "$members"

    print_success "User list exported to: ${output_file}"
    log_audit "USERS_EXPORTED" "SYSTEM" "file=${output_file}"
    echo "$output_file"
}

# ---------------------------------------------------------------------------
# User information display
# ---------------------------------------------------------------------------

user_info() {
    local username="$1"
    print_header "User Information: ${username}"

    # SSH info
    ssh_user_info "$username" 2>/dev/null || print_warning "No SSH account found."

    # Stunnel info
    stunnel_user_info "$username" 2>/dev/null

    # TLS info
    tls_user_info "$username" 2>/dev/null

    # VPN info
    vpn_user_info "$username" 2>/dev/null

    # Bandwidth report
    monitoring_user_bandwidth "$username" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Kill all active sessions for a user
_user_kill_sessions() {
    local username="$1"
    local pids
    pids="$(pgrep -u "$username" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        log_info "Killing sessions for user '${username}' (PIDs: ${pids})..."
        # shellcheck disable=SC2086
        kill -15 $pids 2>/dev/null || true
        sleep 1
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
}

# Archive all user data before removal
_user_archive_all() {
    local username="$1"
    local archive_base="${ARCHIVE_DIR:-/var/backups/sshvpnpanel/archived_users}/${username}"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"

    ensure_dir "$archive_base" 700 root

    # Archive home directory
    local home_dir
    home_dir="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || echo "/home/${username}")"
    if [[ -d "$home_dir" ]]; then
        local archive_file="${archive_base}/home_${ts}.tar.gz"
        tar -czf "$archive_file" -C "$(dirname "$home_dir")" "$(basename "$home_dir")" 2>/dev/null || \
            log_warn "Could not archive home directory for ${username}"
        log_info "Home directory archived: ${archive_file}"
    fi

    # Archive VPN data
    vpn_archive_user "$username" 2>/dev/null || true

    # Archive bandwidth logs (done by monitoring_remove_user)
    log_audit "USER_DATA_ARCHIVED" "$username" "location=${archive_base}"
    return 0
}

# Clean up panel-specific data for a user
_user_cleanup_panel_data() {
    local username="$1"
    local user_data_dir="${PANEL_DATA_DIR}/users/${username}"

    if [[ -d "$user_data_dir" ]]; then
        rm -rf "$user_data_dir"
        log_info "Removed panel data directory: ${user_data_dir}"
    fi
    return 0
}

# Send removal notification email
_user_send_removal_email() {
    local username="$1"
    local email="$2"

    validate_email "$email" || return 1

    local subject="SSH VPN Panel Account Removed"
    local body
    body="$(cat << EOF
Your SSH VPN Panel account has been removed.

  Username  : ${username}
  Removed   : $(date '+%Y-%m-%d %H:%M:%S')

If you believe this was done in error, please contact your administrator.

This is an automated message from SSH VPN Panel.
EOF
)"
    send_email "$email" "$subject" "$body"
}

# Generate a final audit report for a removed user
_user_generate_audit_report() {
    local username="$1"
    local report_dir="${ARCHIVE_DIR:-/var/backups/sshvpnpanel/archived_users}/${username}"
    local report_file
    report_file="${report_dir}/final_audit_report_$(date '+%Y%m%d_%H%M%S').txt"

    ensure_dir "$report_dir" 700 root

    {
        echo "============================================================"
        echo " SSH VPN Panel - Final Audit Report"
        echo " User: ${username}"
        echo " Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Operator: ${SUDO_USER:-${USER:-root}}"
        echo "============================================================"
        echo ""
        echo "--- System Account ---"
        getent passwd "$username" 2>/dev/null || echo "(account already removed)"
        echo ""
        echo "--- Audit Log Entries ---"
        if [[ -f "${LOG_AUDIT_FILE}" ]]; then
            grep "user=${username}" "${LOG_AUDIT_FILE}" 2>/dev/null || echo "(no entries found)"
        else
            echo "(audit log not found)"
        fi
        echo ""
        echo "--- VPN Profile (last known) ---"
        local profile_file="${VPN_CONFIG_DIR:-/etc/sshvpnpanel/vpn}/${username}/profile.conf"
        if [[ -f "$profile_file" ]]; then
            cat "$profile_file"
        else
            echo "(VPN profile already removed)"
        fi
        echo ""
        echo "============================================================"
        echo " End of Report"
        echo "============================================================"
    } > "$report_file" 2>/dev/null

    print_success "Final audit report generated: ${report_file}"
    log_audit "AUDIT_REPORT_GENERATED" "$username" "file=${report_file}"
    return 0
}
