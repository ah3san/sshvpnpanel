#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - Installer / Setup Script
# Sets up the system environment for the SSH VPN Panel:
#   - Installs required packages
#   - Creates directories and config files
#   - Initializes the internal CA
#   - Applies default SSH and firewall hardening
#   - Sets up systemd service (optional)
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

# Bootstrap utilities
# shellcheck source=modules/utilities.sh
source "${MODULES_DIR}/utilities.sh"
# shellcheck source=modules/tls_sni.sh
source "${MODULES_DIR}/tls_sni.sh"
# shellcheck source=modules/security.sh
source "${MODULES_DIR}/security.sh"

INSTALL_CONFIG_DIR="/etc/sshvpnpanel"
INSTALL_LOG_DIR="/var/log/sshvpnpanel"
INSTALL_DATA_DIR="/var/lib/sshvpnpanel"
INSTALL_BACKUP_DIR="/var/backups/sshvpnpanel"
INSTALL_ARCHIVE_DIR="${INSTALL_BACKUP_DIR}/archived_users"

# ---------------------------------------------------------------------------
# Package lists by distribution
# ---------------------------------------------------------------------------

PACKAGES_DEBIAN="openssh-server stunnel4 openssl iptables ufw fail2ban vnstat curl wget"
PACKAGES_RHEL="openssh-server stunnel openssl iptables-services fail2ban curl wget"

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "unknown"
    fi
}

install_packages() {
    local pkg_mgr
    pkg_mgr="$(detect_pkg_manager)"
    print_section "Installing Dependencies (${pkg_mgr})"

    case "$pkg_mgr" in
        apt)
            apt-get update -qq
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                $PACKAGES_DEBIAN 2>/dev/null || log_warn "Some packages may not have installed correctly."
            ;;
        dnf|yum)
            # shellcheck disable=SC2086
            "$pkg_mgr" install -y $PACKAGES_RHEL 2>/dev/null || \
                log_warn "Some packages may not have installed correctly."
            ;;
        *)
            log_warn "Unknown package manager. Please install required packages manually:"
            echo "  SSH server, stunnel, openssl, iptables, fail2ban, vnstat"
            ;;
    esac
    print_success "Dependencies installed."
}

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------

setup_directories() {
    print_section "Creating Directories"
    local dirs=(
        "${INSTALL_CONFIG_DIR}"
        "${INSTALL_CONFIG_DIR}/templates"
        "${INSTALL_CONFIG_DIR}/vpn"
        "${INSTALL_LOG_DIR}"
        "${INSTALL_DATA_DIR}"
        "${INSTALL_DATA_DIR}/users"
        "${INSTALL_DATA_DIR}/sni"
        "${INSTALL_DATA_DIR}/vpn"
        "${INSTALL_DATA_DIR}/bandwidth"
        "${INSTALL_BACKUP_DIR}"
        "${INSTALL_ARCHIVE_DIR}"
        "/etc/stunnel/certs"
        "/etc/stunnel/users"
        "/etc/ssl/sshvpnpanel"
        "/etc/ssl/sshvpnpanel/users"
    )
    for dir in "${dirs[@]}"; do
        ensure_dir "$dir" 750 root
        print_step "create" "$dir"
    done
    print_success "Directories created."
}

# ---------------------------------------------------------------------------
# Copy config files
# ---------------------------------------------------------------------------

install_config_files() {
    print_section "Installing Configuration Files"
    local src_conf="${SCRIPT_DIR}/config/sshvpnpanel.conf"
    local dst_conf="${INSTALL_CONFIG_DIR}/sshvpnpanel.conf"

    if [[ ! -f "$dst_conf" ]]; then
        if [[ -f "$src_conf" ]]; then
            cp "$src_conf" "$dst_conf"
            chmod 640 "$dst_conf"
            print_step "install" "$dst_conf"
        else
            log_warn "Source config not found: ${src_conf}"
        fi
    else
        print_info "Config already exists: ${dst_conf} (not overwritten)"
    fi

    # Copy stunnel template
    local stunnel_tmpl="${SCRIPT_DIR}/config/stunnel.conf.template"
    local stunnel_dst="${INSTALL_CONFIG_DIR}/stunnel.conf.template"
    if [[ -f "$stunnel_tmpl" && ! -f "$stunnel_dst" ]]; then
        cp "$stunnel_tmpl" "$stunnel_dst"
        print_step "install" "$stunnel_dst"
    fi

    # Copy security config
    local sec_src="${SCRIPT_DIR}/config/security.conf"
    local sec_dst="${INSTALL_CONFIG_DIR}/security.conf"
    if [[ -f "$sec_src" && ! -f "$sec_dst" ]]; then
        cp "$sec_src" "$sec_dst"
        chmod 640 "$sec_dst"
        print_step "install" "$sec_dst"
    fi

    # Copy user template
    local tmpl_src="${SCRIPT_DIR}/config/user_template.conf"
    local tmpl_dst="${INSTALL_CONFIG_DIR}/templates/default.conf"
    if [[ -f "$tmpl_src" && ! -f "$tmpl_dst" ]]; then
        cp "$tmpl_src" "$tmpl_dst"
        print_step "install" "$tmpl_dst"
    fi

    print_success "Configuration files installed."
}

# ---------------------------------------------------------------------------
# Make scripts executable
# ---------------------------------------------------------------------------

install_scripts() {
    print_section "Setting Script Permissions"
    chmod +x "${SCRIPT_DIR}/sshvpnpanel.sh"
    chmod +x "${SCRIPT_DIR}/installer.sh"
    for mod in "${MODULES_DIR}"/*.sh; do
        chmod +x "$mod"
    done

    # Create /usr/local/bin symlink
    if [[ ! -L "/usr/local/bin/sshvpnpanel" ]]; then
        ln -sf "${SCRIPT_DIR}/sshvpnpanel.sh" "/usr/local/bin/sshvpnpanel"
        print_step "link" "/usr/local/bin/sshvpnpanel -> ${SCRIPT_DIR}/sshvpnpanel.sh"
    fi
    print_success "Scripts configured."
}

# ---------------------------------------------------------------------------
# SSH VPN user group
# ---------------------------------------------------------------------------

setup_user_group() {
    print_section "Setting Up User Group"
    local group="${USER_DEFAULT_GROUP:-sshvpn}"
    if ! group_exists "$group"; then
        groupadd "$group"
        print_step "create" "group: ${group}"
    else
        print_info "Group '${group}' already exists."
    fi
    print_success "User group ready."
}

# ---------------------------------------------------------------------------
# Initialize internal CA
# ---------------------------------------------------------------------------

init_ca() {
    print_section "Initializing Internal CA"
    load_config "${INSTALL_CONFIG_DIR}/sshvpnpanel.conf"
    tls_init_ca || log_warn "CA initialization skipped (may already exist)."
}

# ---------------------------------------------------------------------------
# Set up log rotation
# ---------------------------------------------------------------------------

setup_logrotate() {
    print_section "Configuring Log Rotation"
    local logrotate_conf="/etc/logrotate.d/sshvpnpanel"
    cat > "$logrotate_conf" << EOF
/var/log/sshvpnpanel/*.log {
    daily
    rotate ${LOG_ROTATE_DAYS:-30}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    print_step "install" "$logrotate_conf"
    print_success "Log rotation configured."
}

# ---------------------------------------------------------------------------
# Apply SSH hardening
# ---------------------------------------------------------------------------

apply_ssh_hardening() {
    print_section "Applying SSH Hardening"
    load_config "${INSTALL_CONFIG_DIR}/sshvpnpanel.conf"
    if [[ -f "${INSTALL_CONFIG_DIR}/security.conf" ]]; then
        # shellcheck source=/dev/null
        source "${INSTALL_CONFIG_DIR}/security.conf"
    fi
    ssh_apply_hardening || log_warn "SSH hardening had warnings; review sshd_config."
}

# ---------------------------------------------------------------------------
# Stunnel include directory setup
# ---------------------------------------------------------------------------

setup_stunnel() {
    print_section "Configuring Stunnel"

    # Determine distro-appropriate paths
    local stunnel_user="stunnel4"
    local stunnel_pid_dir="/var/run/stunnel4"
    local stunnel_log_dir="/var/log/stunnel4"
    local pkg_mgr
    pkg_mgr="$(detect_pkg_manager)"
    if [[ "$pkg_mgr" == "dnf" || "$pkg_mgr" == "yum" ]]; then
        stunnel_user="stunnel"
        stunnel_pid_dir="/var/run/stunnel"
        stunnel_log_dir="/var/log/stunnel"
    fi

    local main_conf="/etc/stunnel/stunnel.conf"
    if [[ ! -f "$main_conf" ]]; then
        cat > "$main_conf" << EOF
# SSH VPN Panel - Stunnel global configuration
pid = ${stunnel_pid_dir}/stunnel.pid
output = ${stunnel_log_dir}/stunnel.log
setuid = ${stunnel_user}
setgid = ${stunnel_user}
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
fips = no
sslVersion = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
options = NO_TLSv1
options = NO_TLSv1.1

# Per-user configs are loaded from this directory:
include = /etc/stunnel/users/
EOF
        print_step "create" "$main_conf"
    else
        # Ensure include directive exists
        if ! grep -q "include = /etc/stunnel/users/" "$main_conf" 2>/dev/null; then
            echo -e "\ninclude = /etc/stunnel/users/" >> "$main_conf"
            print_step "update" "Added 'include' directive to ${main_conf}"
        else
            print_info "Stunnel include directive already present."
        fi
    fi

    # Enable stunnel on startup
    local svc
    for svc in stunnel4 stunnel; do
        if systemctl list-units --type=service 2>/dev/null | grep -q "${svc}.service"; then
            systemctl enable "$svc" 2>/dev/null || true
            break
        fi
    done

    print_success "Stunnel configured."
}

# ---------------------------------------------------------------------------
# Main installer
# ---------------------------------------------------------------------------

main() {
    print_header "SSH VPN Panel Installer v${PANEL_VERSION:-1.0.0}"

    check_root || exit 1

    if prompt_confirm "Install required system packages?" "y"; then
        install_packages
    fi

    setup_directories
    install_config_files
    install_scripts
    setup_user_group
    init_ca
    setup_logrotate
    setup_stunnel

    if prompt_confirm "Apply SSH hardening settings?" "y"; then
        apply_ssh_hardening
    fi

    if prompt_confirm "Apply default firewall rules?" "n"; then
        load_config "${INSTALL_CONFIG_DIR}/sshvpnpanel.conf"
        firewall_apply_defaults
    fi

    echo ""
    print_header "Installation Complete"
    print_success "SSH VPN Panel has been installed successfully!"
    echo ""
    print_info "To start the panel, run:"
    echo "  sudo sshvpnpanel"
    echo ""
    print_info "Or use command-line mode:"
    echo "  sudo sshvpnpanel user add"
    echo "  sudo sshvpnpanel user remove USERNAME"
    echo "  sudo sshvpnpanel --help"
    echo ""
    log_audit "PANEL_INSTALLED" "SYSTEM" "version=${PANEL_VERSION:-1.0.0}"
}

main "$@"
