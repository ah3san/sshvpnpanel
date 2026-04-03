#!/usr/bin/env bash
################################################################################
# SSH VPN Panel - Monitoring Module
# System monitoring, bandwidth tracking, connection stats
################################################################################

[[ -n "${_MONITORING_LOADED:-}" ]] && return 0
_MONITORING_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=modules/utilities.sh
source "${SCRIPT_DIR}/utilities.sh"

BANDWIDTH_REPORT_DIR="${BANDWIDTH_REPORT_DIR:-/var/lib/sshvpnpanel/bandwidth}"
LOG_ACCESS_FILE="${LOG_ACCESS_FILE:-/var/log/sshvpnpanel/access.log}"

# ---------------------------------------------------------------------------
# System status
# ---------------------------------------------------------------------------

monitoring_system_status() {
    print_header "System Status"

    # Uptime
    local uptime_str
    uptime_str="$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//')"
    print_table_row "Uptime" "$uptime_str"

    # Load average
    local load
    load="$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')"
    print_table_row "Load Average" "$load"

    # CPU usage
    local cpu_idle cpu_usage
    cpu_idle="$(top -bn1 2>/dev/null | grep '%Cpu' | awk '{print $8}' | cut -d. -f1)"
    cpu_usage="$((100 - ${cpu_idle:-100}))%"
    print_table_row "CPU Usage" "$cpu_usage"

    # Memory
    local mem_total mem_used mem_free
    mem_total="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
    mem_used="$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')"
    mem_free="$(free -m 2>/dev/null | awk '/^Mem:/{print $4}')"
    print_table_row "Memory" "Total: ${mem_total:-?}MB | Used: ${mem_used:-?}MB | Free: ${mem_free:-?}MB"

    # Disk
    local disk_info
    disk_info="$(df -h / 2>/dev/null | tail -1 | awk '{print "Total: "$2" | Used: "$3" | Free: "$4" ("$5" used)"}')"
    print_table_row "Disk (/)" "$disk_info"

    # SSH connections
    local ssh_conn
    ssh_conn="$(ss -nt 2>/dev/null | grep -c ":${SSH_PORT:-22} " || echo 0)"
    print_table_row "SSH Connections" "$ssh_conn"

    # Active users
    local active_users
    active_users="$(who 2>/dev/null | wc -l)"
    print_table_row "Active Sessions" "$active_users"
}

# ---------------------------------------------------------------------------
# Service status
# ---------------------------------------------------------------------------

monitoring_service_status() {
    print_section "Service Status"
    printf "  %-25s %-15s\n" "SERVICE" "STATUS"
    printf "  %-25s %-15s\n" "-------" "------"

    local services=("ssh" "sshd" "stunnel4" "stunnel" "fail2ban" "ufw" "iptables")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  %-25s ${GREEN}%-15s${RESET}\n" "$svc" "RUNNING"
        elif systemctl list-units --type=service 2>/dev/null | grep -q "^  ${svc}.service"; then
            printf "  %-25s ${RED}%-15s${RESET}\n" "$svc" "STOPPED"
        fi
    done
}

# ---------------------------------------------------------------------------
# Per-user monitoring setup/teardown
# ---------------------------------------------------------------------------

# Set up monitoring for a new user
# Creates log entries and bandwidth tracking stubs
monitoring_add_user() {
    local username="$1"
    ensure_dir "$BANDWIDTH_REPORT_DIR" 750 root
    local bw_file="${BANDWIDTH_REPORT_DIR}/${username}.log"

    if [[ ! -f "$bw_file" ]]; then
        {
            echo "# Bandwidth log for user: ${username}"
            echo "# Created: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# Format: TIMESTAMP,EVENT,BYTES_IN,BYTES_OUT"
        } > "$bw_file"
        chmod 640 "$bw_file"
    fi

    # Set up rsyslog filter for user if available
    local rsyslog_conf="/etc/rsyslog.d/sshvpnpanel-${username}.conf"
    if command -v rsyslogd >/dev/null 2>&1 && [[ ! -f "$rsyslog_conf" ]]; then
        cat > "$rsyslog_conf" << EOF
# SSH VPN Panel - User monitoring: ${username}
:msg, contains, "user ${username}" /var/log/sshvpnpanel/${username}.log
EOF
        systemctl reload rsyslog 2>/dev/null || true
    fi

    log_audit "MONITORING_USER_ADDED" "$username"
    print_success "Monitoring configured for user '${username}'."
    return 0
}

# Remove monitoring for a user
monitoring_remove_user() {
    local username="$1"
    local bw_file="${BANDWIDTH_REPORT_DIR}/${username}.log"
    local rsyslog_conf="/etc/rsyslog.d/sshvpnpanel-${username}.conf"

    # Archive bandwidth log before removing
    if [[ -f "$bw_file" ]]; then
        local archive_dir="${ARCHIVE_DIR:-/var/backups/sshvpnpanel/archived_users}/${username}"
        ensure_dir "$archive_dir" 700 root
        cp "$bw_file" "${archive_dir}/bandwidth_$(date '+%Y%m%d_%H%M%S').log"
        rm -f "$bw_file"
    fi

    if [[ -f "$rsyslog_conf" ]]; then
        rm -f "$rsyslog_conf"
        systemctl reload rsyslog 2>/dev/null || true
    fi

    # Remove per-user log
    rm -f "/var/log/sshvpnpanel/${username}.log" 2>/dev/null || true

    log_audit "MONITORING_USER_REMOVED" "$username"
    print_success "Monitoring removed for user '${username}'."
    return 0
}

# Record a bandwidth event for a user
monitoring_record_bandwidth() {
    local username="$1"
    local event="${2:-CONNECTION}"
    local bytes_in="${3:-0}"
    local bytes_out="${4:-0}"
    local bw_file="${BANDWIDTH_REPORT_DIR}/${username}.log"

    if [[ -f "$bw_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'),${event},${bytes_in},${bytes_out}" >> "$bw_file"
    fi
}

# ---------------------------------------------------------------------------
# Bandwidth report for a user
# ---------------------------------------------------------------------------

monitoring_user_bandwidth() {
    local username="$1"
    local bw_file="${BANDWIDTH_REPORT_DIR}/${username}.log"

    print_section "Bandwidth Report: ${username}"

    if [[ ! -f "$bw_file" ]]; then
        print_warning "No bandwidth data for user '${username}'."
        return 0
    fi

    local total_in=0 total_out=0 total_events=0
    while IFS=',' read -r ts event bytes_in bytes_out; do
        [[ "$ts" == \#* || -z "$ts" ]] && continue
        total_in=$((total_in + ${bytes_in:-0}))
        total_out=$((total_out + ${bytes_out:-0}))
        ((total_events++))
    done < "$bw_file"

    print_table_row "Total Events" "$total_events"
    print_table_row "Total Inbound" "$(human_bytes "$total_in")"
    print_table_row "Total Outbound" "$(human_bytes "$total_out")"
    print_table_row "Total Transfer" "$(human_bytes "$((total_in + total_out))")"

    # Show last 5 events
    echo ""
    print_info "Last 5 events:"
    grep -v '^#' "$bw_file" | tail -5 | while IFS=',' read -r ts event bytes_in bytes_out; do
        [[ -z "$ts" ]] && continue
        printf "    %s | %-15s | in=%-12s | out=%s\n" \
            "$ts" "$event" "$(human_bytes "${bytes_in:-0}")" "$(human_bytes "${bytes_out:-0}")"
    done
}

# Connection history for a user
monitoring_connection_history() {
    local username="$1"
    local lines="${2:-20}"

    print_section "Connection History: ${username}"

    # Pull from auth.log or secure log
    local auth_log="/var/log/auth.log"
    [[ ! -f "$auth_log" ]] && auth_log="/var/log/secure"

    if [[ -f "$auth_log" ]]; then
        grep "sshd.*${username}" "$auth_log" 2>/dev/null | tail "$lines" | while IFS= read -r line; do
            echo "  $line"
        done
    else
        print_warning "Auth log not accessible."
    fi

    # Panel-specific access log
    if [[ -f "$LOG_ACCESS_FILE" ]]; then
        grep "$username" "$LOG_ACCESS_FILE" 2>/dev/null | tail "$lines"
    fi
}

# ---------------------------------------------------------------------------
# Dashboard overview
# ---------------------------------------------------------------------------

monitoring_dashboard() {
    print_header "SSH VPN Panel Dashboard"
    monitoring_system_status
    echo ""
    monitoring_service_status

    print_section "Active SSH Sessions"
    if command -v who >/dev/null 2>&1; then
        who 2>/dev/null | head -10
    fi

    print_section "Recent Audit Events"
    if [[ -f "${LOG_AUDIT_FILE}" ]]; then
        tail -5 "${LOG_AUDIT_FILE}" 2>/dev/null | while IFS= read -r line; do
            echo "  $line"
        done
    else
        print_info "No audit log found."
    fi
}
