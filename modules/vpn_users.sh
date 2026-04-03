#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - VPN Users Module
# Manages VPN user profiles and configurations
################################################################################

[[ -n "${_VPN_USERS_LOADED:-}" ]] && return 0
_VPN_USERS_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

VPN_CONFIG_DIR="${VPN_CONFIG_DIR:-/etc/sshvpnpanel/vpn}"
VPN_DATA_DIR="${VPN_DATA_DIR:-/var/lib/sshvpnpanel/vpn}"
VPN_DEFAULT_DNS="${VPN_DEFAULT_DNS:-8.8.8.8,8.8.4.4}"

# ---------------------------------------------------------------------------
# VPN user profile management
# ---------------------------------------------------------------------------

# Create a VPN user profile
# Usage: vpn_add_user USERNAME [quota_mb] [bandwidth_limit_mb] [expire_date] [dns]
vpn_add_user() {
    local username="$1"
    local quota_mb="${2:-${SSH_DEFAULT_QUOTA_MB:-1024}}"
    local bandwidth_mb="${3:-${BANDWIDTH_LIMIT_DEFAULT_MB:-10240}}"
    local expire_date="${4:-$(calc_expiry_date "${SSH_DEFAULT_EXPIRE_DAYS:-30}")}"
    local dns="${5:-${VPN_DEFAULT_DNS}}"

    check_root || return 1

    ensure_dir "$VPN_CONFIG_DIR" 750 root
    ensure_dir "$VPN_DATA_DIR" 750 root

    local profile_dir="${VPN_CONFIG_DIR}/${username}"
    local data_dir="${VPN_DATA_DIR}/${username}"

    if [[ -d "$profile_dir" ]]; then
        log_warn "VPN profile for '${username}' already exists."
        return 1
    fi

    ensure_dir "$profile_dir" 750 root
    ensure_dir "$data_dir" 750 root

    log_info "Creating VPN profile for user: ${username}"

    # Write VPN profile
    cat > "${profile_dir}/profile.conf" << EOF
# VPN Profile for: ${username}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
VPN_USERNAME=${username}
VPN_QUOTA_MB=${quota_mb}
VPN_BANDWIDTH_LIMIT_MB=${bandwidth_mb}
VPN_EXPIRE_DATE=${expire_date}
VPN_DNS=${dns}
VPN_STATUS=active
VPN_CREATED=$(date '+%Y-%m-%d %H:%M:%S')
VPN_LAST_LOGIN=never
VPN_TOTAL_BYTES_IN=0
VPN_TOTAL_BYTES_OUT=0
VPN_TOTAL_CONNECTIONS=0
EOF

    # Create usage tracking file
    cat > "${data_dir}/usage.dat" << EOF
# Usage statistics for: ${username}
# Format: DATE,BYTES_IN,BYTES_OUT,CONNECTIONS
# Last reset: $(date '+%Y-%m-%d')
EOF

    # Apply disk quota (if quota tools available)
    vpn_set_quota "$username" "$quota_mb"

    log_audit "VPN_USER_CREATED" "$username" "quota=${quota_mb}MB bw=${bandwidth_mb}MB expire=${expire_date}"
    print_success "VPN profile created for '${username}'."
    return 0
}

# Remove a VPN user profile
vpn_remove_user() {
    local username="$1"
    local archive="${2:-true}"
    local profile_dir="${VPN_CONFIG_DIR}/${username}"
    local data_dir="${VPN_DATA_DIR}/${username}"

    check_root || return 1

    if [[ "$archive" == "true" ]]; then
        vpn_archive_user "$username"
    fi

    [[ -d "$profile_dir" ]] && rm -rf "$profile_dir"
    [[ -d "$data_dir" ]] && rm -rf "$data_dir"

    log_audit "VPN_USER_REMOVED" "$username" "archived=${archive}"
    print_success "VPN profile removed for '${username}'."
    return 0
}

# Archive VPN user data for compliance
vpn_archive_user() {
    local username="$1"
    local archive_dir="${ARCHIVE_DIR:-/var/backups/sshvpnpanel/archived_users}/${username}"
    local profile_dir="${VPN_CONFIG_DIR}/${username}"
    local data_dir="${VPN_DATA_DIR}/${username}"

    ensure_dir "$archive_dir" 700 root

    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"

    if [[ -d "$profile_dir" ]]; then
        cp -r "$profile_dir" "${archive_dir}/vpn_config_${ts}"
    fi
    if [[ -d "$data_dir" ]]; then
        cp -r "$data_dir" "${archive_dir}/vpn_data_${ts}"
    fi

    log_audit "VPN_USER_ARCHIVED" "$username" "archive=${archive_dir}"
    print_success "VPN data archived for '${username}' at ${archive_dir}."
}

# Update VPN user profile settings
vpn_update_user() {
    local username="$1"
    local key="$2"
    local value="$3"
    local profile_file="${VPN_CONFIG_DIR}/${username}/profile.conf"

    if [[ ! -f "$profile_file" ]]; then
        log_error "VPN profile not found for user: ${username}"
        return 1
    fi

    if grep -q "^${key}=" "$profile_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$profile_file"
    else
        echo "${key}=${value}" >> "$profile_file"
    fi

    log_audit "VPN_USER_UPDATED" "$username" "${key}=${value}"
    return 0
}

# Suspend/activate a VPN user
vpn_set_status() {
    local username="$1"
    local status="$2"  # active or suspended

    vpn_update_user "$username" "VPN_STATUS" "$status"
    log_audit "VPN_STATUS_CHANGED" "$username" "status=${status}"
    print_success "VPN user '${username}' status set to: ${status}."
}

# Set disk quota for a user (via setquota if available)
vpn_set_quota() {
    local username="$1"
    local quota_mb="$2"

    if ! command -v setquota >/dev/null 2>&1; then
        log_debug "setquota not available; skipping disk quota for ${username}"
        return 0
    fi

    # Convert MB to 1K blocks; hard limit is 110% of soft (integer arithmetic is intentional)
    local soft_blocks=$((quota_mb * 1024))
    local hard_blocks=$((quota_mb * 1126))  # ~110% of soft limit (quota_mb * 1024 * 110 / 100)

    # Find the filesystem for the user's home directory
    local home_dir
    home_dir="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || echo "/home/${username}")"
    local fs
    fs="$(df "$home_dir" 2>/dev/null | tail -1 | awk '{print $1}')"

    if [[ -n "$fs" ]]; then
        setquota -u "$username" "$soft_blocks" "$hard_blocks" 0 0 "$fs" 2>/dev/null || \
            log_debug "Could not set quota for ${username} on ${fs}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# VPN user information
# ---------------------------------------------------------------------------

vpn_user_info() {
    local username="$1"
    local profile_file="${VPN_CONFIG_DIR}/${username}/profile.conf"

    print_section "VPN Profile: ${username}"
    if [[ -f "$profile_file" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            local display_key
            display_key="$(echo "${key#VPN_}" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')"
            print_table_row "$display_key" "$value"
        done < "$profile_file"
    else
        print_warning "No VPN profile found for user '${username}'."
        return 1
    fi

    # Show recent usage stats
    local usage_file="${VPN_DATA_DIR}/${username}/usage.dat"
    if [[ -f "$usage_file" ]]; then
        print_section "Recent Usage: ${username}"
        tail -5 "$usage_file" | grep -v '^#' | while IFS=',' read -r date bytes_in bytes_out conns; do
            [[ -z "$date" ]] && continue
            printf "  %-12s in=%-12s out=%-12s conns=%s\n" \
                "$date" "$(human_bytes "${bytes_in:-0}")" "$(human_bytes "${bytes_out:-0}")" "${conns:-0}"
        done
    fi
}

# List all VPN users
vpn_list_users() {
    print_section "VPN Users"
    printf "  %-20s %-12s %-12s %-12s %-12s\n" "USERNAME" "STATUS" "EXPIRES" "QUOTA(MB)" "BW LIMIT(MB)"
    printf "  %-20s %-12s %-12s %-12s %-12s\n" "--------" "------" "-------" "---------" "-----------"

    if [[ ! -d "$VPN_CONFIG_DIR" ]]; then
        print_info "No VPN user configurations found."
        return 0
    fi

    local found=0
    for profile in "${VPN_CONFIG_DIR}"/*/profile.conf; do
        [[ -f "$profile" ]] || continue
        local username status expires quota bw
        username="$(grep 'VPN_USERNAME=' "$profile" | cut -d= -f2)"
        status="$(grep 'VPN_STATUS=' "$profile" | cut -d= -f2)"
        expires="$(grep 'VPN_EXPIRE_DATE=' "$profile" | cut -d= -f2)"
        quota="$(grep 'VPN_QUOTA_MB=' "$profile" | cut -d= -f2)"
        bw="$(grep 'VPN_BANDWIDTH_LIMIT_MB=' "$profile" | cut -d= -f2)"
        printf "  %-20s %-12s %-12s %-12s %-12s\n" \
            "$username" "$status" "$expires" "$quota" "$bw"
        ((found++))
    done

    [[ "$found" -eq 0 ]] && print_info "No VPN users found."
}

# Record a connection event for a user
vpn_record_connection() {
    local username="$1"
    local bytes_in="${2:-0}"
    local bytes_out="${3:-0}"
    local usage_file="${VPN_DATA_DIR}/${username}/usage.dat"

    if [[ -d "$(dirname "$usage_file")" ]]; then
        echo "$(date '+%Y-%m-%d'),${bytes_in},${bytes_out},1" >> "$usage_file"
        # Update profile total counters
        local profile_file="${VPN_CONFIG_DIR}/${username}/profile.conf"
        if [[ -f "$profile_file" ]]; then
            local old_in old_out old_conn
            old_in="$(grep 'VPN_TOTAL_BYTES_IN=' "$profile_file" | cut -d= -f2)"
            old_out="$(grep 'VPN_TOTAL_BYTES_OUT=' "$profile_file" | cut -d= -f2)"
            old_conn="$(grep 'VPN_TOTAL_CONNECTIONS=' "$profile_file" | cut -d= -f2)"
            vpn_update_user "$username" "VPN_TOTAL_BYTES_IN" "$((${old_in:-0} + bytes_in))"
            vpn_update_user "$username" "VPN_TOTAL_BYTES_OUT" "$((${old_out:-0} + bytes_out))"
            vpn_update_user "$username" "VPN_TOTAL_CONNECTIONS" "$((${old_conn:-0} + 1))"
            vpn_update_user "$username" "VPN_LAST_LOGIN" "$(date '+%Y-%m-%d %H:%M:%S')"
        fi
    fi
}
