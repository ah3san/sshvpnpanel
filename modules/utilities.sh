#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - Utilities Module
# Provides helper functions used across all modules
################################################################################

# Guard against multiple sourcing
[[ -n "${_UTILITIES_LOADED:-}" ]] && return 0
_UTILITIES_LOADED=1

# ---------------------------------------------------------------------------
# Color and formatting constants
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Default paths (can be overridden by sourcing sshvpnpanel.conf)
# ---------------------------------------------------------------------------
PANEL_LOG_DIR="${PANEL_LOG_DIR:-/var/log/sshvpnpanel}"
PANEL_DATA_DIR="${PANEL_DATA_DIR:-/var/lib/sshvpnpanel}"
PANEL_CONFIG_DIR="${PANEL_CONFIG_DIR:-/etc/sshvpnpanel}"
PANEL_BACKUP_DIR="${PANEL_BACKUP_DIR:-/var/backups/sshvpnpanel}"
LOG_AUDIT_FILE="${LOG_AUDIT_FILE:-${PANEL_LOG_DIR}/audit.log}"
LOG_ERROR_FILE="${LOG_ERROR_FILE:-${PANEL_LOG_DIR}/error.log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------

# Write a formatted log entry
# Usage: _log_write LEVEL "message"
_log_write() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local caller="${FUNCNAME[2]:-unknown}:${BASH_LINENO[1]:-0}"
    printf '[%s] [%-5s] [%s] %s\n' "$timestamp" "$level" "$caller" "$message"
}

log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] || return 0
    _log_write "DEBUG" "$*" | tee -a "${LOG_AUDIT_FILE}" >/dev/null 2>&1 || true
}

log_info() {
    _log_write "INFO" "$*" | tee -a "${LOG_AUDIT_FILE}" >/dev/null 2>&1 || true
    echo -e "${GREEN}[INFO]${RESET} $*"
}

log_warn() {
    _log_write "WARN" "$*" | tee -a "${LOG_AUDIT_FILE}" >/dev/null 2>&1 || true
    echo -e "${YELLOW}[WARN]${RESET} $*" >&2
}

log_error() {
    _log_write "ERROR" "$*" | tee -a "${LOG_AUDIT_FILE}" "${LOG_ERROR_FILE}" >/dev/null 2>&1 || true
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

# Audit log - always written regardless of log level
log_audit() {
    local action="$1"
    local user="${2:-SYSTEM}"
    local detail="${3:-}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local operator="${SUDO_USER:-${USER:-root}}"
    local entry="[${timestamp}] AUDIT | action=${action} | user=${user} | operator=${operator} | ${detail}"
    echo "$entry" >> "${LOG_AUDIT_FILE}" 2>/dev/null || true
    log_info "AUDIT: ${action} | user=${user} | ${detail}"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

print_header() {
    local title="$1"
    local width=70
    local line
    line="$(printf '%*s' "$width" '' | tr ' ' '=')"
    echo -e "\n${CYAN}${line}${RESET}"
    printf "${CYAN}  %-*s${RESET}\n" $((width - 2)) "$title"
    echo -e "${CYAN}${line}${RESET}\n"
}

print_section() {
    local title="$1"
    echo -e "\n${BOLD}${BLUE}--- ${title} ---${RESET}"
}

print_success() {
    echo -e "${GREEN}✓ $*${RESET}"
}

print_error() {
    echo -e "${RED}✗ $*${RESET}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠ $*${RESET}"
}

print_info() {
    echo -e "${CYAN}ℹ $*${RESET}"
}

print_step() {
    local step="$1"
    local desc="$2"
    echo -e "  ${DIM}[${step}]${RESET} ${desc}"
}

print_table_row() {
    printf "  %-25s : %s\n" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Input / prompt helpers
# ---------------------------------------------------------------------------

# Prompt for input with optional default value
# Usage: prompt_input VAR_NAME "Prompt text" [default_value]
prompt_input() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local input

    if [[ -n "$default" ]]; then
        read -r -p "$(echo -e "${CYAN}${prompt_text} [${default}]: ${RESET}")" input
        input="${input:-$default}"
    else
        read -r -p "$(echo -e "${CYAN}${prompt_text}: ${RESET}")" input
    fi
    printf -v "$var_name" '%s' "$input"
}

# Prompt for a password (hidden input)
prompt_password() {
    local var_name="$1"
    local prompt_text="${2:-Password}"
    local pass1 pass2

    while true; do
        read -r -s -p "$(echo -e "${CYAN}${prompt_text}: ${RESET}")" pass1
        echo
        read -r -s -p "$(echo -e "${CYAN}Confirm ${prompt_text}: ${RESET}")" pass2
        echo
        if [[ "$pass1" == "$pass2" ]]; then
            printf -v "$var_name" '%s' "$pass1"
            return 0
        fi
        print_warning "Passwords do not match. Please try again."
    done
}

# Prompt yes/no question, returns 0 for yes, 1 for no
prompt_confirm() {
    local message="$1"
    local default="${2:-n}"
    local prompt choice

    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    read -r -p "$(echo -e "${YELLOW}${message} ${prompt}: ${RESET}")" choice
    choice="${choice:-$default}"
    case "${choice,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

validate_username() {
    local username="$1"
    # Must start with letter, 3-32 chars, only alphanumeric and underscore/hyphen
    if [[ ! "$username" =~ ^[a-z][a-z0-9_-]{2,31}$ ]]; then
        log_error "Invalid username '${username}'. Must be 3-32 chars, start with a letter, and contain only [a-z0-9_-]."
        return 1
    fi
    return 0
}

validate_password() {
    local password="$1"
    if [[ ${#password} -lt 8 ]]; then
        log_error "Password must be at least 8 characters long."
        return 1
    fi
    return 0
}

validate_integer() {
    local value="$1"
    local name="${2:-value}"
    local min="${3:-}"
    local max="${4:-}"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "${name} must be a positive integer."
        return 1
    fi
    if [[ -n "$min" && "$value" -lt "$min" ]]; then
        log_error "${name} must be >= ${min}."
        return 1
    fi
    if [[ -n "$max" && "$value" -gt "$max" ]]; then
        log_error "${name} must be <= ${max}."
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    validate_integer "$port" "Port" 1 65535
}

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        log_error "Invalid domain name: ${domain}"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -r -a octets <<< "$ip"
    if [[ ${#octets[@]} -ne 4 ]]; then
        log_error "Invalid IP address: ${ip}"
        return 1
    fi
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^[0-9]+$ ]] || [[ "$octet" -gt 255 ]]; then
            log_error "Invalid IP address: ${ip}"
            return 1
        fi
    done
    return 0
}

validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email address: ${email}"
        return 1
    fi
    return 0
}

validate_date() {
    local date_str="$1"
    if ! date -d "$date_str" >/dev/null 2>&1; then
        log_error "Invalid date format: ${date_str}. Use YYYY-MM-DD."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# System helpers
# ---------------------------------------------------------------------------

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "This operation requires root privileges. Run with sudo."
        return 1
    fi
    return 0
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: ${cmd}"
        return 1
    fi
    return 0
}

check_commands() {
    local all_ok=0
    for cmd in "$@"; do
        check_command "$cmd" || all_ok=1
    done
    return "$all_ok"
}

# Ensure a directory exists and set permissions
ensure_dir() {
    local dir="$1"
    local perms="${2:-750}"
    local owner="${3:-root}"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { log_error "Failed to create directory: ${dir}"; return 1; }
    fi
    chmod "$perms" "$dir" 2>/dev/null || true
    chown "$owner" "$dir" 2>/dev/null || true
}

# Check if a user exists on the system
user_exists() {
    local username="$1"
    id "$username" >/dev/null 2>&1
}

# Check if a group exists on the system
group_exists() {
    local group="$1"
    getent group "$group" >/dev/null 2>&1
}

# Get OS/distro info
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "${ID:-unknown} ${VERSION_ID:-}"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# Get a free port in a range
get_free_port() {
    local start="${1:-10000}"
    local end="${2:-20000}"
    local port
    for port in $(seq "$start" "$end"); do
        if ! ss -ltn 2>/dev/null | grep -q ":${port} " && \
           ! grep -qr "accept.*= .*:${port}" /etc/stunnel/ 2>/dev/null; then
            echo "$port"
            return 0
        fi
    done
    log_error "No free port found in range ${start}-${end}"
    return 1
}

# Generate a random password
generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c "$length"
    echo
}

# Generate a random alphanumeric token
generate_token() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    echo
}

# Calculate expiry date from days
calc_expiry_date() {
    local days="${1:-30}"
    date -d "+${days} days" '+%Y-%m-%d'
}

# Convert bytes to human-readable format
human_bytes() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc 2>/dev/null || echo "$((bytes / 1073741824))")"
    elif [[ "$bytes" -ge 1048576 ]]; then
        printf "%.2f MB" "$(echo "scale=2; $bytes/1048576" | bc 2>/dev/null || echo "$((bytes / 1048576))")"
    elif [[ "$bytes" -ge 1024 ]]; then
        printf "%.2f KB" "$(echo "scale=2; $bytes/1024" | bc 2>/dev/null || echo "$((bytes / 1024))")"
    else
        printf "%d B" "$bytes"
    fi
}

# Send notification email (if configured)
send_email() {
    local to="$1"
    local subject="$2"
    local body="$3"

    if [[ "${EMAIL_ENABLED:-false}" != "true" ]]; then
        log_debug "Email disabled; skipping notification to ${to}"
        return 0
    fi

    if ! check_command "mail" && ! check_command "sendmail"; then
        log_warn "No mail client found; cannot send email to ${to}"
        return 1
    fi

    echo "$body" | mail -s "$subject" \
        -a "From: ${EMAIL_FROM:-noreply@example.com}" \
        "$to" 2>/dev/null || {
        log_warn "Failed to send email to ${to}"
        return 1
    }
    log_info "Email notification sent to ${to}: ${subject}"
    return 0
}

# Backup a file before modifying it
backup_file() {
    local file="$1"
    local backup_dir="${2:-${PANEL_BACKUP_DIR}/configs}"
    if [[ -f "$file" ]]; then
        ensure_dir "$backup_dir"
        local backup_name
        backup_name="${backup_dir}/$(basename "${file}").$(date '+%Y%m%d_%H%M%S').bak"
        cp -p "$file" "$backup_name" && log_debug "Backed up ${file} to ${backup_name}"
    fi
}

# Sanitize a string for safe use in filenames / log entries
sanitize_string() {
    local str="$1"
    echo "${str//[^a-zA-Z0-9._-]/}"
}

# Load the main panel configuration file
load_config() {
    local config_file="${1:-${PANEL_CONFIG_DIR}/sshvpnpanel.conf}"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        log_debug "Loaded configuration from ${config_file}"
    else
        log_warn "Configuration file not found: ${config_file}; using defaults."
    fi
}
