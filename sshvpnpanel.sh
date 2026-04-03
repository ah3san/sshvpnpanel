#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - Main Script
# =============================================================================
# A comprehensive SSH/VPN management panel with support for:
#   - SSH user management (create/delete/modify, keys, quotas)
#   - Stunnel SSL/TLS tunnel management
#   - TLS/SNI multi-domain certificate handling
#   - VPN user management with bandwidth & expiry controls
#   - Real-time system monitoring and dashboard
#   - Security management (firewall, IP lists, fail2ban, RBAC)
#   - Backup and restore functionality
#   - Comprehensive logging and audit trails
#
# Usage:
#   sudo sshvpnpanel [OPTIONS]
#
# Options:
#   --maintenance     Run maintenance tasks (for cron/systemd)
#   --cleanup-expired Remove expired users
#   --renew-certs     Auto-renew expiring certificates
#   --backup          Create a configuration backup
#   --rotate-logs     Rotate log files
#   --no-auth         Skip authentication (use with caution)
#   --debug           Enable debug mode
#   --version         Show version
#   --help            Show this help
#
# Requirements:
#   - Bash 4.0+
#   - Root privileges
#   - Linux (Ubuntu/Debian, CentOS/RHEL, Alpine)
#
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# =============================================================================
# SCRIPT METADATA
# =============================================================================

readonly PANEL_SCRIPT_VERSION="1.0.0"
readonly PANEL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PANEL_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# =============================================================================
# DEFAULT CONFIGURATION PATHS
# =============================================================================

# These can be overridden by environment variables or the config file
PANEL_BASE_DIR="${PANEL_BASE_DIR:-/etc/sshvpnpanel}"
PANEL_INSTALL_DIR="${PANEL_INSTALL_DIR:-${PANEL_SCRIPT_DIR}}"
PANEL_CONFIG_FILE="${PANEL_CONFIG_FILE:-${PANEL_BASE_DIR}/sshvpnpanel.conf}"
PANEL_LOG_DIR="${PANEL_LOG_DIR:-/var/log/sshvpnpanel}"
PANEL_BACKUP_DIR="${PANEL_BACKUP_DIR:-/var/backups/sshvpnpanel}"
PANEL_TMP_DIR="/tmp/sshvpnpanel"

# =============================================================================
# COMMAND LINE ARGUMENT PARSING
# =============================================================================

MODE="interactive"
SKIP_AUTH=no
DEBUG=no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --maintenance)   MODE="maintenance" ;;
        --cleanup-expired) MODE="cleanup" ;;
        --renew-certs)   MODE="renew-certs" ;;
        --backup)        MODE="backup" ;;
        --rotate-logs)   MODE="rotate-logs" ;;
        --no-auth)       SKIP_AUTH=yes ;;
        --debug)         DEBUG=yes; set -x ;;
        --version)
            echo "SSH VPN Panel v${PANEL_SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            cat << 'HELP_EOF'
SSH VPN Panel - Comprehensive SSH/VPN Management System

Usage: sudo sshvpnpanel [OPTIONS]

Options:
  --maintenance       Run scheduled maintenance tasks
  --cleanup-expired   Remove expired users
  --renew-certs       Auto-renew expiring SSL certificates
  --backup            Create configuration backup
  --rotate-logs       Rotate log files
  --no-auth           Skip panel authentication (not recommended)
  --debug             Enable debug mode (verbose output)
  --version           Show version information
  --help              Show this help message

Interactive Mode (default):
  Run without options to start the interactive menu panel.

Examples:
  sudo sshvpnpanel                     # Start interactive panel
  sudo sshvpnpanel --maintenance       # Run maintenance tasks
  sudo sshvpnpanel --backup            # Create backup
  sudo sshvpnpanel --cleanup-expired   # Remove expired users
HELP_EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
    shift
done

# =============================================================================
# MODULE LOADING
# =============================================================================

_load_modules() {
    local modules_dir="${PANEL_INSTALL_DIR}/modules"

    # Fallback to script directory if modules dir not found
    if [[ ! -d "${modules_dir}" ]]; then
        modules_dir="${PANEL_SCRIPT_DIR}/modules"
    fi

    if [[ ! -d "${modules_dir}" ]]; then
        echo "ERROR: Modules directory not found: ${modules_dir}" >&2
        echo "Please ensure the panel is properly installed." >&2
        exit 1
    fi

    # Load modules in dependency order
    local required_modules=(
        "utilities"
        "ssh_management"
        "stunnel_config"
        "tls_sni"
        "vpn_users"
        "monitoring"
        "security"
    )

    for module in "${required_modules[@]}"; do
        local module_file="${modules_dir}/${module}.sh"
        if [[ -f "${module_file}" ]]; then
            # shellcheck source=/dev/null
            source "${module_file}"
        else
            echo "WARNING: Module not found: ${module_file}" >&2
        fi
    done
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

_load_config() {
    local config_file="${PANEL_CONFIG_FILE}"

    # Try to find config file
    if [[ ! -f "${config_file}" ]]; then
        # Try relative location (dev mode)
        local alt_config="${PANEL_SCRIPT_DIR}/config/sshvpnpanel.conf"
        if [[ -f "${alt_config}" ]]; then
            config_file="${alt_config}"
        else
            # Use built-in defaults - create minimal config
            mkdir -p "${PANEL_BASE_DIR}" 2>/dev/null || PANEL_BASE_DIR="/tmp/sshvpnpanel"
            config_file="${PANEL_BASE_DIR}/sshvpnpanel.conf"
        fi
    fi

    if [[ -f "${config_file}" ]]; then
        # shellcheck source=/dev/null
        source "${config_file}"
        PANEL_CONFIG_FILE="${config_file}"
    fi

    # Override with environment if set
    LOG_DIR="${PANEL_LOG_DIR:-${LOG_DIR:-/var/log/sshvpnpanel}}"
    BACKUP_DIR="${PANEL_BACKUP_DIR:-${BACKUP_DIR:-/var/backups/sshvpnpanel}}"
    TMP_DIR="${PANEL_TMP_DIR}"
    CERT_DIR="${CERT_DIR:-${PANEL_BASE_DIR}/certs}"
    USER_DATA_DIR="${USER_DATA_DIR:-${PANEL_BASE_DIR}/users}"
    STUNNEL_DIR="${STUNNEL_DIR:-${PANEL_BASE_DIR}/stunnel}"

    # Debug mode
    [[ "${DEBUG}" == "yes" ]] && LOG_LEVEL="DEBUG"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

_initialize() {
    # Create essential directories
    local dirs=(
        "${PANEL_BASE_DIR}"
        "${LOG_DIR}"
        "${BACKUP_DIR}"
        "${TMP_DIR}"
        "${CERT_DIR}"
        "${USER_DATA_DIR}"
        "${STUNNEL_DIR}/tunnels"
        "${PANEL_BASE_DIR}/admins"
        "${PANEL_BASE_DIR}/sni"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}" 2>/dev/null || true
    done

    # Initialize subsystems
    init_utilities 2>/dev/null || true
    init_ssh_management 2>/dev/null || true
    init_stunnel_management 2>/dev/null || true
    init_tls_sni 2>/dev/null || true
    init_vpn_management 2>/dev/null || true
    init_security 2>/dev/null || true

    log_info "SSH VPN Panel v${PANEL_SCRIPT_VERSION} started"
}

# =============================================================================
# BACKUP & RESTORE
# =============================================================================

create_backup() {
    require_root || return 1

    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local backup_file="${BACKUP_DIR}/sshvpnpanel_backup_${timestamp}.tar.gz"

    mkdir -p "${BACKUP_DIR}" 2>/dev/null

    print_info "Creating backup..."

    local backup_dirs=("${PANEL_BASE_DIR}")
    [[ -d "${LOG_DIR}" ]] && backup_dirs+=("${LOG_DIR}")

    # Create backup
    if tar -czf "${backup_file}" "${backup_dirs[@]}" 2>/dev/null; then
        print_success "Backup created: ${backup_file}"
        print_info "Size: $(du -sh "${backup_file}" | awk '{print $1}')"

        # Encrypt if configured
        if [[ "${BACKUP_ENCRYPTION:-no}" == "yes" && -n "${BACKUP_PASSPHRASE:-}" ]]; then
            openssl enc -aes-256-cbc -pbkdf2 -pass "pass:${BACKUP_PASSPHRASE}" \
                -in "${backup_file}" -out "${backup_file}.enc" 2>/dev/null && \
            rm -f "${backup_file}" && \
            backup_file="${backup_file}.enc"
            print_success "Backup encrypted"
        fi

        # Remote backup
        if [[ "${REMOTE_BACKUP:-no}" == "yes" && -n "${REMOTE_BACKUP_DEST:-}" ]]; then
            print_info "Copying to remote destination..."
            scp "${backup_file}" "${REMOTE_BACKUP_DEST}/" 2>/dev/null && \
                print_success "Remote backup complete" || \
                print_warning "Remote backup failed"
        fi

        # Retain only N most recent backups
        local retain="${BACKUP_RETAIN:-7}"
        find "${BACKUP_DIR}" -name "sshvpnpanel_backup_*.tar.gz*" -type f | \
            sort -r | tail -n +"$((retain+1))" | xargs rm -f 2>/dev/null || true

        log_audit "backup_create" "file=${backup_file}"
        return 0
    else
        print_error "Backup failed"
        return 1
    fi
}

restore_backup() {
    require_root || return 1

    clear_screen
    print_header "Restore from Backup"

    # List available backups
    if [[ ! -d "${BACKUP_DIR}" ]] || [[ -z "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]]; then
        print_info "No backups found in ${BACKUP_DIR}"
        return 1
    fi

    echo -e "\n${C_BOLD}Available Backups:${C_RESET}"
    local backups=()
    local i=0
    while IFS= read -r f; do
        (( i++ ))
        local size
        size="$(du -sh "${f}" | awk '{print $1}')"
        echo -e "  ${i}. $(basename "${f}") (${size})"
        backups+=("${f}")
    done < <(find "${BACKUP_DIR}" -name "sshvpnpanel_backup_*" -type f | sort -r)

    echo
    local choice
    choice="$(read_int "Select backup to restore" 1 "${#backups[@]}")"
    local selected="${backups[$((choice-1))]}"

    print_warning "This will overwrite existing configuration!"
    confirm "Restore from $(basename "${selected}")?" "no" || return 0

    # Create pre-restore backup
    create_backup

    local restore_file="${selected}"

    # Decrypt if needed
    if [[ "${restore_file}" == *.enc ]]; then
        local passphrase
        read_password "Backup decryption passphrase" passphrase
        local decrypted="${restore_file%.enc}"
        openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${passphrase}" \
            -in "${restore_file}" -out "${decrypted}" 2>/dev/null || {
            print_error "Decryption failed"
            return 1
        }
        restore_file="${decrypted}"
    fi

    # Extract backup
    if tar -xzf "${restore_file}" -C / 2>/dev/null; then
        print_success "Backup restored successfully"
        print_warning "Please restart services for changes to take effect"
        log_audit "backup_restore" "file=$(basename "${selected}")"
    else
        print_error "Restore failed"
        return 1
    fi

    # Cleanup temp decrypted file
    [[ "${restore_file}" != "${selected}" ]] && rm -f "${restore_file}"
}

list_backups() {
    clear_screen
    print_header "Available Backups"

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        print_info "Backup directory not found: ${BACKUP_DIR}"
        return
    fi

    local count=0
    print_table_header "Filename" "Date" "Size"

    while IFS= read -r f; do
        (( count++ ))
        local fname
        fname="$(basename "${f}")"
        local fdate
        fdate="$(stat -c '%y' "${f}" 2>/dev/null | cut -d. -f1)"
        local fsize
        fsize="$(du -sh "${f}" | awk '{print $1}')"
        printf "  %-42s %-22s %s\n" "${fname}" "${fdate}" "${fsize}"
    done < <(find "${BACKUP_DIR}" -name "sshvpnpanel_backup_*" -type f | sort -r)

    echo
    print_info "Total backups: ${count}"
}

# =============================================================================
# CONFIGURATION MANAGEMENT MENU
# =============================================================================

config_menu() {
    while true; do
        clear_screen
        print_header "Configuration & Backup"

        echo -e "${C_BOLD}Configuration:${C_RESET}"
        echo "  1. View Current Configuration"
        echo "  2. Edit Configuration"
        echo "  3. Validate Configuration"
        echo
        echo -e "${C_BOLD}Backup & Restore:${C_RESET}"
        echo "  4. Create Backup Now"
        echo "  5. Restore from Backup"
        echo "  6. List Backups"
        echo "  7. Schedule Backup"
        echo
        echo -e "${C_BOLD}Import/Export:${C_RESET}"
        echo "  8. Export User Data"
        echo "  9. Import User Data"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 9)"

        case "${choice}" in
            1) _view_config ;;
            2) _edit_config ;;
            3) _validate_config ;;
            4) create_backup; read -rp $'\nPress Enter to continue...' ;;
            5) restore_backup; read -rp $'\nPress Enter to continue...' ;;
            6) list_backups; read -rp $'\nPress Enter to continue...' ;;
            7) _schedule_backup ;;
            8) _export_users ;;
            9) _import_users ;;
            0) return 0 ;;
        esac
    done
}

_view_config() {
    clear_screen
    print_header "Configuration"
    if [[ -f "${PANEL_CONFIG_FILE}" ]]; then
        grep -v '^#\|^$' "${PANEL_CONFIG_FILE}" | head -50 | while IFS= read -r line; do
            echo -e "  ${C_DIM}${line}${C_RESET}"
        done
    else
        print_info "Config file not found: ${PANEL_CONFIG_FILE}"
    fi
    read -rp $'\nPress Enter to continue...'
}

_edit_config() {
    local editor="${EDITOR:-nano}"
    command -v "${editor}" &>/dev/null || editor="vi"
    command -v "${editor}" &>/dev/null || {
        print_error "No text editor found. Install nano or vi."
        read -rp $'\nPress Enter...'
        return
    }
    "${editor}" "${PANEL_CONFIG_FILE}"
}

_validate_config() {
    clear_screen
    print_header "Configuration Validation"

    if bash -n "${PANEL_SCRIPT_DIR}/modules/"*.sh 2>&1; then
        print_success "All module scripts have valid syntax"
    else
        print_error "Syntax errors found in modules"
    fi

    local required_keys=(PANEL_VERSION ADMIN_USER PANEL_BASE_DIR USER_DATA_DIR
                        LOG_DIR BACKUP_DIR SSH_PORT STUNNEL_SSL_PORT)
    local errors=0

    for key in "${required_keys[@]}"; do
        local val
        val="$(config_get "${PANEL_CONFIG_FILE}" "${key}")"
        if [[ -n "${val}" ]]; then
            print_success "${key}: ${val}"
        else
            print_warning "${key}: not set (using default)"
        fi
    done

    [[ "${errors}" -eq 0 ]] && print_success "Configuration validation passed"
    read -rp $'\nPress Enter to continue...'
}

_schedule_backup() {
    clear_screen
    print_header "Schedule Automatic Backup"
    print_info "Current: ${BACKUP_FREQUENCY:-daily} (retain ${BACKUP_RETAIN:-7})"
    echo

    echo "  1. Daily"
    echo "  2. Weekly"
    echo "  3. Monthly"
    echo "  4. Disable"
    local choice
    choice="$(read_int "Select frequency" 1 4)"

    local frequencies=("daily" "weekly" "monthly" "none")
    config_set "${PANEL_CONFIG_FILE}" "BACKUP_FREQUENCY" "${frequencies[$((choice-1))]}"
    config_set "${PANEL_CONFIG_FILE}" "AUTO_BACKUP" \
        "$([ "${choice}" -eq 4 ] && echo "no" || echo "yes")"

    print_success "Backup schedule updated"
    read -rp $'\nPress Enter to continue...'
}

_export_users() {
    clear_screen
    print_header "Export User Data"

    local export_file="${BACKUP_DIR}/users_export_$(date +%Y%m%d_%H%M%S).csv"
    mkdir -p "${BACKUP_DIR}" 2>/dev/null

    echo "username,type,status,expiry,bandwidth_limit,protocol,created" > "${export_file}"

    local count=0
    while IFS= read -r -d '' user_dir; do
        local username
        username="$(basename "${user_dir}")"

        # Check SSH user
        local ssh_file="${user_dir}/ssh.conf"
        if [[ -f "${ssh_file}" ]]; then
            local expiry
            expiry="$(config_get "${ssh_file}" "EXPIRY_DATE" "never")"
            local status
            status="$(config_get "${ssh_file}" "STATUS" "active")"
            local bw
            bw="$(config_get "${ssh_file}" "BANDWIDTH_LIMIT" "0")"
            local created
            created="$(config_get "${ssh_file}" "CREATED")"
            echo "${username},ssh,${status},${expiry},${bw},,${created}" >> "${export_file}"
            (( count++ ))
        fi

        # Check VPN user
        local vpn_file="${user_dir}/vpn.conf"
        if [[ -f "${vpn_file}" ]]; then
            local expiry
            expiry="$(config_get "${vpn_file}" "EXPIRY_DATE" "never")"
            local status
            status="$(config_get "${vpn_file}" "STATUS" "active")"
            local bw
            bw="$(config_get "${vpn_file}" "BANDWIDTH_LIMIT" "0")"
            local protocol
            protocol="$(config_get "${vpn_file}" "PROTOCOL" "ssh")"
            local created
            created="$(config_get "${vpn_file}" "CREATED")"
            echo "${username},vpn,${status},${expiry},${bw},${protocol},${created}" \
                >> "${export_file}"
        fi
    done < <(find "${USER_DATA_DIR:-/etc/sshvpnpanel/users}" \
        -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    print_success "Exported ${count} users to: ${export_file}"
    log_audit "users_export" "file=${export_file},count=${count}"
    read -rp $'\nPress Enter to continue...'
}

_import_users() {
    clear_screen
    print_header "Import User Data"
    print_warning "Import from CSV file (format: username,type,status,expiry,bandwidth,protocol,created)"

    local import_file
    read_input "CSV file path" "" import_file
    [[ -z "${import_file}" ]] && return

    if [[ ! -f "${import_file}" ]]; then
        print_error "File not found: ${import_file}"
        read -rp $'\nPress Enter to continue...'
        return
    fi

    local imported=0
    local errors=0
    local default_pass
    read_password "Default password for imported users" default_pass
    [[ -z "${default_pass}" ]] && default_pass="$(random_password 12)"

    while IFS=',' read -r username type status expiry bw protocol created; do
        [[ "${username}" == "username" ]] && continue  # Skip header
        [[ -z "${username}" ]] && continue

        if validate_username "${username}" 2>/dev/null; then
            local expiry_days=30
            if [[ "${expiry}" != "never" && "${expiry}" != "" ]]; then
                local expiry_epoch
                expiry_epoch="$(date -d "${expiry}" +%s 2>/dev/null || echo 0)"
                local now_epoch
                now_epoch="$(date +%s)"
                expiry_days=$(( (expiry_epoch - now_epoch) / 86400 ))
                [[ "${expiry_days}" -lt 0 ]] && expiry_days=0
            fi

            case "${type}" in
                ssh)
                    create_ssh_user "${username}" "${default_pass}" "${expiry_days}" \
                        "${bw:-0}" 2 2>/dev/null && (( imported++ )) || (( errors++ ))
                    ;;
                vpn)
                    create_vpn_user "${username}" "${default_pass}" "${expiry_days}" \
                        "${bw:-0}" 2 "${protocol:-both}" 2>/dev/null && \
                    (( imported++ )) || (( errors++ ))
                    ;;
            esac
        else
            (( errors++ ))
        fi
    done < "${import_file}"

    print_success "Imported: ${imported} users"
    [[ "${errors}" -gt 0 ]] && print_warning "Errors: ${errors}"
    log_audit "users_import" "file=${import_file},imported=${imported},errors=${errors}"
    read -rp $'\nPress Enter to continue...'
}

# =============================================================================
# MAINTENANCE MODE
# =============================================================================

run_maintenance() {
    log_info "Running scheduled maintenance..."

    local tasks=(
        "cleanup_expired_ssh_users"
        "cleanup_expired_vpn_users"
        "auto_renew_certificates"
        "update_online_status"
        "rotate_logs"
    )

    for task in "${tasks[@]}"; do
        if declare -f "${task}" &>/dev/null; then
            log_info "Running maintenance task: ${task}"
            "${task}" 2>/dev/null || log_warn "Task failed: ${task}"
        fi
    done

    # Create backup if auto-backup enabled
    if [[ "${AUTO_BACKUP:-yes}" == "yes" ]]; then
        create_backup 2>/dev/null || log_warn "Auto-backup failed"
    fi

    log_info "Maintenance complete"
}

# =============================================================================
# MAIN INTERACTIVE MENU
# =============================================================================

main_menu() {
    while true; do
        clear_screen

        # Show quick stats
        local cpu_usage
        cpu_usage="$(get_cpu_usage 2>/dev/null || echo "?")"
        local mem_info
        mem_info="$(get_memory_info 2>/dev/null || echo "")"
        local mem_pct="?"
        if [[ -n "${mem_info}" ]]; then
            eval "${mem_info}" 2>/dev/null || true
            mem_pct="${pct:-?}"
        fi

        local ssh_sessions
        ssh_sessions="$(get_logged_in_users 2>/dev/null || echo "0")"

        # Count users
        local user_count=0
        [[ -d "${USER_DATA_DIR:-/etc/sshvpnpanel/users}" ]] && \
            user_count="$(find "${USER_DATA_DIR:-/etc/sshvpnpanel/users}" \
                -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"

        # Service status
        local ssh_status
        ssh_status="$(service_status "${SSH_SERVICE:-sshd}" 2>/dev/null || echo "?")"
        local stunnel_status
        stunnel_status="$(service_status "${STUNNEL_SERVICE:-stunnel4}" 2>/dev/null || echo "?")"

        # Quick status bar
        echo -e "  ${C_DIM}CPU: ${cpu_usage}%  Mem: ${mem_pct}%  SSH Sessions: ${ssh_sessions}  Users: ${user_count}${C_RESET}"
        echo -e "  ${C_DIM}SSH: $([ "${ssh_status}" == "running" ] && echo "${C_SUCCESS}●${C_RESET}" || echo "${C_ERROR}●${C_RESET}")  Stunnel: $([ "${stunnel_status}" == "running" ] && echo "${C_SUCCESS}●${C_RESET}" || echo "${C_ERROR}●${C_RESET}")  Admin: ${C_BOLD}${CURRENT_USER:-unknown}${C_RESET} (${CURRENT_ROLE:-unknown})${C_RESET}"
        echo

        print_separator 70

        echo -e "  ${C_BOLD}1.${C_RESET} SSH User Management        ${C_DIM}Add/delete/modify SSH accounts${C_RESET}"
        echo -e "  ${C_BOLD}2.${C_RESET} Stunnel Management          ${C_DIM}SSL/TLS tunnel configuration${C_RESET}"
        echo -e "  ${C_BOLD}3.${C_RESET} TLS/SNI Configuration       ${C_DIM}Multi-domain SSL & SNI routing${C_RESET}"
        echo -e "  ${C_BOLD}4.${C_RESET} VPN User Management         ${C_DIM}VPN users, bandwidth & expiry${C_RESET}"
        echo -e "  ${C_BOLD}5.${C_RESET} System Monitoring           ${C_DIM}Dashboard, stats & alerts${C_RESET}"
        echo -e "  ${C_BOLD}6.${C_RESET} Security Management         ${C_DIM}Firewall, IP lists & auth${C_RESET}"
        echo -e "  ${C_BOLD}7.${C_RESET} Configuration & Backup      ${C_DIM}Settings, backup & restore${C_RESET}"
        echo

        print_separator 70

        echo -e "  ${C_BOLD}8.${C_RESET} Quick Dashboard"
        echo -e "  ${C_BOLD}9.${C_RESET} Check System Alerts"
        echo -e "  ${C_BOLD}r.${C_RESET} Restart All Services"
        echo -e "  ${C_BOLD}l.${C_RESET} Lock Screen / Logout"
        echo -e "  ${C_BOLD}q.${C_RESET} Quit"
        echo

        echo -ne "${C_INPUT}Select option: ${C_RESET}"
        local choice
        read -r choice

        case "${choice,,}" in
            1) ssh_management_menu ;;
            2) stunnel_management_menu ;;
            3) tls_sni_menu ;;
            4) vpn_management_menu ;;
            5) monitoring_menu ;;
            6) security_menu ;;
            7) config_menu ;;
            8)
                clear_screen
                show_dashboard 2>/dev/null
                read -rp $'\nPress Enter to continue...'
                ;;
            9)
                clear_screen
                check_system_alerts 2>/dev/null
                read -rp $'\nPress Enter to continue...'
                ;;
            r)
                print_info "Restarting services..."
                service_restart "${SSH_SERVICE:-sshd}" 2>/dev/null && \
                    print_success "SSH restarted" || print_error "SSH restart failed"
                service_restart "${STUNNEL_SERVICE:-stunnel4}" 2>/dev/null && \
                    print_success "Stunnel restarted" || print_warning "Stunnel restart failed"
                read -rp $'\nPress Enter to continue...'
                ;;
            l)
                panel_logout 2>/dev/null
                # Re-authenticate
                panel_login || exit 0
                ;;
            q|quit|exit|0)
                clear
                echo -e "${C_SUCCESS}Goodbye!${C_RESET}"
                exit 0
                ;;
            *)
                print_error "Invalid option: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main() {
    # Load modules first (before config, as config uses utility functions)
    _load_modules

    # Load configuration
    _load_config

    # Initialize subsystems
    _initialize

    # Handle non-interactive modes
    case "${MODE}" in
        maintenance)
            run_maintenance
            exit 0
            ;;
        cleanup)
            require_root || exit 1
            cleanup_expired_ssh_users 2>/dev/null
            cleanup_expired_vpn_users 2>/dev/null
            exit 0
            ;;
        renew-certs)
            require_root || exit 1
            auto_renew_certificates 2>/dev/null
            exit 0
            ;;
        backup)
            require_root || exit 1
            create_backup
            exit $?
            ;;
        rotate-logs)
            require_root || exit 1
            rotate_logs 2>/dev/null
            exit 0
            ;;
    esac

    # Interactive mode - require root
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "\033[0;31m[✗] This panel requires root privileges\033[0m"
        echo "    Run: sudo sshvpnpanel"
        exit 1
    fi

    # Authentication
    if [[ "${SKIP_AUTH}" != "yes" ]]; then
        if ! check_session 2>/dev/null; then
            if ! panel_login 2>/dev/null; then
                echo "Authentication failed"
                exit 1
            fi
        fi
    fi

    # Set terminal title
    echo -ne "\033]0;SSH VPN Panel v${PANEL_SCRIPT_VERSION}\007" 2>/dev/null || true

    # Start interactive menu
    main_menu
}

main "$@"
