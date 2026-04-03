#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - Utilities Module
# =============================================================================
# Shared helper functions, logging, color output, and common utilities
# used across all panel modules.
# =============================================================================

# Prevent direct execution
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# COLOR DEFINITIONS
# =============================================================================

# Text colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_PURPLE='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[0;37m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_DIM='\033[2m'

# Background colors
readonly BG_RED='\033[41m'
readonly BG_GREEN='\033[42m'
readonly BG_YELLOW='\033[43m'
readonly BG_BLUE='\033[44m'

# Reset
readonly COLOR_RESET='\033[0m'

# Semantic aliases
readonly C_ERROR="${COLOR_RED}"
readonly C_SUCCESS="${COLOR_GREEN}"
readonly C_WARNING="${COLOR_YELLOW}"
readonly C_INFO="${COLOR_CYAN}"
readonly C_HEADER="${COLOR_BOLD}${COLOR_BLUE}"
readonly C_TITLE="${COLOR_BOLD}${COLOR_CYAN}"
readonly C_MENU="${COLOR_WHITE}"
readonly C_INPUT="${COLOR_YELLOW}"
readonly C_DATA="${COLOR_GREEN}"
readonly C_DIM="${COLOR_DIM}"
readonly C_BOLD="${COLOR_BOLD}"
readonly C_RESET="${COLOR_RESET}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Internal log function
# Usage: _log LEVEL message
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_entry="[${timestamp}] [${level}] ${message}"

    # Determine log file from config or use default
    local log_file="${MAIN_LOG:-/var/log/sshvpnpanel/sshvpnpanel.log}"

    # Ensure log directory exists
    local log_dir
    log_dir="$(dirname "${log_file}")"
    [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" 2>/dev/null

    # Write to log file if writable
    [[ -w "${log_dir}" ]] && echo "${log_entry}" >> "${log_file}" 2>/dev/null

    # Also write to syslog if enabled
    if [[ "${ENABLE_SYSLOG:-no}" == "yes" ]] && command -v logger &>/dev/null; then
        logger -t "sshvpnpanel" "${level}: ${message}"
    fi
}

# Log debug message
log_debug() {
    [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && _log "DEBUG" "$@"
}

# Log info message
log_info() {
    _log "INFO" "$@"
}

# Log warning message
log_warn() {
    _log "WARN" "$@"
}

# Log error message
log_error() {
    local error_log="${ERROR_LOG:-/var/log/sshvpnpanel/error.log}"
    _log "ERROR" "$@"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_dir
    log_dir="$(dirname "${error_log}")"
    [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" 2>/dev/null
    [[ -w "${log_dir}" ]] && echo "[${timestamp}] [ERROR] $*" >> "${error_log}" 2>/dev/null
}

# Log audit event
log_audit() {
    local event="$1"
    local detail="${2:-}"
    local audit_log="${AUDIT_LOG:-/var/log/sshvpnpanel/audit.log}"

    if [[ "${ENABLE_AUDIT_LOG:-yes}" == "yes" ]]; then
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local user="${CURRENT_USER:-system}"
        local ip="${CLIENT_IP:-local}"
        local log_dir
        log_dir="$(dirname "${audit_log}")"
        [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" 2>/dev/null
        [[ -w "${log_dir}" ]] && \
            echo "[${timestamp}] [AUDIT] user=${user} ip=${ip} event=${event} detail=${detail}" \
            >> "${audit_log}" 2>/dev/null
    fi
}

# =============================================================================
# PRINT/DISPLAY FUNCTIONS
# =============================================================================

# Print success message
print_success() {
    echo -e "${C_SUCCESS}[✓] $*${C_RESET}"
}

# Print error message
print_error() {
    echo -e "${C_ERROR}[✗] $*${C_RESET}" >&2
}

# Print warning message
print_warning() {
    echo -e "${C_WARNING}[!] $*${C_RESET}"
}

# Print info message
print_info() {
    echo -e "${C_INFO}[i] $*${C_RESET}"
}

# Print a section header
print_header() {
    local title="$1"
    local width="${2:-70}"
    local line
    line="$(printf '%*s' "${width}" '' | tr ' ' '=')"
    echo -e "${C_HEADER}${line}${C_RESET}"
    echo -e "${C_TITLE}  ${title}${C_RESET}"
    echo -e "${C_HEADER}${line}${C_RESET}"
}

# Print a sub-header
print_subheader() {
    local title="$1"
    local width="${2:-70}"
    local line
    line="$(printf '%*s' "${width}" '' | tr ' ' '-')"
    echo -e "${C_INFO}${line}${C_RESET}"
    echo -e "${C_BOLD}  ${title}${C_RESET}"
    echo -e "${C_INFO}${line}${C_RESET}"
}

# Print a separator line
print_separator() {
    local width="${1:-70}"
    local char="${2:--}"
    printf "${C_DIM}"
    printf '%*s' "${width}" '' | tr ' ' "${char}"
    printf "${C_RESET}\n"
}

# Print a table row
# Usage: print_table_row "col1" "col2" "col3" ...
print_table_row() {
    local cols=("$@")
    local col_width=20
    local row=""
    for col in "${cols[@]}"; do
        row+="$(printf "%-${col_width}s" "${col}")"
    done
    echo -e "${C_DATA}${row}${C_RESET}"
}

# Print a table header row
print_table_header() {
    local cols=("$@")
    local col_width=20
    local row=""
    for col in "${cols[@]}"; do
        row+="$(printf "%-${col_width}s" "${col}")"
    done
    echo -e "${C_BOLD}${row}${C_RESET}"
    local width=$(( ${#cols[@]} * col_width ))
    print_separator "${width}"
}

# Print a status badge
print_status() {
    local status="$1"
    case "${status,,}" in
        running|active|online|enabled|yes|true)
            echo -e "${BG_GREEN}${COLOR_WHITE} ${status^^} ${C_RESET}"
            ;;
        stopped|inactive|offline|disabled|no|false)
            echo -e "${BG_RED}${COLOR_WHITE} ${status^^} ${C_RESET}"
            ;;
        warning|pending|unknown)
            echo -e "${BG_YELLOW}${COLOR_WHITE} ${status^^} ${C_RESET}"
            ;;
        *)
            echo -e "${C_DIM}${status}${C_RESET}"
            ;;
    esac
}

# Print a progress bar
# Usage: print_progress VALUE MAX [WIDTH]
print_progress() {
    local value="$1"
    local max="$2"
    local width="${3:-40}"

    local filled=$(( value * width / max ))
    [[ ${filled} -gt ${width} ]] && filled=${width}
    local empty=$(( width - filled ))

    local bar=""
    bar+="["
    bar+="$(printf '%*s' "${filled}" '' | tr ' ' '#')"
    bar+="$(printf '%*s' "${empty}" '' | tr ' ' '-')"
    bar+="]"

    local pct=$(( value * 100 / max ))
    local color="${C_SUCCESS}"
    [[ ${pct} -gt 70 ]] && color="${C_WARNING}"
    [[ ${pct} -gt 90 ]] && color="${C_ERROR}"

    echo -e "${color}${bar} ${pct}%${C_RESET}"
}

# Clear screen with panel header
clear_screen() {
    clear
    local panel_name="${PANEL_NAME:-SSH VPN Panel}"
    local panel_version="${PANEL_VERSION:-1.0.0}"
    echo -e "${C_HEADER}"
    printf '%.0s=' {1..70}
    echo
    printf "  %-40s %s\n" "${panel_name}" "v${panel_version}"
    printf '%.0s=' {1..70}
    echo -e "${C_RESET}"
    echo
}

# =============================================================================
# INPUT FUNCTIONS
# =============================================================================

# Read a string input with optional default
# Usage: read_input PROMPT [DEFAULT] [VARIABLE_NAME]
read_input() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="${3:-}"

    if [[ -n "${default}" ]]; then
        echo -ne "${C_INPUT}${prompt} [${default}]: ${C_RESET}"
    else
        echo -ne "${C_INPUT}${prompt}: ${C_RESET}"
    fi

    local value
    read -r value

    if [[ -z "${value}" && -n "${default}" ]]; then
        value="${default}"
    fi

    if [[ -n "${var_name}" ]]; then
        printf -v "${var_name}" '%s' "${value}"
    else
        echo "${value}"
    fi
}

# Read a password (hidden input)
# Usage: read_password PROMPT [VARIABLE_NAME]
read_password() {
    local prompt="$1"
    local var_name="${2:-}"

    echo -ne "${C_INPUT}${prompt}: ${C_RESET}"
    local value
    read -rs value
    echo

    if [[ -n "${var_name}" ]]; then
        printf -v "${var_name}" '%s' "${value}"
    else
        echo "${value}"
    fi
}

# Read a yes/no confirmation
# Usage: confirm PROMPT [DEFAULT=yes]
# Returns 0 for yes, 1 for no
confirm() {
    local prompt="$1"
    local default="${2:-yes}"

    local options
    if [[ "${default,,}" == "yes" ]]; then
        options="[Y/n]"
    else
        options="[y/N]"
    fi

    echo -ne "${C_WARNING}${prompt} ${options}: ${C_RESET}"
    local answer
    read -r answer

    if [[ -z "${answer}" ]]; then
        answer="${default}"
    fi

    case "${answer,,}" in
        y|yes) return 0 ;;
        n|no) return 1 ;;
        *) return 1 ;;
    esac
}

# Read an integer in a range
# Usage: read_int PROMPT MIN MAX [DEFAULT]
read_int() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local default="${4:-}"

    while true; do
        local value
        read_input "${prompt} (${min}-${max})" "${default}" value

        if [[ "${value}" =~ ^[0-9]+$ ]] && \
           [[ "${value}" -ge "${min}" ]] && \
           [[ "${value}" -le "${max}" ]]; then
            echo "${value}"
            return 0
        fi
        print_error "Please enter a number between ${min} and ${max}"
    done
}

# Select from a menu of options
# Usage: select_option PROMPT option1 option2 ...
# Returns selected index (1-based) in SELECTED_INDEX
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local count="${#options[@]}"

    echo
    for i in "${!options[@]}"; do
        echo -e "  ${C_BOLD}$((i+1))${C_RESET}. ${options[${i}]}"
    done
    echo

    local choice
    choice="$(read_int "${prompt}" 1 "${count}")"
    SELECTED_INDEX="${choice}"
    echo "${options[$((choice-1))]}"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate username (alphanumeric, dash, underscore)
validate_username() {
    local username="$1"
    if [[ ! "${username}" =~ ^[a-z][a-z0-9_-]{2,31}$ ]]; then
        print_error "Invalid username. Must start with a letter, be 3-32 chars, and contain only a-z, 0-9, -, _"
        return 1
    fi
    return 0
}

# Validate IPv4 address
validate_ip() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "${ip}" =~ ${regex} ]]; then
        return 1
    fi
    IFS='.' read -r -a parts <<< "${ip}"
    for part in "${parts[@]}"; do
        [[ "${part}" -gt 255 ]] && return 1
    done
    return 0
}

# Validate CIDR notation
validate_cidr() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    validate_ip "${ip}" || return 1
    [[ "${prefix}" =~ ^[0-9]+$ ]] && [[ "${prefix}" -le 32 ]] || return 1
    return 0
}

# Validate port number
validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && [[ "${port}" -ge 1 ]] && [[ "${port}" -le 65535 ]]
}

# Validate domain name
validate_domain() {
    local domain="$1"
    local regex='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    [[ "${domain}" =~ ${regex} ]]
}

# Validate email address
validate_email() {
    local email="$1"
    local regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    [[ "${email}" =~ ${regex} ]]
}

# Validate date format (YYYY-MM-DD)
validate_date() {
    local date_str="$1"
    local regex='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    if [[ ! "${date_str}" =~ ${regex} ]]; then
        return 1
    fi
    # Check if date is valid using date command
    date -d "${date_str}" &>/dev/null 2>&1 || \
    date -j -f "%Y-%m-%d" "${date_str}" &>/dev/null 2>&1
}

# Validate password strength
validate_password() {
    local password="$1"
    local min_length="${MIN_PASSWORD_LENGTH:-8}"

    if [[ ${#password} -lt ${min_length} ]]; then
        print_error "Password must be at least ${min_length} characters"
        return 1
    fi

    if [[ "${REQUIRE_PASSWORD_COMPLEXITY:-yes}" == "yes" ]]; then
        if [[ ! "${password}" =~ [A-Z] ]]; then
            print_error "Password must contain at least one uppercase letter"
            return 1
        fi
        if [[ ! "${password}" =~ [a-z] ]]; then
            print_error "Password must contain at least one lowercase letter"
            return 1
        fi
        if [[ ! "${password}" =~ [0-9] ]]; then
            print_error "Password must contain at least one digit"
            return 1
        fi
    fi
    return 0
}

# =============================================================================
# SYSTEM DETECTION FUNCTIONS
# =============================================================================

# Detect Linux distribution
detect_distro() {
    local distro=""
    local version=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        distro="${ID:-unknown}"
        version="${VERSION_ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        distro="rhel"
        version="$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)"
    elif [[ -f /etc/debian_version ]]; then
        distro="debian"
        version="$(cat /etc/debian_version)"
    fi

    echo "${distro}:${version}"
}

# Get package manager for the current distribution
get_pkg_manager() {
    if [[ -n "${PKG_MANAGER:-}" ]]; then
        echo "${PKG_MANAGER}"
        return
    fi

    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apk &>/dev/null; then
        echo "apk"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# Get service manager
get_service_manager() {
    if [[ -n "${SERVICE_MANAGER:-}" ]]; then
        echo "${SERVICE_MANAGER}"
        return
    fi

    if command -v systemctl &>/dev/null && systemctl &>/dev/null 2>&1; then
        echo "systemd"
    elif command -v service &>/dev/null; then
        echo "sysvinit"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

# Get default network interface
get_default_interface() {
    if [[ -n "${NETWORK_INTERFACE:-}" ]]; then
        echo "${NETWORK_INTERFACE}"
        return
    fi

    local iface
    iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)"
    if [[ -z "${iface}" ]]; then
        iface="$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/ {print $8}' | head -1)"
    fi
    echo "${iface:-eth0}"
}

# Get server's public IP address
get_public_ip() {
    local ip=""
    # Try multiple methods
    if command -v curl &>/dev/null; then
        ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)" || true
    fi
    if [[ -z "${ip}" ]] && command -v wget &>/dev/null; then
        ip="$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null)" || true
    fi
    if [[ -z "${ip}" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    fi
    echo "${ip:-unknown}"
}

# Check if running as root
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_error "This operation requires root privileges"
        print_info "Please run with sudo or as root"
        return 1
    fi
    return 0
}

# =============================================================================
# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================

# Start a service
service_start() {
    local service="$1"
    local svc_mgr
    svc_mgr="$(get_service_manager)"

    case "${svc_mgr}" in
        systemd)
            systemctl start "${service}" 2>&1
            ;;
        sysvinit)
            service "${service}" start 2>&1
            ;;
        openrc)
            rc-service "${service}" start 2>&1
            ;;
        *)
            print_error "Unknown service manager"
            return 1
            ;;
    esac
}

# Stop a service
service_stop() {
    local service="$1"
    local svc_mgr
    svc_mgr="$(get_service_manager)"

    case "${svc_mgr}" in
        systemd)
            systemctl stop "${service}" 2>&1
            ;;
        sysvinit)
            service "${service}" stop 2>&1
            ;;
        openrc)
            rc-service "${service}" stop 2>&1
            ;;
        *)
            print_error "Unknown service manager"
            return 1
            ;;
    esac
}

# Restart a service
service_restart() {
    local service="$1"
    local svc_mgr
    svc_mgr="$(get_service_manager)"

    case "${svc_mgr}" in
        systemd)
            systemctl restart "${service}" 2>&1
            ;;
        sysvinit)
            service "${service}" restart 2>&1
            ;;
        openrc)
            rc-service "${service}" restart 2>&1
            ;;
        *)
            print_error "Unknown service manager"
            return 1
            ;;
    esac
}

# Get service status
service_status() {
    local service="$1"
    local svc_mgr
    svc_mgr="$(get_service_manager)"

    case "${svc_mgr}" in
        systemd)
            if systemctl is-active --quiet "${service}" 2>/dev/null; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        sysvinit)
            if service "${service}" status &>/dev/null 2>&1; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Enable service on boot
service_enable() {
    local service="$1"
    local svc_mgr
    svc_mgr="$(get_service_manager)"

    case "${svc_mgr}" in
        systemd)
            systemctl enable "${service}" 2>&1
            ;;
        openrc)
            rc-update add "${service}" default 2>&1
            ;;
    esac
}

# =============================================================================
# FILE AND DATA UTILITIES
# =============================================================================

# Safely write to a file (atomic write)
safe_write() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp.$$"

    echo "${content}" > "${tmp_file}" || return 1
    mv "${tmp_file}" "${file}" || {
        rm -f "${tmp_file}"
        return 1
    }
}

# Append to a file safely
safe_append() {
    local file="$1"
    local content="$2"
    echo "${content}" >> "${file}"
}

# Read a value from a config file (KEY=VALUE format)
config_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"

    if [[ -f "${file}" ]]; then
        local value
        value="$(grep -E "^${key}=" "${file}" 2>/dev/null | tail -1 | cut -d'=' -f2-)"
        # Remove surrounding quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        echo "${value:-${default}}"
    else
        echo "${default}"
    fi
}

# Set a value in a config file (KEY=VALUE format)
config_set() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
    else
        echo "${key}=${value}" >> "${file}"
    fi
}

# Remove a key from a config file
config_remove() {
    local file="$1"
    local key="$2"
    sed -i "/^${key}=/d" "${file}"
}

# Generate a random string
random_string() {
    local length="${1:-16}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
}

# Generate a random password
random_password() {
    local length="${1:-16}"
    tr -dc 'a-zA-Z0-9!@#$%^&*()_+' < /dev/urandom | head -c "${length}"
}

# Hash a password using SHA-256
hash_password() {
    local password="$1"
    echo -n "${password}" | sha256sum | awk '{print $1}'
}

# Convert bytes to human-readable format
bytes_to_human() {
    local bytes="$1"
    if [[ "${bytes}" -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ "${bytes}" -lt $((1024*1024)) ]]; then
        echo "$(( bytes / 1024 ))KB"
    elif [[ "${bytes}" -lt $((1024*1024*1024)) ]]; then
        echo "$(( bytes / 1024 / 1024 ))MB"
    else
        echo "$(( bytes / 1024 / 1024 / 1024 ))GB"
    fi
}

# Convert seconds to human-readable duration
seconds_to_human() {
    local seconds="$1"
    local days=$(( seconds / 86400 ))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$(( seconds % 60 ))

    if [[ "${days}" -gt 0 ]]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [[ "${hours}" -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${secs}s"
    elif [[ "${minutes}" -gt 0 ]]; then
        echo "${minutes}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if a package is installed
package_installed() {
    local pkg="$1"
    local pkg_mgr
    pkg_mgr="$(get_pkg_manager)"

    case "${pkg_mgr}" in
        apt)
            dpkg -l "${pkg}" &>/dev/null 2>&1
            ;;
        dnf|yum)
            rpm -q "${pkg}" &>/dev/null 2>&1
            ;;
        apk)
            apk info "${pkg}" &>/dev/null 2>&1
            ;;
        *)
            command_exists "${pkg}"
            ;;
    esac
}

# Install a package
install_package() {
    local pkg="$1"
    local pkg_mgr
    pkg_mgr="$(get_pkg_manager)"

    print_info "Installing ${pkg}..."
    case "${pkg_mgr}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" 2>&1
            ;;
        dnf)
            dnf install -y "${pkg}" 2>&1
            ;;
        yum)
            yum install -y "${pkg}" 2>&1
            ;;
        apk)
            apk add --no-cache "${pkg}" 2>&1
            ;;
        *)
            print_error "Cannot install ${pkg}: unknown package manager"
            return 1
            ;;
    esac
}

# =============================================================================
# DATE AND TIME UTILITIES
# =============================================================================

# Get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get current date
get_date() {
    date '+%Y-%m-%d'
}

# Calculate expiry date from today + N days
calc_expiry_date() {
    local days="$1"
    if [[ "${days}" -eq 0 ]]; then
        echo "never"
        return
    fi

    if date -d "+${days} days" &>/dev/null 2>&1; then
        date -d "+${days} days" '+%Y-%m-%d'
    elif date -v "+${days}d" &>/dev/null 2>&1; then
        date -v "+${days}d" '+%Y-%m-%d'
    else
        echo "unknown"
    fi
}

# Check if a date has expired
is_expired() {
    local expiry="$1"
    [[ "${expiry}" == "never" ]] && return 1
    [[ "${expiry}" == "0" ]] && return 1

    local expiry_epoch
    local now_epoch
    now_epoch="$(date +%s)"

    if date -d "${expiry}" &>/dev/null 2>&1; then
        expiry_epoch="$(date -d "${expiry}" +%s)"
    elif date -j -f "%Y-%m-%d" "${expiry}" &>/dev/null 2>&1; then
        expiry_epoch="$(date -j -f "%Y-%m-%d" "${expiry}" +%s)"
    else
        return 1
    fi

    [[ "${now_epoch}" -gt "${expiry_epoch}" ]]
}

# Days until expiry (negative if expired)
days_until_expiry() {
    local expiry="$1"
    [[ "${expiry}" == "never" ]] && echo "∞" && return
    [[ "${expiry}" == "0" ]] && echo "∞" && return

    local expiry_epoch
    local now_epoch
    now_epoch="$(date +%s)"

    if date -d "${expiry}" &>/dev/null 2>&1; then
        expiry_epoch="$(date -d "${expiry}" +%s)"
    elif date -j -f "%Y-%m-%d" "${expiry}" &>/dev/null 2>&1; then
        expiry_epoch="$(date -j -f "%Y-%m-%d" "${expiry}" +%s)"
    else
        echo "unknown"
        return
    fi

    echo "$(( (expiry_epoch - now_epoch) / 86400 ))"
}

# =============================================================================
# NETWORK UTILITIES
# =============================================================================

# Get network interface statistics
get_iface_stats() {
    local iface="${1:-$(get_default_interface)}"

    if [[ -f "/sys/class/net/${iface}/statistics/rx_bytes" ]]; then
        local rx
        local tx
        rx="$(cat "/sys/class/net/${iface}/statistics/rx_bytes")"
        tx="$(cat "/sys/class/net/${iface}/statistics/tx_bytes")"
        echo "rx=${rx} tx=${tx}"
    fi
}

# Check if a port is in use
port_in_use() {
    local port="$1"
    local proto="${2:-tcp}"

    if command_exists ss; then
        ss -ln${proto:0:1} 2>/dev/null | grep -q ":${port} " || \
        ss -ln${proto:0:1} 2>/dev/null | grep -q ":${port}$"
    elif command_exists netstat; then
        netstat -ln 2>/dev/null | grep -q ":${port} "
    fi
}

# Get listening ports
get_listening_ports() {
    if command_exists ss; then
        ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE ':[0-9]+$' | tr -d ':'
    elif command_exists netstat; then
        netstat -tlnp 2>/dev/null | awk 'NR>2 {print $4}' | grep -oE ':[0-9]+$' | tr -d ':'
    fi
}

# =============================================================================
# PAGINATION UTILITIES
# =============================================================================

# Display a paginated list
# Usage: paginate_list ITEMS_PER_PAGE item1 item2 ...
paginate_list() {
    local per_page="$1"
    shift
    local items=("$@")
    local total="${#items[@]}"
    local pages=$(( (total + per_page - 1) / per_page ))
    local page=1

    while true; do
        local start=$(( (page - 1) * per_page ))
        local end=$(( start + per_page - 1 ))
        [[ ${end} -ge ${total} ]] && end=$(( total - 1 ))

        echo
        echo -e "${C_DIM}Page ${page}/${pages} (${total} items)${C_RESET}"
        print_separator

        for (( i=start; i<=end; i++ )); do
            echo -e "  $((i+1)). ${items[${i}]}"
        done

        print_separator
        echo -e "  ${C_BOLD}n${C_RESET}=next  ${C_BOLD}p${C_RESET}=prev  ${C_BOLD}q${C_RESET}=quit"
        echo -ne "${C_INPUT}Action: ${C_RESET}"
        local action
        read -r action

        case "${action,,}" in
            n|next)
                [[ ${page} -lt ${pages} ]] && (( page++ ))
                ;;
            p|prev)
                [[ ${page} -gt 1 ]] && (( page-- ))
                ;;
            q|quit|"")
                break
                ;;
        esac
    done
}

# =============================================================================
# LOCK FILE MANAGEMENT
# =============================================================================

# Acquire a lock file
acquire_lock() {
    local lock_file="${1:-/tmp/sshvpnpanel.lock}"
    local timeout="${2:-30}"

    local count=0
    while [[ -f "${lock_file}" ]]; do
        local pid
        pid="$(cat "${lock_file}" 2>/dev/null)"
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            rm -f "${lock_file}"
            break
        fi
        (( count++ ))
        if [[ ${count} -ge ${timeout} ]]; then
            print_error "Could not acquire lock after ${timeout} seconds"
            return 1
        fi
        sleep 1
    done

    echo $$ > "${lock_file}"
    return 0
}

# Release a lock file
release_lock() {
    local lock_file="${1:-/tmp/sshvpnpanel.lock}"
    local pid
    pid="$(cat "${lock_file}" 2>/dev/null)"
    [[ "${pid}" == "$$" ]] && rm -f "${lock_file}"
}

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

# Check and report required dependencies
check_dependencies() {
    local required=("$@")
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command_exists "${cmd}"; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_warning "Missing dependencies: ${missing[*]}"
        return 1
    fi
    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize logging directories
init_logging() {
    local log_dir="${LOG_DIR:-/var/log/sshvpnpanel}"
    mkdir -p "${log_dir}" 2>/dev/null
    touch "${MAIN_LOG:-${log_dir}/sshvpnpanel.log}" 2>/dev/null
    touch "${ERROR_LOG:-${log_dir}/error.log}" 2>/dev/null
    touch "${AUDIT_LOG:-${log_dir}/audit.log}" 2>/dev/null
}

# Initialize temporary directory
init_tmp() {
    local tmp_dir="${TMP_DIR:-/tmp/sshvpnpanel}"
    mkdir -p "${tmp_dir}" 2>/dev/null
    chmod 700 "${tmp_dir}" 2>/dev/null
}

# Initialize all utility subsystems
init_utilities() {
    init_logging
    init_tmp
}
