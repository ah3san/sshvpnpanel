#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - Automated Installer
# =============================================================================
# Installs and configures the SSH VPN Panel on supported Linux distributions.
#
# Supported:
#   Ubuntu 18.04+, Debian 10+
#   CentOS 7+, RHEL 7+, AlmaLinux 8+, Rocky Linux 8+
#   Alpine Linux 3.12+
#
# Usage:
#   sudo bash installer.sh [OPTIONS]
#
# Options:
#   --no-interactive    Run in non-interactive mode with defaults
#   --install-dir DIR   Installation directory (default: /opt/sshvpnpanel)
#   --config-dir DIR    Config directory (default: /etc/sshvpnpanel)
#   --port PORT         SSH port (default: 22)
#   --ssl-port PORT     SSL/Stunnel port (default: 443)
#   --uninstall         Uninstall the panel
#   --upgrade           Upgrade an existing installation
#   --help              Show this help
# =============================================================================

set -euo pipefail

# =============================================================================
# INSTALLER CONFIGURATION
# =============================================================================

INSTALLER_VERSION="1.0.0"
INSTALL_DIR="${INSTALL_DIR:-/opt/sshvpnpanel}"
CONFIG_DIR="${CONFIG_DIR:-/etc/sshvpnpanel}"
LOG_DIR="${LOG_DIR:-/var/log/sshvpnpanel}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/sshvpnpanel}"
DATA_DIR="${DATA_DIR:-/var/lib/sshvpnpanel}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERACTIVE="${INTERACTIVE:-yes}"

# Parse command-line arguments
SSH_PORT=22
SSL_PORT=443
UNINSTALL=no
UPGRADE=no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-interactive) INTERACTIVE=no ;;
        --install-dir) INSTALL_DIR="$2"; shift ;;
        --config-dir) CONFIG_DIR="$2"; shift ;;
        --port) SSH_PORT="$2"; shift ;;
        --ssl-port) SSL_PORT="$2"; shift ;;
        --uninstall) UNINSTALL=yes ;;
        --upgrade) UPGRADE=yes ;;
        --help|-h)
            echo "SSH VPN Panel Installer v${INSTALLER_VERSION}"
            echo
            echo "Usage: sudo bash installer.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --no-interactive    Non-interactive mode"
            echo "  --install-dir DIR   Installation directory [/opt/sshvpnpanel]"
            echo "  --config-dir DIR    Config directory [/etc/sshvpnpanel]"
            echo "  --port PORT         SSH port [22]"
            echo "  --ssl-port PORT     SSL port [443]"
            echo "  --uninstall         Remove the panel"
            echo "  --upgrade           Upgrade existing installation"
            echo "  --help              Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# =============================================================================
# COLOR DEFINITIONS (standalone for installer)
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_ok()      { echo -e "${GREEN}[✓] $*${RESET}"; }
print_err()     { echo -e "${RED}[✗] $*${RESET}" >&2; }
print_warn()    { echo -e "${YELLOW}[!] $*${RESET}"; }
print_info()    { echo -e "${CYAN}[i] $*${RESET}"; }
print_step()    { echo -e "\n${BOLD}${BLUE}>>> $*${RESET}"; }
print_banner()  {
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║         SSH VPN Panel - Installer v${INSTALLER_VERSION}                     ║"
    echo "  ║         SSH + Stunnel + TLS + SNI Support                       ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_err "This installer must be run as root"
        print_info "Run: sudo bash installer.sh"
        exit 1
    fi
}

check_bash_version() {
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        print_err "Bash 4.0+ is required (current: ${BASH_VERSION})"
        exit 1
    fi
}

detect_distro() {
    local distro="" version="" pkg_mgr="" svc_mgr=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        distro="${ID:-unknown}"
        version="${VERSION_ID:-unknown}"
    elif command -v lsb_release &>/dev/null; then
        distro="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
        version="$(lsb_release -sr)"
    fi

    # Detect package manager
    if command -v apt-get &>/dev/null; then
        pkg_mgr="apt"
    elif command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    elif command -v yum &>/dev/null; then
        pkg_mgr="yum"
    elif command -v apk &>/dev/null; then
        pkg_mgr="apk"
    else
        pkg_mgr="unknown"
    fi

    # Detect service manager
    if command -v systemctl &>/dev/null && systemctl status &>/dev/null 2>&1; then
        svc_mgr="systemd"
    elif command -v rc-service &>/dev/null; then
        svc_mgr="openrc"
    else
        svc_mgr="sysvinit"
    fi

    DISTRO="${distro}"
    DISTRO_VERSION="${version}"
    PKG_MGR="${pkg_mgr}"
    SVC_MGR="${svc_mgr}"

    print_info "Distribution: ${distro} ${version}"
    print_info "Package manager: ${pkg_mgr}"
    print_info "Service manager: ${svc_mgr}"
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

update_package_db() {
    print_info "Updating package database..."
    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -5
            ;;
        dnf)
            dnf check-update -q 2>&1 || true
            ;;
        yum)
            yum check-update -q 2>&1 || true
            ;;
        apk)
            apk update -q 2>&1
            ;;
    esac
}

install_packages() {
    local packages=("$@")

    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                "${packages[@]}" 2>&1 | tail -5
            ;;
        dnf)
            dnf install -y "${packages[@]}" 2>&1 | tail -5
            ;;
        yum)
            yum install -y "${packages[@]}" 2>&1 | tail -5
            ;;
        apk)
            apk add --no-cache "${packages[@]}" 2>&1 | tail -5
            ;;
        *)
            print_err "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

install_dependencies() {
    print_step "Installing dependencies..."

    local common_pkgs=("openssl" "curl" "wget" "net-tools" "iproute2" "coreutils")
    local ssh_pkgs=()
    local stunnel_pkgs=()

    case "${PKG_MGR}" in
        apt)
            ssh_pkgs=("openssh-server")
            stunnel_pkgs=("stunnel4")
            common_pkgs+=("iptables" "fail2ban" "logrotate" "chage")
            ;;
        dnf|yum)
            ssh_pkgs=("openssh-server")
            stunnel_pkgs=("stunnel")
            common_pkgs+=("iptables" "fail2ban" "logrotate")
            ;;
        apk)
            ssh_pkgs=("openssh")
            stunnel_pkgs=("stunnel")
            common_pkgs+=("iptables" "logrotate")
            ;;
    esac

    # Update package database
    update_package_db

    # Install packages
    local all_pkgs=("${common_pkgs[@]}" "${ssh_pkgs[@]}" "${stunnel_pkgs[@]}")
    print_info "Installing: ${all_pkgs[*]}"

    if install_packages "${all_pkgs[@]}"; then
        print_ok "Dependencies installed"
    else
        print_warn "Some packages may not have installed correctly"
    fi

    # Verify critical tools
    local required=("ssh" "openssl" "iptables")
    for tool in "${required[@]}"; do
        if command -v "${tool}" &>/dev/null; then
            print_ok "${tool}: found"
        else
            print_warn "${tool}: not found (may need manual installation)"
        fi
    done
}

# =============================================================================
# DIRECTORY SETUP
# =============================================================================

create_directories() {
    print_step "Creating directories..."

    local dirs=(
        "${INSTALL_DIR}"
        "${INSTALL_DIR}/modules"
        "${CONFIG_DIR}"
        "${CONFIG_DIR}/certs"
        "${CONFIG_DIR}/certs/ca"
        "${CONFIG_DIR}/stunnel/tunnels"
        "${CONFIG_DIR}/sni"
        "${CONFIG_DIR}/admins"
        "${CONFIG_DIR}/users"
        "${LOG_DIR}"
        "${BACKUP_DIR}"
        "${BACKUP_DIR}/certs"
        "${DATA_DIR}"
        "/tmp/sshvpnpanel"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
        print_info "  Created: ${dir}"
    done

    # Set permissions
    chmod 700 "${CONFIG_DIR}/certs"
    chmod 700 "${CONFIG_DIR}/admins"
    chmod 700 "${CONFIG_DIR}/users"
    chmod 750 "${LOG_DIR}"
    chmod 750 "${BACKUP_DIR}"

    print_ok "Directories created"
}

# =============================================================================
# FILE INSTALLATION
# =============================================================================

install_panel_files() {
    print_step "Installing panel files..."

    # Copy main scripts
    cp "${SCRIPT_DIR}/sshvpnpanel.sh" "${INSTALL_DIR}/sshvpnpanel.sh"
    chmod 750 "${INSTALL_DIR}/sshvpnpanel.sh"

    cp "${SCRIPT_DIR}/installer.sh" "${INSTALL_DIR}/installer.sh"
    chmod 750 "${INSTALL_DIR}/installer.sh"

    # Copy modules
    if [[ -d "${SCRIPT_DIR}/modules" ]]; then
        cp -r "${SCRIPT_DIR}/modules/"* "${INSTALL_DIR}/modules/"
        chmod 640 "${INSTALL_DIR}/modules/"*.sh
    fi

    # Copy config templates (don't overwrite existing configs)
    if [[ -d "${SCRIPT_DIR}/config" ]]; then
        for conf_file in "${SCRIPT_DIR}/config/"*; do
            local dest="${CONFIG_DIR}/$(basename "${conf_file}")"
            if [[ ! -f "${dest}" ]]; then
                cp "${conf_file}" "${dest}"
                print_info "  Installed: ${dest}"
            else
                print_info "  Skipped (exists): ${dest}"
            fi
        done
    fi

    # Create symlink for easy access
    ln -sf "${INSTALL_DIR}/sshvpnpanel.sh" /usr/local/bin/sshvpnpanel 2>/dev/null || true

    print_ok "Panel files installed"
}

# =============================================================================
# CONFIGURATION
# =============================================================================

configure_panel() {
    print_step "Configuring panel..."

    local config_file="${CONFIG_DIR}/sshvpnpanel.conf"

    # Update configuration with detected/provided values
    sed -i "s|^PANEL_BASE_DIR=.*|PANEL_BASE_DIR=\"${CONFIG_DIR}\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^LOG_DIR=.*|LOG_DIR=\"${LOG_DIR}\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^BACKUP_DIR=.*|BACKUP_DIR=\"${BACKUP_DIR}\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^USER_DATA_DIR=.*|USER_DATA_DIR=\"${CONFIG_DIR}/users\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^CERT_DIR=.*|CERT_DIR=\"${CONFIG_DIR}/certs\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^SSH_PORT=.*|SSH_PORT=${SSH_PORT}|" "${config_file}" 2>/dev/null || true
    sed -i "s|^STUNNEL_SSL_PORT=.*|STUNNEL_SSL_PORT=${SSL_PORT}|" "${config_file}" 2>/dev/null || true
    sed -i "s|^SERVICE_MANAGER=.*|SERVICE_MANAGER=\"${SVC_MGR}\"|" "${config_file}" 2>/dev/null || true
    sed -i "s|^PKG_MANAGER=.*|PKG_MANAGER=\"${PKG_MGR}\"|" "${config_file}" 2>/dev/null || true

    # Set admin password interactively if needed
    if [[ "${INTERACTIVE}" == "yes" ]]; then
        echo
        print_info "Set admin password for the panel:"
        local admin_pass
        while true; do
            read -rsp "  New admin password: " admin_pass
            echo
            local confirm_pass
            read -rsp "  Confirm password: " confirm_pass
            echo
            if [[ "${admin_pass}" == "${confirm_pass}" ]]; then
                [[ ${#admin_pass} -ge 8 ]] && break
                print_warn "Password must be at least 8 characters"
            else
                print_warn "Passwords do not match"
            fi
        done

        local pass_hash
        pass_hash="$(echo -n "${admin_pass}" | sha256sum | awk '{print $1}')"
        sed -i "s|^ADMIN_PASSWORD_HASH=.*|ADMIN_PASSWORD_HASH=\"${pass_hash}\"|" \
            "${config_file}" 2>/dev/null || true
    fi

    print_ok "Panel configured"
}

configure_ssh() {
    print_step "Configuring SSH..."

    local sshd_config="/etc/ssh/sshd_config"

    if [[ -f "${sshd_config}" ]]; then
        # Backup existing config
        cp "${sshd_config}" "${sshd_config}.backup.$(date +%Y%m%d)" 2>/dev/null || true

        # Configure SSH settings
        # Enable password authentication (needed for VPN users initially)
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
            "${sshd_config}" 2>/dev/null || true

        # Configure SSH port if changed
        if [[ "${SSH_PORT}" -ne 22 ]]; then
            sed -i "s/^#*Port.*/Port ${SSH_PORT}/" "${sshd_config}" 2>/dev/null || true
        fi

        # Security hardening
        # Disable root login
        if [[ "${INTERACTIVE}" == "yes" ]]; then
            echo -ne "${YELLOW}  Disable root SSH login? [Y/n]: ${RESET}"
            local disable_root
            read -r disable_root
            if [[ "${disable_root,,}" != "n" ]]; then
                sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
                    "${sshd_config}" 2>/dev/null || true
                print_ok "Root SSH login disabled"
            fi
        fi

        # Restart SSH service
        if systemctl restart sshd 2>/dev/null || \
           systemctl restart ssh 2>/dev/null || \
           service ssh restart 2>/dev/null; then
            print_ok "SSH service configured and restarted"
        else
            print_warn "SSH may need manual restart"
        fi
    else
        print_warn "SSH config not found at ${sshd_config}"
    fi
}

configure_stunnel() {
    print_step "Configuring Stunnel..."

    local stunnel_dir="/etc/stunnel"
    mkdir -p "${stunnel_dir}" 2>/dev/null

    # Generate default certificate if none exists
    local cert_file="${CONFIG_DIR}/certs/stunnel.crt"
    local key_file="${CONFIG_DIR}/certs/stunnel.key"

    if [[ ! -f "${cert_file}" ]]; then
        print_info "Generating default Stunnel certificate..."
        local hostname
        hostname="$(hostname -f 2>/dev/null || hostname)"
        openssl req -x509 -newkey rsa:4096 -keyout "${key_file}" \
            -out "${cert_file}" -days 365 -nodes \
            -subj "/CN=${hostname}/O=SSH VPN Panel/C=US" 2>/dev/null && {
            chmod 600 "${key_file}"
            chmod 644 "${cert_file}"
            print_ok "Default certificate generated"
        } || print_warn "Certificate generation failed - generate manually"
    fi

    # Create initial Stunnel config
    cat > "${stunnel_dir}/stunnel.conf" << EOF
; SSH VPN Panel - Stunnel Configuration
; Generated by installer

setuid = stunnel4
setgid = stunnel4
pid = /var/run/stunnel4/stunnel4.pid
output = /var/log/stunnel4/stunnel4.log
debug = 5

socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

; Default SSH over SSL tunnel
[ssh-ssl]
accept  = 0.0.0.0:${SSL_PORT}
connect = 127.0.0.1:${SSH_PORT}
cert    = ${cert_file}
key     = ${key_file}
TIMEOUTclose = 0
EOF

    # Create necessary directories for stunnel
    mkdir -p /var/run/stunnel4 /var/log/stunnel4 2>/dev/null
    chown stunnel4:stunnel4 /var/run/stunnel4 /var/log/stunnel4 2>/dev/null || true

    print_ok "Stunnel configured"
}

setup_logrotate() {
    print_step "Setting up log rotation..."

    cat > "/etc/logrotate.d/sshvpnpanel" << EOF
${LOG_DIR}/*.log {
    daily
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    size 50M
}
EOF
    print_ok "Log rotation configured"
}

setup_systemd_service() {
    print_step "Setting up systemd service..."

    if [[ "${SVC_MGR}" != "systemd" ]]; then
        print_info "Systemd not available - skipping service setup"
        return
    fi

    # Create watchdog/maintenance service
    cat > "/etc/systemd/system/sshvpnpanel-maintenance.service" << EOF
[Unit]
Description=SSH VPN Panel Maintenance
After=network.target sshd.service

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/sshvpnpanel.sh --maintenance
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create maintenance timer (runs daily)
    cat > "/etc/systemd/system/sshvpnpanel-maintenance.timer" << EOF
[Unit]
Description=SSH VPN Panel Daily Maintenance

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload 2>/dev/null
    systemctl enable sshvpnpanel-maintenance.timer 2>/dev/null || true
    systemctl start sshvpnpanel-maintenance.timer 2>/dev/null || true

    print_ok "Systemd service configured"
}

setup_cron() {
    print_step "Setting up scheduled tasks..."

    if command -v crontab &>/dev/null; then
        # Add cron jobs for maintenance tasks
        local cron_file="/etc/cron.d/sshvpnpanel"
        cat > "${cron_file}" << EOF
# SSH VPN Panel maintenance cron jobs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Check for expired users every hour
0 * * * * root ${INSTALL_DIR}/sshvpnpanel.sh --cleanup-expired >/dev/null 2>&1

# Auto-renew expiring certificates daily
0 2 * * * root ${INSTALL_DIR}/sshvpnpanel.sh --renew-certs >/dev/null 2>&1

# Daily backup at 3 AM
0 3 * * * root ${INSTALL_DIR}/sshvpnpanel.sh --backup >/dev/null 2>&1

# Rotate logs weekly
0 0 * * 0 root ${INSTALL_DIR}/sshvpnpanel.sh --rotate-logs >/dev/null 2>&1
EOF
        chmod 644 "${cron_file}"
        print_ok "Cron jobs configured"
    else
        print_warn "crontab not available - scheduled tasks not configured"
    fi
}

# =============================================================================
# BACKUP CONFIGURATION
# =============================================================================

configure_backup() {
    if [[ "${AUTO_BACKUP:-yes}" != "yes" ]]; then
        return
    fi

    print_step "Configuring automatic backups..."

    local backup_script="${INSTALL_DIR}/backup.sh"
    cat > "${backup_script}" << 'BACKUP_EOF'
#!/usr/bin/env bash
# SSH VPN Panel - Backup Script
BACKUP_DIR="${BACKUP_DIR:-/var/backups/sshvpnpanel}"
CONFIG_DIR="${CONFIG_DIR:-/etc/sshvpnpanel}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_${DATE}.tar.gz"

mkdir -p "${BACKUP_DIR}"
tar -czf "${BACKUP_FILE}" "${CONFIG_DIR}" 2>/dev/null
echo "Backup created: ${BACKUP_FILE}"

# Remove old backups (keep last 7)
find "${BACKUP_DIR}" -name "backup_*.tar.gz" -type f | \
    sort -r | tail -n +8 | xargs rm -f 2>/dev/null || true
BACKUP_EOF
    chmod 750 "${backup_script}"
    print_ok "Backup configured"
}

# =============================================================================
# INITIAL SETUP
# =============================================================================

run_initial_setup() {
    print_step "Running initial setup..."

    # Source the panel to run initialization
    export PANEL_BASE_DIR="${CONFIG_DIR}"
    export USER_DATA_DIR="${CONFIG_DIR}/users"
    export LOG_DIR="${LOG_DIR}"
    export CERT_DIR="${CONFIG_DIR}/certs"
    export STUNNEL_DIR="${CONFIG_DIR}/stunnel"

    # Initialize admin database
    local admin_conf="${CONFIG_DIR}/admins/admin.conf"
    if [[ ! -f "${admin_conf}" ]]; then
        local pass_hash
        pass_hash="$(grep 'ADMIN_PASSWORD_HASH' "${CONFIG_DIR}/sshvpnpanel.conf" 2>/dev/null | \
            cut -d= -f2 | tr -d '"')"
        if [[ -z "${pass_hash}" ]]; then
            # Default password: admin123
            pass_hash="240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9"
        fi

        cat > "${admin_conf}" << EOF
USERNAME=admin
PASSWORD_HASH=${pass_hash}
ROLE=admin
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
LAST_LOGIN=never
LOGIN_COUNT=0
ENABLED=yes
REQUIRE_CHANGE=yes
EOF
        chmod 600 "${admin_conf}"
        print_ok "Admin account created (username: admin)"
    fi

    # Create initial log files
    for log_file in sshvpnpanel.log error.log audit.log vpn_activity.log; do
        touch "${LOG_DIR}/${log_file}"
        chmod 640 "${LOG_DIR}/${log_file}"
    done

    # Initialize empty IP lists
    touch "${CONFIG_DIR}/ip_whitelist.conf"
    touch "${CONFIG_DIR}/ip_blacklist.conf"
    touch "${CONFIG_DIR}/vpn_connections.db"
    touch "${CONFIG_DIR}/failed_logins.db"
    touch "${CONFIG_DIR}/lockouts.db"

    print_ok "Initial setup complete"
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_installation() {
    print_step "Verifying installation..."

    local errors=0

    # Check main script
    if [[ -x "${INSTALL_DIR}/sshvpnpanel.sh" ]]; then
        print_ok "Main script: ${INSTALL_DIR}/sshvpnpanel.sh"
    else
        print_err "Main script not found or not executable"
        (( errors++ ))
    fi

    # Check modules
    local module_count=0
    for module in utilities ssh_management stunnel_config tls_sni vpn_users monitoring security; do
        if [[ -f "${INSTALL_DIR}/modules/${module}.sh" ]]; then
            (( module_count++ ))
        else
            print_warn "Module not found: ${module}.sh"
        fi
    done
    print_ok "Modules installed: ${module_count}/7"

    # Check config
    if [[ -f "${CONFIG_DIR}/sshvpnpanel.conf" ]]; then
        print_ok "Configuration: ${CONFIG_DIR}/sshvpnpanel.conf"
    else
        print_err "Configuration file not found"
        (( errors++ ))
    fi

    # Check symlink
    if [[ -L "/usr/local/bin/sshvpnpanel" ]]; then
        print_ok "Symlink: /usr/local/bin/sshvpnpanel"
    fi

    # Check services
    for svc in "${SSH_SERVICE:-sshd}" "${STUNNEL_SERVICE:-stunnel4}"; do
        if command -v systemctl &>/dev/null && systemctl is-enabled "${svc}" &>/dev/null 2>&1; then
            print_ok "Service enabled: ${svc}"
        fi
    done

    if [[ "${errors}" -eq 0 ]]; then
        print_ok "Verification passed"
        return 0
    else
        print_err "Verification failed with ${errors} error(s)"
        return 1
    fi
}

# =============================================================================
# UNINSTALL
# =============================================================================

uninstall_panel() {
    print_banner
    echo -e "${RED}${BOLD}  ⚠  UNINSTALL - This will remove the SSH VPN Panel  ⚠${RESET}\n"

    if [[ "${INTERACTIVE}" == "yes" ]]; then
        echo -ne "${YELLOW}  Are you sure you want to uninstall? [y/N]: ${RESET}"
        local confirm
        read -r confirm
        [[ "${confirm,,}" != "y" ]] && echo "Aborted." && exit 0
    fi

    print_step "Uninstalling SSH VPN Panel..."

    # Stop services
    systemctl stop sshvpnpanel-maintenance.timer 2>/dev/null || true
    systemctl disable sshvpnpanel-maintenance.timer 2>/dev/null || true

    # Remove files
    rm -f /usr/local/bin/sshvpnpanel
    rm -f /etc/systemd/system/sshvpnpanel-*.service
    rm -f /etc/systemd/system/sshvpnpanel-*.timer
    rm -f /etc/cron.d/sshvpnpanel
    rm -f /etc/logrotate.d/sshvpnpanel

    if [[ "${INTERACTIVE}" == "yes" ]]; then
        echo -ne "${YELLOW}  Remove all data (configs, users, logs)? [y/N]: ${RESET}"
        local remove_data
        read -r remove_data
        if [[ "${remove_data,,}" == "y" ]]; then
            rm -rf "${INSTALL_DIR}"
            rm -rf "${CONFIG_DIR}"
            rm -rf "${LOG_DIR}"
            print_ok "All data removed"
        else
            print_info "Data kept at: ${CONFIG_DIR}"
        fi
    fi

    systemctl daemon-reload 2>/dev/null || true
    print_ok "SSH VPN Panel uninstalled"
}

# =============================================================================
# UPGRADE
# =============================================================================

upgrade_panel() {
    print_step "Upgrading SSH VPN Panel..."

    # Backup current installation
    local backup_file="${BACKUP_DIR}/pre_upgrade_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "${backup_file}" "${CONFIG_DIR}" "${INSTALL_DIR}/modules" 2>/dev/null || true
    print_ok "Backup created: ${backup_file}"

    # Install new files
    install_panel_files

    # Reload services
    systemctl daemon-reload 2>/dev/null || true

    print_ok "Upgrade complete"
}

# =============================================================================
# MAIN INSTALLER
# =============================================================================

main() {
    # Check for non-interactive mode flags
    if [[ "${UNINSTALL}" == "yes" ]]; then
        check_root
        uninstall_panel
        exit $?
    fi

    if [[ "${UPGRADE}" == "yes" ]]; then
        check_root
        print_banner
        detect_distro
        upgrade_panel
        verify_installation
        exit $?
    fi

    # Full installation
    print_banner

    check_root
    check_bash_version

    print_step "System Detection"
    detect_distro

    if [[ "${INTERACTIVE}" == "yes" ]]; then
        echo
        echo -e "  ${BOLD}Installation Summary:${RESET}"
        echo -e "    Install Dir:  ${INSTALL_DIR}"
        echo -e "    Config Dir:   ${CONFIG_DIR}"
        echo -e "    Log Dir:      ${LOG_DIR}"
        echo -e "    SSH Port:     ${SSH_PORT}"
        echo -e "    SSL Port:     ${SSL_PORT}"
        echo
        echo -ne "${YELLOW}  Proceed with installation? [Y/n]: ${RESET}"
        local confirm
        read -r confirm
        [[ "${confirm,,}" == "n" ]] && echo "Installation cancelled." && exit 0
    fi

    # Run installation steps
    install_dependencies
    create_directories
    install_panel_files
    configure_panel
    configure_ssh
    configure_stunnel
    setup_logrotate
    setup_systemd_service
    setup_cron
    configure_backup
    run_initial_setup
    verify_installation

    # Final message
    echo
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║         SSH VPN Panel - Installation Complete! 🎉               ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${BOLD}Quick Start:${RESET}"
    echo -e "    Run panel:     ${CYAN}sudo sshvpnpanel${RESET}"
    echo -e "    Or:            ${CYAN}sudo ${INSTALL_DIR}/sshvpnpanel.sh${RESET}"
    echo
    echo -e "  ${BOLD}Default Credentials:${RESET}"
    echo -e "    Username:      ${CYAN}admin${RESET}"
    echo -e "    Password:      ${CYAN}(set during installation)${RESET}"
    echo
    echo -e "  ${BOLD}Important Files:${RESET}"
    echo -e "    Config:        ${CYAN}${CONFIG_DIR}/sshvpnpanel.conf${RESET}"
    echo -e "    Logs:          ${CYAN}${LOG_DIR}/${RESET}"
    echo -e "    SSL Certs:     ${CYAN}${CONFIG_DIR}/certs/${RESET}"
    echo
    print_warn "Remember to configure your firewall and change the default password!"
    echo
}

main "$@"
