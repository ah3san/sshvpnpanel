#!/usr/bin/env bash
# =============================================================================
# SSH VPN Panel - System Monitoring Module
# =============================================================================
# Real-time server status, CPU/memory/disk monitoring, active connections,
# bandwidth stats, per-protocol breakdown, and alerts.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "This module should be sourced, not executed directly."
    exit 1
}

# =============================================================================
# SYSTEM INFORMATION
# =============================================================================

# Get CPU usage percentage
get_cpu_usage() {
    local cpu_idle
    # Try /proc/stat first (Linux)
    if [[ -f /proc/stat ]]; then
        cpu_idle="$(awk '/^cpu / {idle=$5; total=$2+$3+$4+$5+$6+$7+$8; print int((total-idle)*100/total)}' \
            /proc/stat 2>/dev/null)"
        echo "${cpu_idle:-0}"
        return
    fi
    # Fallback using top
    local usage
    usage="$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)"
    echo "${usage:-0}"
}

# Get memory usage
get_memory_info() {
    if [[ -f /proc/meminfo ]]; then
        local total
        total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
        local available
        available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
        local free
        free="$(awk '/^MemFree:/ {print $2}' /proc/meminfo)"
        local cached
        cached="$(awk '/^Cached:/ {print $2}' /proc/meminfo)"
        local used=$(( total - available ))
        local pct=$(( used * 100 / total ))

        echo "total=$((total/1024)) used=$((used/1024)) free=$((free/1024)) pct=${pct}"
    fi
}

# Get disk usage for a path
get_disk_usage() {
    local path="${1:-/}"
    local info
    info="$(df -h "${path}" 2>/dev/null | tail -1)"
    if [[ -n "${info}" ]]; then
        local total used avail pct
        total="$(echo "${info}" | awk '{print $2}')"
        used="$(echo "${info}" | awk '{print $3}')"
        avail="$(echo "${info}" | awk '{print $4}')"
        pct="$(echo "${info}" | awk '{print $5}' | tr -d '%')"
        echo "total=${total} used=${used} avail=${avail} pct=${pct}"
    fi
}

# Get system load averages
get_load_average() {
    if [[ -f /proc/loadavg ]]; then
        awk '{print $1, $2, $3}' /proc/loadavg
    else
        uptime | awk -F'load average:' '{print $2}' | tr -d ' '
    fi
}

# Get uptime
get_system_uptime() {
    if [[ -f /proc/uptime ]]; then
        local uptime_seconds
        uptime_seconds="$(awk '{print int($1)}' /proc/uptime)"
        seconds_to_human "${uptime_seconds}"
    else
        uptime -p 2>/dev/null || uptime 2>/dev/null | awk '{print $3,$4,$5}'
    fi
}

# Get network traffic statistics
get_network_stats() {
    local iface="${1:-$(get_default_interface)}"

    if [[ -f "/sys/class/net/${iface}/statistics/rx_bytes" ]]; then
        local rx_bytes
        rx_bytes="$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)"
        local tx_bytes
        tx_bytes="$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)"
        local rx_packets
        rx_packets="$(cat "/sys/class/net/${iface}/statistics/rx_packets" 2>/dev/null || echo 0)"
        local tx_packets
        tx_packets="$(cat "/sys/class/net/${iface}/statistics/tx_packets" 2>/dev/null || echo 0)"
        echo "rx_bytes=${rx_bytes} tx_bytes=${tx_bytes} rx_packets=${rx_packets} tx_packets=${tx_packets}"
    fi
}

# Calculate current bandwidth speed (bytes/sec)
get_bandwidth_speed() {
    local iface="${1:-$(get_default_interface)}"
    local interval="${2:-1}"

    local rx1 tx1 rx2 tx2

    if [[ -f "/sys/class/net/${iface}/statistics/rx_bytes" ]]; then
        rx1="$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)"
        tx1="$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)"
        sleep "${interval}"
        rx2="$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)"
        tx2="$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)"

        local rx_speed=$(( (rx2 - rx1) / interval ))
        local tx_speed=$(( (tx2 - tx1) / interval ))
        echo "rx=${rx_speed} tx=${tx_speed}"
    fi
}

# Get number of active connections
get_connection_count() {
    local count=0
    if command_exists ss; then
        count="$(ss -tn state established 2>/dev/null | grep -c "." || echo "0")"
    elif command_exists netstat; then
        count="$(netstat -tn 2>/dev/null | grep -c "ESTABLISHED" || echo "0")"
    fi
    echo "${count}"
}

# Get process count
get_process_count() {
    local total
    total="$(ps aux 2>/dev/null | wc -l)"
    echo "$((total - 1))"
}

# Get number of logged-in users
get_logged_in_users() {
    who 2>/dev/null | wc -l
}

# =============================================================================
# DASHBOARD
# =============================================================================

show_dashboard() {
    clear_screen
    local iface
    iface="$(get_default_interface)"
    local public_ip
    public_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"

    echo -e "${C_BOLD}  System: $(hostname) | IP: ${public_ip} | Interface: ${iface}${C_RESET}"
    echo -e "  Uptime: $(get_system_uptime) | $(date '+%Y-%m-%d %H:%M:%S')"
    echo

    # CPU Section
    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    echo -ne "  ${C_BOLD}CPU:${C_RESET}    "
    print_progress "${cpu_usage}" 100 30
    local load_avg
    load_avg="$(get_load_average)"
    echo -e "  ${C_DIM}Load: ${load_avg}${C_RESET}"

    # Memory Section
    local mem_info
    mem_info="$(get_memory_info)"
    if [[ -n "${mem_info}" ]]; then
        eval "${mem_info}"
        local mem_label
        mem_label="${used}MB / ${total}MB"
        echo -ne "  ${C_BOLD}Memory:${C_RESET} "
        print_progress "${pct}" 100 30
        echo -e "  ${C_DIM}${mem_label}${C_RESET}"
    fi

    # Disk Section
    local disk_info
    disk_info="$(get_disk_usage /)"
    if [[ -n "${disk_info}" ]]; then
        eval "${disk_info}"
        echo -ne "  ${C_BOLD}Disk:${C_RESET}   "
        print_progress "${pct}" 100 30
        echo -e "  ${C_DIM}Used: ${used} / ${total} (Avail: ${avail})${C_RESET}"
    fi

    echo
    print_separator 70

    # Network Section
    local net_stats
    net_stats="$(get_network_stats "${iface}")"
    if [[ -n "${net_stats}" ]]; then
        eval "${net_stats}"
        echo -e "  ${C_BOLD}Network [${iface}]:${C_RESET}"
        printf "  %-20s %s\n" "RX Total:" "$(bytes_to_human "${rx_bytes}")"
        printf "  %-20s %s\n" "TX Total:" "$(bytes_to_human "${tx_bytes}")"
    fi

    echo
    print_separator 70

    # Services Section
    echo -e "  ${C_BOLD}Services:${C_RESET}"
    local services=(
        "${SSH_SERVICE:-sshd}:SSH"
        "${STUNNEL_SERVICE:-stunnel4}:Stunnel"
    )

    for svc_entry in "${services[@]}"; do
        local svc_name="${svc_entry%%:*}"
        local svc_label="${svc_entry#*:}"
        local status
        status="$(service_status "${svc_name}" 2>/dev/null || echo "unknown")"
        local status_str
        if [[ "${status}" == "running" ]]; then
            status_str="${C_SUCCESS}● Running${C_RESET}"
        else
            status_str="${C_ERROR}● Stopped${C_RESET}"
        fi
        printf "  %-14s %b\n" "${svc_label}:" "${status_str}"
    done

    echo
    print_separator 70

    # User Section
    local ssh_sessions
    ssh_sessions="$(get_logged_in_users)"
    local total_connections
    total_connections="$(get_connection_count)"
    local processes
    processes="$(get_process_count)"

    echo -e "  ${C_BOLD}Activity:${C_RESET}"
    printf "  %-20s %s\n" "SSH Sessions:" "${ssh_sessions}"
    printf "  %-20s %s\n" "Total Connections:" "${total_connections}"
    printf "  %-20s %s\n" "Running Processes:" "${processes}"
}

# =============================================================================
# REAL-TIME MONITORING
# =============================================================================

realtime_monitor() {
    local refresh="${MONITOR_REFRESH:-5}"
    print_info "Starting real-time monitor (refresh: ${refresh}s). Press Ctrl+C to stop."
    sleep 1

    while true; do
        show_dashboard
        echo
        echo -e "  ${C_DIM}Auto-refresh every ${refresh}s | Press Ctrl+C to stop${C_RESET}"
        sleep "${refresh}"
    done
}

# =============================================================================
# BANDWIDTH MONITORING
# =============================================================================

show_bandwidth_stats() {
    clear_screen
    print_header "Bandwidth Statistics"

    local iface
    iface="$(get_default_interface)"

    echo -e "\n${C_BOLD}Measuring current bandwidth (1 second sample)...${C_RESET}"

    local speed_info
    speed_info="$(get_bandwidth_speed "${iface}" 1)"

    if [[ -n "${speed_info}" ]]; then
        eval "${speed_info}"
        echo -e "\n${C_BOLD}Current Speed [${iface}]:${C_RESET}"
        printf "  %-20s %s/s\n" "Download (RX):" "$(bytes_to_human "${rx}")"
        printf "  %-20s %s/s\n" "Upload (TX):" "$(bytes_to_human "${tx}")"
    fi

    echo -e "\n${C_BOLD}Total Interface Statistics:${C_RESET}"
    local net_stats
    net_stats="$(get_network_stats "${iface}")"
    if [[ -n "${net_stats}" ]]; then
        eval "${net_stats}"
        printf "  %-20s %s (%s packets)\n" "Total RX:" "$(bytes_to_human "${rx_bytes}")" "${rx_packets}"
        printf "  %-20s %s (%s packets)\n" "Total TX:" "$(bytes_to_human "${tx_bytes}")" "${tx_packets}"
    fi

    # Per-user breakdown if monitoring enabled
    if [[ "${ENABLE_TRAFFIC_MONITORING:-yes}" == "yes" ]] && \
       [[ -d "${USER_DATA_DIR:-/etc/sshvpnpanel/users}" ]]; then
        echo -e "\n${C_BOLD}Per-User Traffic:${C_RESET}"
        print_table_header "Username" "Data In" "Data Out" "Total"

        while IFS= read -r -d '' user_dir; do
            local username
            username="$(basename "${user_dir}")"
            local vpn_file="${user_dir}/vpn.conf"
            [[ -f "${vpn_file}" ]] || continue

            local bytes_in
            bytes_in="$(config_get "${vpn_file}" "TOTAL_BYTES_IN" "0")"
            local bytes_out
            bytes_out="$(config_get "${vpn_file}" "TOTAL_BYTES_OUT" "0")"
            local total=$(( bytes_in + bytes_out ))

            if [[ "${total}" -gt 0 ]]; then
                printf "  %-20s %-12s %-12s %s\n" \
                    "${username}" \
                    "$(bytes_to_human "${bytes_in}")" \
                    "$(bytes_to_human "${bytes_out}")" \
                    "$(bytes_to_human "${total}")"
            fi
        done < <(find "${USER_DATA_DIR:-/etc/sshvpnpanel/users}" \
            -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
}

# =============================================================================
# CONNECTION STATISTICS
# =============================================================================

show_connection_stats() {
    clear_screen
    print_header "Connection Statistics"

    echo -e "\n${C_BOLD}Active Connections by Protocol:${C_RESET}"
    print_separator 40

    # SSH connections
    local ssh_count
    ssh_count="$(who 2>/dev/null | wc -l)"
    printf "  %-20s %s\n" "SSH:" "${ssh_count}"

    # All TCP connections
    local tcp_established
    tcp_established="$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l || echo "0")"
    printf "  %-20s %s\n" "TCP Established:" "${tcp_established}"

    # Connections by port
    echo -e "\n${C_BOLD}Connections by Port:${C_RESET}"
    print_separator 40
    if command_exists ss; then
        ss -tn state established 2>/dev/null | tail -n +2 | \
        awk '{print $4}' | grep -oE ':[0-9]+$' | tr -d ':' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r count port; do
            printf "  %-20s %s connections\n" "Port ${port}:" "${count}"
        done
    fi

    # Top source IPs
    echo -e "\n${C_BOLD}Top Source IPs:${C_RESET}"
    print_separator 40
    if command_exists ss; then
        ss -tn state established 2>/dev/null | tail -n +2 | \
        awk '{print $5}' | grep -oE '^[0-9.]+' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r count ip; do
            printf "  %-22s %s connections\n" "${ip}:" "${count}"
        done
    fi
}

# =============================================================================
# ALERTS
# =============================================================================

check_system_alerts() {
    local alerts=()

    # CPU alert
    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    if [[ "${cpu_usage}" -gt "${CPU_ALERT_THRESHOLD:-90}" ]]; then
        alerts+=("HIGH CPU: ${cpu_usage}% (threshold: ${CPU_ALERT_THRESHOLD:-90}%)")
    fi

    # Memory alert
    local mem_info
    mem_info="$(get_memory_info)"
    if [[ -n "${mem_info}" ]]; then
        eval "${mem_info}"
        if [[ "${pct}" -gt "${MEMORY_ALERT_THRESHOLD:-90}" ]]; then
            alerts+=("HIGH MEMORY: ${pct}% (threshold: ${MEMORY_ALERT_THRESHOLD:-90}%)")
        fi
    fi

    # Disk alert
    local disk_info
    disk_info="$(get_disk_usage /)"
    if [[ -n "${disk_info}" ]]; then
        eval "${disk_info}"
        if [[ "${pct}" -gt "${DISK_ALERT_THRESHOLD:-85}" ]]; then
            alerts+=("HIGH DISK: ${pct}% on / (threshold: ${DISK_ALERT_THRESHOLD:-85}%)")
        fi
    fi

    # Service alerts
    local ssh_status
    ssh_status="$(service_status "${SSH_SERVICE:-sshd}" 2>/dev/null || echo "unknown")"
    if [[ "${ssh_status}" != "running" ]]; then
        alerts+=("SSH SERVICE NOT RUNNING: ${ssh_status}")
    fi

    local stunnel_status
    stunnel_status="$(service_status "${STUNNEL_SERVICE:-stunnel4}" 2>/dev/null || echo "unknown")"
    if [[ "${stunnel_status}" != "running" ]]; then
        alerts+=("STUNNEL SERVICE NOT RUNNING: ${stunnel_status}")
    fi

    # Certificate expiry alerts
    if command_exists openssl && [[ -d "${CERT_DIR:-/etc/sshvpnpanel/certs}" ]]; then
        while IFS= read -r -d '' cert_file; do
            local expiry_str
            expiry_str="$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)"
            local expiry_date
            expiry_date="$(date -d "${expiry_str}" '+%Y-%m-%d' 2>/dev/null || echo "")"
            if [[ -n "${expiry_date}" ]]; then
                local days_left
                days_left="$(days_until_expiry "${expiry_date}")"
                if [[ "${days_left}" =~ ^-?[0-9]+$ ]] && [[ "${days_left}" -lt 7 ]]; then
                    local cert_name
                    cert_name="$(basename "${cert_file}")"
                    alerts+=("CERT EXPIRING: ${cert_name} in ${days_left} days")
                fi
            fi
        done < <(find "${CERT_DIR:-/etc/sshvpnpanel/certs}" -name "*.crt" -print0 2>/dev/null)
    fi

    # Display alerts
    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo -e "\n${BG_RED}${COLOR_WHITE}  ⚠  SYSTEM ALERTS (${#alerts[@]})  ${C_RESET}"
        for alert in "${alerts[@]}"; do
            echo -e "  ${C_ERROR}▶ ${alert}${C_RESET}"
        done
        echo

        # Send email if configured
        if [[ "${ENABLE_EMAIL_ALERTS:-no}" == "yes" ]] && \
           [[ -n "${ALERT_EMAIL:-}" ]] && command_exists mail; then
            local alert_text
            printf -v alert_text '%s\n' "${alerts[@]}"
            echo "${alert_text}" | mail -s "SSH VPN Panel Alert: $(hostname)" \
                "${ALERT_EMAIL}" 2>/dev/null || true
        fi
    else
        print_success "No active alerts"
    fi

    return ${#alerts[@]}
}

# =============================================================================
# HISTORICAL DATA
# =============================================================================

show_historical_stats() {
    clear_screen
    print_header "Historical Statistics"

    local log_file="${MAIN_LOG:-/var/log/sshvpnpanel/sshvpnpanel.log}"

    if [[ ! -f "${log_file}" ]]; then
        print_info "No log data available"
        return
    fi

    echo -e "\n${C_BOLD}Log Summary (${log_file}):${C_RESET}"
    print_separator 40

    local total_lines
    total_lines="$(wc -l < "${log_file}" 2>/dev/null || echo "0")"
    local error_count
    error_count="$(grep -c '\[ERROR\]' "${log_file}" 2>/dev/null || echo "0")"
    local warn_count
    warn_count="$(grep -c '\[WARN\]' "${log_file}" 2>/dev/null || echo "0")"
    local info_count
    info_count="$(grep -c '\[INFO\]' "${log_file}" 2>/dev/null || echo "0")"

    printf "  %-20s %s\n" "Total Log Lines:" "${total_lines}"
    printf "  %-20s ${C_ERROR}%s${C_RESET}\n" "Errors:" "${error_count}"
    printf "  %-20s ${C_WARNING}%s${C_RESET}\n" "Warnings:" "${warn_count}"
    printf "  %-20s %s\n" "Info Messages:" "${info_count}"

    echo -e "\n${C_BOLD}Recent Log Entries:${C_RESET}"
    print_separator 40
    tail -20 "${log_file}" | while IFS= read -r line; do
        local color="${C_DIM}"
        [[ "${line}" =~ \[WARN\] ]] && color="${C_WARNING}"
        [[ "${line}" =~ \[ERROR\] ]] && color="${C_ERROR}"
        echo -e "  ${color}${line}${C_RESET}"
    done

    echo -e "\n${C_BOLD}Audit Log Summary:${C_RESET}"
    print_separator 40
    local audit_log="${AUDIT_LOG:-/var/log/sshvpnpanel/audit.log}"
    if [[ -f "${audit_log}" ]]; then
        local audit_total
        audit_total="$(wc -l < "${audit_log}" 2>/dev/null || echo "0")"
        printf "  %-20s %s\n" "Total Audit Events:" "${audit_total}"
        echo -e "\n  ${C_BOLD}Recent Audit Events:${C_RESET}"
        tail -10 "${audit_log}" | while IFS= read -r line; do
            echo -e "  ${C_DIM}${line}${C_RESET}"
        done
    else
        print_info "No audit log found"
    fi
}

# =============================================================================
# LOG MANAGEMENT
# =============================================================================

rotate_logs() {
    require_root || return 1

    local log_dir="${LOG_DIR:-/var/log/sshvpnpanel}"
    local max_size="${LOG_ROTATE_SIZE:-50}"
    local keep="${LOG_ROTATE_KEEP:-10}"

    print_info "Rotating logs in ${log_dir}..."

    local rotated=0
    for log_file in "${log_dir}"/*.log; do
        [[ -f "${log_file}" ]] || continue

        local size_mb
        size_mb=$(( $(stat -c%s "${log_file}" 2>/dev/null || echo 0) / 1024 / 1024 ))

        if [[ "${size_mb}" -ge "${max_size}" ]]; then
            print_info "Rotating ${log_file} (${size_mb}MB)"

            # Shift existing rotations
            for i in $(seq $((keep-1)) -1 1); do
                [[ -f "${log_file}.${i}" ]] && \
                    mv "${log_file}.${i}" "${log_file}.$((i+1))" 2>/dev/null
            done

            # Rotate current log
            mv "${log_file}" "${log_file}.1"
            touch "${log_file}"
            chmod 640 "${log_file}"

            # Remove old rotations beyond keep count
            for i in $(seq $((keep+1)) $((keep+10))); do
                rm -f "${log_file}.${i}" 2>/dev/null
            done

            (( rotated++ ))
        fi
    done

    if [[ "${rotated}" -eq 0 ]]; then
        print_info "No logs needed rotation"
    else
        print_success "Rotated ${rotated} log file(s)"
    fi

    log_audit "logs_rotated" "count=${rotated}"
}

view_logs() {
    clear_screen
    print_header "Log Viewer"

    local log_dir="${LOG_DIR:-/var/log/sshvpnpanel}"

    echo "Available logs:"
    local logs=()
    local i=0
    for log_file in "${log_dir}"/*.log; do
        [[ -f "${log_file}" ]] || continue
        local size
        size="$(stat -c%s "${log_file}" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "?")"
        echo -e "  $((++i)). $(basename "${log_file}") (${size})"
        logs+=("${log_file}")
    done

    [[ ${#logs[@]} -eq 0 ]] && { print_info "No log files found"; return; }

    local choice
    choice="$(read_int "Select log" 1 "${#logs[@]}")"
    local selected_log="${logs[$((choice-1))]}"

    echo
    echo "View options:"
    echo "  1. Last 50 lines"
    echo "  2. Last 100 lines"
    echo "  3. Last 200 lines"
    echo "  4. Full log (paginated)"
    echo "  5. Follow (tail -f)"
    echo "  6. Search"
    local view_choice
    view_choice="$(read_int "Select view" 1 6)"

    case "${view_choice}" in
        1) tail -50 "${selected_log}" | less -F ;;
        2) tail -100 "${selected_log}" | less -F ;;
        3) tail -200 "${selected_log}" | less -F ;;
        4) less -F "${selected_log}" ;;
        5)
            print_info "Following ${selected_log}. Press Ctrl+C to stop."
            tail -f "${selected_log}"
            ;;
        6)
            local search_term
            read_input "Search term" "" search_term
            grep --color=always "${search_term}" "${selected_log}" | less -F
            ;;
    esac
}

# =============================================================================
# MONITORING MENU
# =============================================================================

monitoring_menu() {
    while true; do
        clear_screen
        print_header "System Monitoring"

        echo -e "${C_BOLD}Overview:${C_RESET}"
        echo "  1. Live Dashboard"
        echo "  2. Real-Time Monitor (auto-refresh)"
        echo "  3. System Alerts"
        echo
        echo -e "${C_BOLD}Statistics:${C_RESET}"
        echo "  4. Bandwidth Statistics"
        echo "  5. Connection Statistics"
        echo "  6. Historical Statistics"
        echo
        echo -e "${C_BOLD}Logs:${C_RESET}"
        echo "  7. View Logs"
        echo "  8. Rotate Logs"
        echo "  9. Audit Log"
        echo "  0. Back to Main Menu"
        echo

        local choice
        choice="$(read_int "Select option" 0 9)"

        case "${choice}" in
            1) show_dashboard; read -rp $'\nPress Enter to continue...' ;;
            2) realtime_monitor ;;
            3) check_system_alerts; read -rp $'\nPress Enter to continue...' ;;
            4) show_bandwidth_stats; read -rp $'\nPress Enter to continue...' ;;
            5) show_connection_stats; read -rp $'\nPress Enter to continue...' ;;
            6) show_historical_stats; read -rp $'\nPress Enter to continue...' ;;
            7) view_logs ;;
            8) rotate_logs; read -rp $'\nPress Enter to continue...' ;;
            9) _view_audit_log ;;
            0) return 0 ;;
        esac
    done
}

_view_audit_log() {
    clear_screen
    print_header "Audit Log"
    local audit_log="${AUDIT_LOG:-/var/log/sshvpnpanel/audit.log}"
    if [[ -f "${audit_log}" ]]; then
        local lines
        lines="$(read_int "Lines to show" 1 1000 "50")"
        tail -"${lines}" "${audit_log}" | while IFS= read -r line; do
            echo -e "  ${C_DIM}${line}${C_RESET}"
        done
    else
        print_info "No audit log found"
    fi
    read -rp $'\nPress Enter to continue...'
}
