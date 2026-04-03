#!/usr/bin/env bash
################################################################################
#  SSH VPN Panel v1.0.0
#
#  A comprehensive SSH VPN management panel with:
#    - SSH user management (add/remove/list/info)
#    - Stunnel SSL/TLS tunnel management
#    - TLS/SNI certificate management
#    - VPN user profile management
#    - Firewall (iptables/ufw) per-user rules
#    - Bandwidth monitoring and reporting
#    - Batch user operations (CSV/JSON import)
#    - User suspension/reactivation
#    - System monitoring dashboard
#
#  Requirements: bash >= 4.0, root/sudo access
#  Supported distros: Ubuntu 20.04+, Debian 10+, CentOS/RHEL 7+
#
#  Usage:
#    sudo ./sshvpnpanel.sh            # Interactive menu
#    sudo ./sshvpnpanel.sh --help     # Show help
#    sudo ./sshvpnpanel.sh user add   # Add user (interactive)
#    sudo ./sshvpnpanel.sh user remove USERNAME
#    sudo ./sshvpnpanel.sh user list
#    sudo ./sshvpnpanel.sh user info  USERNAME
#    sudo ./sshvpnpanel.sh batch add  users.csv
#    sudo ./sshvpnpanel.sh batch remove userlist.txt
#    sudo ./sshvpnpanel.sh monitor    # Show system dashboard
#    sudo ./sshvpnpanel.sh stunnel list
#    sudo ./sshvpnpanel.sh export csv [output_file]
################################################################################

set -euo pipefail

PANEL_VERSION="1.0.0"
PANEL_NAME="SSH VPN Panel"

# Determine the real directory of this script (follows symlinks)
PANEL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODULES_DIR="${PANEL_DIR}/modules"
CONFIG_FILE="${PANEL_CONFIG_DIR:-/etc/sshvpnpanel}/sshvpnpanel.conf"

# Fall back to bundled config if system config is absent
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="${PANEL_DIR}/config/sshvpnpanel.conf"
fi

# ---------------------------------------------------------------------------
# Bootstrap: load utilities and config
# ---------------------------------------------------------------------------
if [[ ! -d "$MODULES_DIR" ]]; then
    echo "ERROR: Modules directory not found: ${MODULES_DIR}" >&2
    echo "       Run the installer first: sudo ./installer.sh" >&2
    exit 1
fi

# shellcheck source=modules/utilities.sh
source "${MODULES_DIR}/utilities.sh"
load_config "$CONFIG_FILE"

# Ensure log directory exists
ensure_dir "${PANEL_LOG_DIR}" 750 root 2>/dev/null || true

# ---------------------------------------------------------------------------
# Load all modules
# ---------------------------------------------------------------------------
_load_modules() {
    local mod_list=(
        "ssh_management.sh"
        "stunnel_config.sh"
        "tls_sni.sh"
        "security.sh"
        "vpn_users.sh"
        "monitoring.sh"
        "user_add.sh"
        "user_remove.sh"
    )
    for mod in "${mod_list[@]}"; do
        local mod_path="${MODULES_DIR}/${mod}"
        if [[ -f "$mod_path" ]]; then
            # shellcheck source=/dev/null
            source "$mod_path"
        else
            log_warn "Module not found: ${mod_path}"
        fi
    done
}

_load_modules

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------
usage() {
    cat << EOF
${BOLD}${CYAN}${PANEL_NAME} v${PANEL_VERSION}${RESET}

Usage: sudo $0 [COMMAND] [SUBCOMMAND] [ARGS...]

${BOLD}User Management:${RESET}
  user add                    Interactive user add (all services)
  user add USERNAME           Add user with prompts for options
  user remove                 Interactive user remove
  user remove USERNAME        Remove user (interactive confirm)
  user suspend USERNAME       Suspend user account
  user reactivate USERNAME    Reactivate suspended user
  user info USERNAME          Show full user information
  user list                   List all VPN users
  user trial USERNAME [days]  Create a temporary/trial user

${BOLD}Batch Operations:${RESET}
  batch add csv CSVFILE       Add users from CSV file
  batch add json JSONFILE     Add users from JSON file
  batch remove LISTFILE       Remove users from a list file

${BOLD}Export:${RESET}
  export csv [OUTFILE]        Export user list to CSV

${BOLD}SSH:${RESET}
  ssh list                    List SSH users
  ssh info USERNAME           Show SSH user info
  ssh keys generate USERNAME  Generate SSH key pair
  ssh keys revoke USERNAME    Revoke SSH keys

${BOLD}Stunnel:${RESET}
  stunnel list                List Stunnel configurations
  stunnel info USERNAME       Show Stunnel info for user
  stunnel add USERNAME        Add Stunnel config for user
  stunnel remove USERNAME     Remove Stunnel config for user

${BOLD}TLS/SNI:${RESET}
  tls init-ca                 Initialize internal CA
  tls issue USERNAME [DOMAIN] Issue TLS certificate
  tls revoke USERNAME         Revoke TLS certificate
  sni add USERNAME DOMAIN     Add SNI domain for user
  sni remove USERNAME DOMAIN  Remove SNI domain for user
  sni list USERNAME           List SNI domains for user

${BOLD}Firewall:${RESET}
  firewall defaults           Apply default firewall rules
  firewall list               List whitelisted users
  firewall add USERNAME [IP]  Add user to firewall whitelist
  firewall remove USERNAME    Remove user from firewall

${BOLD}VPN:${RESET}
  vpn list                    List VPN users
  vpn info USERNAME           Show VPN profile

${BOLD}Monitoring:${RESET}
  monitor                     Show system dashboard
  monitor bandwidth USERNAME  Show bandwidth stats for user
  monitor history USERNAME    Show connection history for user

${BOLD}System:${RESET}
  install                     Run installer / apply defaults
  status                      Show service status
  version                     Show panel version

${BOLD}Options:${RESET}
  -h, --help                  Show this help message
  -v, --version               Show version

${BOLD}Environment Variables for 'user add':${RESET}
  EXPIRE_DAYS, QUOTA_MB, BANDWIDTH_LIMIT_MB, MAX_CONNECTIONS,
  STUNNEL_ENABLED, STUNNEL_PORT, STUNNEL_DOMAIN, TLS_ENABLED,
  TLS_DOMAIN, TLS_DAYS, FIREWALL_WHITELIST, FIREWALL_RATE_LIMIT,
  VPN_ENABLED, MONITORING_ENABLED, SSH_GEN_KEYS, SSH_KEY_TYPE,
  SNI_DOMAIN, USER_EMAIL, SEND_WELCOME_EMAIL, TEMPLATE_FILE

${BOLD}Examples:${RESET}
  sudo $0 user add                               # Fully interactive
  sudo $0 user add alice                         # Prompt for options
  sudo EXPIRE_DAYS=7 $0 user add bob myp@ss     # Set options via env
  sudo $0 user remove alice                      # Remove with confirm
  sudo $0 batch add csv /tmp/users.csv           # Batch from CSV
  sudo $0 export csv /tmp/userlist.csv           # Export users
  sudo $0 monitor                                # Live dashboard
EOF
}

# ---------------------------------------------------------------------------
# Main interactive menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        print_header "${PANEL_NAME} v${PANEL_VERSION}"
        echo -e "  ${BOLD}1.${RESET}  Add User"
        echo -e "  ${BOLD}2.${RESET}  Remove User"
        echo -e "  ${BOLD}3.${RESET}  List Users"
        echo -e "  ${BOLD}4.${RESET}  User Information"
        echo -e "  ${BOLD}5.${RESET}  Suspend / Reactivate User"
        echo -e "  ${BOLD}6.${RESET}  Batch Add Users (CSV)"
        echo -e "  ${BOLD}7.${RESET}  Batch Remove Users"
        echo -e "  ${BOLD}8.${RESET}  Export User List"
        echo -e "  ${BOLD}9.${RESET}  Stunnel Management"
        echo -e "  ${BOLD}10.${RESET} TLS/SNI Management"
        echo -e "  ${BOLD}11.${RESET} Firewall Management"
        echo -e "  ${BOLD}12.${RESET} System Monitor / Dashboard"
        echo -e "  ${BOLD}13.${RESET} VPN Users"
        echo -e "  ${BOLD}14.${RESET} SSH Keys"
        echo -e "  ${BOLD}15.${RESET} Trial User"
        echo -e "  ${BOLD}0.${RESET}  Exit"
        echo ""
        prompt_input CHOICE "Select an option" ""
        echo ""

        case "$CHOICE" in
            1)  user_add_interactive ;;
            2)  user_remove_interactive ;;
            3)  ssh_list_users; vpn_list_users ;;
            4)
                prompt_input _USER "Username"
                user_info "$_USER"
                ;;
            5)  _menu_suspend_reactivate ;;
            6)
                prompt_input _CSV "Path to CSV file"
                user_add_batch_csv "$_CSV"
                ;;
            7)
                prompt_input _LIST "Path to user list file"
                user_remove_batch "$_LIST"
                ;;
            8)
                prompt_input _OUT "Output CSV file (leave blank for default)" ""
                user_export_csv "${_OUT:-}"
                ;;
            9)  _menu_stunnel ;;
            10) _menu_tls_sni ;;
            11) _menu_firewall ;;
            12) monitoring_dashboard ;;
            13) vpn_list_users ;;
            14) _menu_ssh_keys ;;
            15)
                prompt_input _USER "Trial username"
                prompt_input _DAYS "Trial duration (days)" "7"
                user_add_trial "$_USER" "$_DAYS"
                ;;
            0)  print_info "Goodbye."; exit 0 ;;
            *)  print_warning "Invalid option." ;;
        esac

        echo ""
        read -r -p "$(echo -e "${DIM}Press Enter to continue...${RESET}")"
    done
}

_menu_suspend_reactivate() {
    echo -e "  ${BOLD}1.${RESET} Suspend user"
    echo -e "  ${BOLD}2.${RESET} Reactivate user"
    prompt_input _CHOICE "Select" ""
    prompt_input _USER "Username"
    case "$_CHOICE" in
        1) user_suspend "$_USER" ;;
        2) user_reactivate "$_USER" ;;
        *) print_warning "Invalid option." ;;
    esac
}

_menu_stunnel() {
    echo -e "  ${BOLD}1.${RESET} List Stunnel configurations"
    echo -e "  ${BOLD}2.${RESET} Show user Stunnel info"
    echo -e "  ${BOLD}3.${RESET} Add Stunnel for user"
    echo -e "  ${BOLD}4.${RESET} Remove Stunnel for user"
    prompt_input _CHOICE "Select" ""
    case "$_CHOICE" in
        1) stunnel_list_users ;;
        2) prompt_input _USER "Username"; stunnel_user_info "$_USER" ;;
        3) prompt_input _USER "Username"; stunnel_add_user "$_USER" ;;
        4) prompt_input _USER "Username"; stunnel_remove_user "$_USER" ;;
        *) print_warning "Invalid option." ;;
    esac
}

_menu_tls_sni() {
    echo -e "  ${BOLD}1.${RESET} Initialize CA"
    echo -e "  ${BOLD}2.${RESET} Issue TLS certificate"
    echo -e "  ${BOLD}3.${RESET} Revoke TLS certificate"
    echo -e "  ${BOLD}4.${RESET} Add SNI domain"
    echo -e "  ${BOLD}5.${RESET} Remove SNI domain"
    echo -e "  ${BOLD}6.${RESET} List SNI domains"
    prompt_input _CHOICE "Select" ""
    case "$_CHOICE" in
        1) tls_init_ca ;;
        2) prompt_input _USER "Username"; prompt_input _DOM "Domain" "${SNI_DEFAULT_DOMAIN:-vpn.example.com}"; tls_issue_cert "$_USER" "$_DOM" ;;
        3) prompt_input _USER "Username"; tls_revoke_cert "$_USER" ;;
        4) prompt_input _USER "Username"; prompt_input _DOM "Domain"; sni_add_domain "$_USER" "$_DOM" ;;
        5) prompt_input _USER "Username"; prompt_input _DOM "Domain"; sni_remove_domain "$_USER" "$_DOM" ;;
        6) prompt_input _USER "Username"; sni_list_domains "$_USER" ;;
        *) print_warning "Invalid option." ;;
    esac
}

_menu_firewall() {
    echo -e "  ${BOLD}1.${RESET} Apply default firewall rules"
    echo -e "  ${BOLD}2.${RESET} List whitelisted users"
    echo -e "  ${BOLD}3.${RESET} Add user to whitelist"
    echo -e "  ${BOLD}4.${RESET} Remove user from whitelist"
    prompt_input _CHOICE "Select" ""
    case "$_CHOICE" in
        1) firewall_apply_defaults ;;
        2) firewall_list_users ;;
        3) prompt_input _USER "Username"; prompt_input _IP "IP address (or ANY)" "ANY"; firewall_add_user "$_USER" "$_IP" ;;
        4) prompt_input _USER "Username"; firewall_remove_user "$_USER" ;;
        *) print_warning "Invalid option." ;;
    esac
}

_menu_ssh_keys() {
    echo -e "  ${BOLD}1.${RESET} Generate SSH keys"
    echo -e "  ${BOLD}2.${RESET} Revoke SSH keys"
    prompt_input _CHOICE "Select" ""
    prompt_input _USER "Username"
    case "$_CHOICE" in
        1) ssh_generate_keys "$_USER" ;;
        2) ssh_revoke_keys "$_USER" ;;
        *) print_warning "Invalid option." ;;
    esac
}

# ---------------------------------------------------------------------------
# CLI command dispatcher
# ---------------------------------------------------------------------------
_dispatch() {
    local cmd="${1:-}"
    local sub="${2:-}"

    case "$cmd" in
        # ---- User management ----
        user)
            case "$sub" in
                add)
                    local uname="${3:-}"
                    local pass="${4:-}"
                    if [[ -z "$uname" ]]; then
                        user_add_interactive
                    else
                        user_add "$uname" "$pass"
                    fi
                    ;;
                remove|rm|delete)
                    local uname="${3:-}"
                    if [[ -z "$uname" ]]; then
                        user_remove_interactive
                    else
                        if ! prompt_confirm "Remove user '${uname}'?" "n"; then
                            print_info "Cancelled."
                            exit 0
                        fi
                        user_remove "$uname"
                    fi
                    ;;
                suspend)   user_suspend "${3:?Usage: user suspend USERNAME}" ;;
                reactivate|activate) user_reactivate "${3:?Usage: user reactivate USERNAME}" ;;
                info)      user_info "${3:?Usage: user info USERNAME}" ;;
                list|ls)   ssh_list_users; vpn_list_users ;;
                trial)     user_add_trial "${3:?Usage: user trial USERNAME}" "${4:-7}" ;;
                *)         usage; exit 1 ;;
            esac
            ;;

        # ---- Batch operations ----
        batch)
            case "$sub" in
                add)
                    local fmt="${3:-csv}"
                    local file="${4:?Usage: batch add [csv|json] FILE}"
                    case "$fmt" in
                        csv)  user_add_batch_csv "$file" ;;
                        json) user_add_batch_json "$file" ;;
                        *)    log_error "Unknown format '${fmt}'. Use csv or json."; exit 1 ;;
                    esac
                    ;;
                remove|rm)
                    user_remove_batch "${3:?Usage: batch remove LISTFILE}"
                    ;;
                *)  usage; exit 1 ;;
            esac
            ;;

        # ---- Export ----
        export)
            case "$sub" in
                csv) user_export_csv "${3:-}" ;;
                *)   usage; exit 1 ;;
            esac
            ;;

        # ---- SSH ----
        ssh)
            case "$sub" in
                list|ls)   ssh_list_users ;;
                info)      ssh_user_info "${3:?Usage: ssh info USERNAME}" ;;
                keys)
                    case "${3:-}" in
                        generate|gen) ssh_generate_keys "${4:?Usage: ssh keys generate USERNAME}" "${5:-ed25519}" ;;
                        revoke)       ssh_revoke_keys "${4:?Usage: ssh keys revoke USERNAME}" ;;
                        *)            usage; exit 1 ;;
                    esac
                    ;;
                reload)    ssh_reload ;;
                *)         usage; exit 1 ;;
            esac
            ;;

        # ---- Stunnel ----
        stunnel)
            case "$sub" in
                list|ls)   stunnel_list_users ;;
                info)      stunnel_user_info "${3:?Usage: stunnel info USERNAME}" ;;
                add)       stunnel_add_user "${3:?Usage: stunnel add USERNAME}" "${4:-}" "${5:-}" ;;
                remove|rm) stunnel_remove_user "${3:?Usage: stunnel remove USERNAME}" ;;
                *)         usage; exit 1 ;;
            esac
            ;;

        # ---- TLS/SNI ----
        tls)
            case "$sub" in
                init-ca|initca) tls_init_ca ;;
                issue)   tls_issue_cert "${3:?Usage: tls issue USERNAME}" "${4:-}" "${5:-}" ;;
                revoke)  tls_revoke_cert "${3:?Usage: tls revoke USERNAME}" ;;
                info)    tls_user_info "${3:?Usage: tls info USERNAME}" ;;
                *)       usage; exit 1 ;;
            esac
            ;;
        sni)
            case "$sub" in
                add)    sni_add_domain "${3:?Usage: sni add USERNAME DOMAIN}" "${4:?}" ;;
                remove|rm) sni_remove_domain "${3:?Usage: sni remove USERNAME DOMAIN}" "${4:?}" ;;
                list|ls)   sni_list_domains "${3:?Usage: sni list USERNAME}" ;;
                *)         usage; exit 1 ;;
            esac
            ;;

        # ---- Firewall ----
        firewall|fw)
            case "$sub" in
                defaults)  firewall_apply_defaults ;;
                list|ls)   firewall_list_users ;;
                add)       firewall_add_user "${3:?Usage: firewall add USERNAME}" "${4:-ANY}" ;;
                remove|rm) firewall_remove_user "${3:?Usage: firewall remove USERNAME}" ;;
                *)         usage; exit 1 ;;
            esac
            ;;

        # ---- VPN ----
        vpn)
            case "$sub" in
                list|ls)  vpn_list_users ;;
                info)     vpn_user_info "${3:?Usage: vpn info USERNAME}" ;;
                *)        usage; exit 1 ;;
            esac
            ;;

        # ---- Monitoring ----
        monitor|monitoring)
            case "$sub" in
                ""|dashboard) monitoring_dashboard ;;
                bandwidth|bw) monitoring_user_bandwidth "${3:?Usage: monitor bandwidth USERNAME}" ;;
                history)      monitoring_connection_history "${3:?Usage: monitor history USERNAME}" ;;
                status)       monitoring_service_status ;;
                *)            usage; exit 1 ;;
            esac
            ;;

        # ---- Install ----
        install) "${PANEL_DIR}/installer.sh" ;;

        # ---- Status ----
        status) monitoring_service_status; monitoring_system_status ;;

        # ---- Version ----
        version|-v|--version)
            echo "${PANEL_NAME} v${PANEL_VERSION}"
            ;;

        # ---- Help ----
        help|-h|--help)
            usage
            ;;

        # ---- Interactive menu (no args) ----
        "")
            check_root || exit 1
            main_menu
            ;;

        *)
            log_error "Unknown command: ${cmd}"
            usage
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    # Show version in non-interactive mode
    if [[ "${1:-}" != "" && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
        log_debug "Starting ${PANEL_NAME} v${PANEL_VERSION} (UID=${EUID:-?})"
    fi
    _dispatch "$@"
}

main "$@"
