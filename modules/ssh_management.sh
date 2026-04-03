#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - SSH Management Module
# Handles SSH user accounts, key management, sshd_config tuning
################################################################################

[[ -n "${_SSH_MANAGEMENT_LOADED:-}" ]] && return 0
_SSH_MANAGEMENT_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

# ---------------------------------------------------------------------------
# SSH user creation
# ---------------------------------------------------------------------------

# Create a system SSH user account
# Usage: ssh_create_user USERNAME PASSWORD SHELL EXPIRE_DATE HOME_DIR
ssh_create_user() {
    local username="$1"
    local password="$2"
    local shell="${3:-/bin/bash}"
    local expire_date="${4:-}"
    local home_dir="${5:-/home/${username}}"
    local group="${USER_DEFAULT_GROUP:-sshvpn}"

    check_root || return 1
    validate_username "$username" || return 1
    validate_password "$password" || return 1

    if user_exists "$username"; then
        log_warn "SSH user '${username}' already exists."
        return 1
    fi

    # Ensure the group exists
    if ! group_exists "$group"; then
        groupadd "$group" || { log_error "Failed to create group ${group}"; return 1; }
        log_info "Created group: ${group}"
    fi

    log_info "Creating SSH system user: ${username}"

    # Build useradd arguments
    local useradd_args=(-m -d "$home_dir" -s "$shell" -g "$group" -c "SSH VPN User")
    [[ -n "$expire_date" ]] && useradd_args+=(-e "$expire_date")

    useradd "${useradd_args[@]}" "$username" || {
        log_error "Failed to create user account: ${username}"
        return 1
    }

    # Set password
    echo "${username}:${password}" | chpasswd || {
        log_error "Failed to set password for user: ${username}"
        userdel -r "$username" 2>/dev/null || true
        return 1
    }

    # Create .ssh directory
    local ssh_dir="${home_dir}/.ssh"
    ensure_dir "$ssh_dir" 700 "${username}"

    # Set home directory permissions
    chown -R "${username}:${group}" "$home_dir"
    chmod 750 "$home_dir"

    log_audit "SSH_USER_CREATED" "$username" "home=${home_dir} shell=${shell} expire=${expire_date:-none}"
    print_success "SSH user '${username}' created successfully."
    return 0
}

# ---------------------------------------------------------------------------
# SSH key management
# ---------------------------------------------------------------------------

# Generate SSH key pair for a user
# Usage: ssh_generate_keys USERNAME [key_type] [key_bits]
ssh_generate_keys() {
    local username="$1"
    local key_type="${2:-ed25519}"
    local key_bits="${3:-4096}"
    local home_dir
    home_dir="$(getent passwd "$username" | cut -d: -f6)"
    local ssh_dir="${home_dir}/.ssh"
    local key_file="${ssh_dir}/id_${key_type}"

    user_exists "$username" || { log_error "User does not exist: ${username}"; return 1; }
    ensure_dir "$ssh_dir" 700 "$username"

    log_info "Generating SSH ${key_type} key pair for user: ${username}"

    if [[ "$key_type" == "rsa" ]]; then
        ssh-keygen -t rsa -b "$key_bits" -f "$key_file" -N "" -C "${username}@sshvpnpanel" -q
    else
        ssh-keygen -t ed25519 -f "$key_file" -N "" -C "${username}@sshvpnpanel" -q
    fi || { log_error "Failed to generate SSH keys for ${username}"; return 1; }

    # Add public key to authorized_keys
    cat "${key_file}.pub" >> "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys" "${key_file}" "${key_file}.pub"
    chown -R "${username}" "$ssh_dir"

    log_audit "SSH_KEYS_GENERATED" "$username" "type=${key_type}"
    print_success "SSH keys generated for '${username}'."
    echo "  Private key : ${key_file}"
    echo "  Public key  : ${key_file}.pub"
    return 0
}

# Revoke (remove) SSH keys for a user
ssh_revoke_keys() {
    local username="$1"
    local home_dir
    home_dir="$(getent passwd "$username" | cut -d: -f6 2>/dev/null)"
    if [[ -z "$home_dir" ]]; then
        log_warn "Cannot find home directory for ${username}; skipping key revocation."
        return 0
    fi
    local ssh_dir="${home_dir}/.ssh"
    if [[ -d "$ssh_dir" ]]; then
        rm -f "${ssh_dir}/authorized_keys" "${ssh_dir}/id_"* 2>/dev/null || true
        log_info "Revoked SSH keys for user: ${username}"
        log_audit "SSH_KEYS_REVOKED" "$username"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# SSH session limiting
# ---------------------------------------------------------------------------

# Set MaxSessions for a specific user in sshd_config
ssh_set_max_sessions() {
    local username="$1"
    local max_sessions="${2:-2}"
    local sshd_config="${SSH_CONFIG:-/etc/ssh/sshd_config}"
    local marker="# sshvpnpanel:user:${username}"

    backup_file "$sshd_config"

    # Remove existing block for this user if present
    if grep -q "$marker" "$sshd_config" 2>/dev/null; then
        sed -i "/${marker}/,/^$/d" "$sshd_config"
    fi

    # Append new Match block
    printf '\n%s\nMatch User %s\n    MaxSessions %d\n    MaxAuthTries %d\n' \
        "$marker" "$username" "$max_sessions" "${SSH_MAX_AUTH_TRIES:-3}" \
        >> "$sshd_config"

    log_info "Set MaxSessions=${max_sessions} for SSH user: ${username}"
    return 0
}

# Remove SSH Match block for a user
ssh_remove_user_config() {
    local username="$1"
    local sshd_config="${SSH_CONFIG:-/etc/ssh/sshd_config}"
    local marker="# sshvpnpanel:user:${username}"

    if grep -q "$marker" "$sshd_config" 2>/dev/null; then
        backup_file "$sshd_config"
        # Use awk to remove the marked block
        awk -v m="$marker" '
            /^[[:space:]]*$/ { blank=$0; next }
            $0 == m { skip=1; next }
            skip && /^Match / { skip=0 }
            skip { next }
            { if (blank) { print blank; blank="" } print }
        ' "$sshd_config" > "${sshd_config}.tmp.$$" && mv "${sshd_config}.tmp.$$" "$sshd_config"
        log_info "Removed SSH config block for user: ${username}"
    fi
    return 0
}

# Reload SSH daemon
ssh_reload() {
    log_info "Reloading SSH daemon..."
    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload sshd || systemctl restart sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl reload ssh || systemctl restart ssh
    else
        kill -HUP "$(cat /var/run/sshd.pid 2>/dev/null)" 2>/dev/null || true
    fi
    log_info "SSH daemon reloaded."
}

# ---------------------------------------------------------------------------
# SSH user deletion
# ---------------------------------------------------------------------------

# Delete a system SSH user account
# Usage: ssh_delete_user USERNAME [preserve_home=false]
ssh_delete_user() {
    local username="$1"
    local preserve_home="${2:-false}"

    check_root || return 1

    if ! user_exists "$username"; then
        log_warn "SSH user '${username}' does not exist."
        return 0
    fi

    # Kill active sessions
    local pids
    pids="$(pgrep -u "$username" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        log_info "Terminating active sessions for user: ${username}"
        kill -9 $pids 2>/dev/null || true
    fi

    ssh_revoke_keys "$username"
    ssh_remove_user_config "$username"

    if [[ "$preserve_home" == "true" ]]; then
        userdel "$username" 2>/dev/null || { log_error "Failed to delete user: ${username}"; return 1; }
    else
        userdel -r "$username" 2>/dev/null || { log_error "Failed to delete user: ${username}"; return 1; }
    fi

    log_audit "SSH_USER_DELETED" "$username" "preserve_home=${preserve_home}"
    print_success "SSH user '${username}' deleted."
    return 0
}

# ---------------------------------------------------------------------------
# SSH user information
# ---------------------------------------------------------------------------

# Display information about a SSH user
ssh_user_info() {
    local username="$1"

    if ! user_exists "$username"; then
        print_error "User '${username}' does not exist."
        return 1
    fi

    local uid gid home shell expire groups
    uid="$(id -u "$username")"
    gid="$(id -g "$username")"
    home="$(getent passwd "$username" | cut -d: -f6)"
    shell="$(getent passwd "$username" | cut -d: -f7)"
    expire="$(chage -l "$username" 2>/dev/null | grep 'Account expires' | cut -d: -f2 | xargs)"
    groups="$(groups "$username" 2>/dev/null | cut -d: -f2 | xargs)"

    print_section "SSH User Information: ${username}"
    print_table_row "UID" "$uid"
    print_table_row "GID" "$gid"
    print_table_row "Home" "$home"
    print_table_row "Shell" "$shell"
    print_table_row "Expires" "${expire:-never}"
    print_table_row "Groups" "$groups"

    # Show active connections
    local conn_count
    conn_count="$(who | grep -c "^${username} " 2>/dev/null || echo 0)"
    print_table_row "Active Sessions" "$conn_count"

    # Show SSH keys
    local auth_keys="${home}/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local key_count
        key_count="$(grep -c 'ssh-' "$auth_keys" 2>/dev/null || echo 0)"
        print_table_row "Authorized Keys" "$key_count"
    else
        print_table_row "Authorized Keys" "none"
    fi
}

# List all SSH VPN users
ssh_list_users() {
    local group="${USER_DEFAULT_GROUP:-sshvpn}"
    print_section "SSH VPN Users (group: ${group})"
    printf "  %-20s %-8s %-30s %-12s\n" "USERNAME" "UID" "HOME" "EXPIRES"
    printf "  %-20s %-8s %-30s %-12s\n" "--------" "---" "----" "-------"

    if ! group_exists "$group"; then
        print_warning "Group '${group}' does not exist yet."
        return 0
    fi

    local members
    members="$(getent group "$group" | cut -d: -f4 | tr ',' '\n')"
    if [[ -z "$members" ]]; then
        print_info "No users found in group '${group}'."
        return 0
    fi

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local uid home expire
        uid="$(id -u "$user" 2>/dev/null || echo "?")"
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || echo "?")"
        expire="$(chage -l "$user" 2>/dev/null | grep 'Account expires' | cut -d: -f2 | xargs || echo "never")"
        printf "  %-20s %-8s %-30s %-12s\n" "$user" "$uid" "$home" "$expire"
    done <<< "$members"
}
