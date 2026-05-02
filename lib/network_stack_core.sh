#!/bin/bash
# network_stack_core.sh - Ubuntu 网络栈诊断核心模块

if [[ -n "${USER_MANAGER_NETWORK_STACK_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
USER_MANAGER_NETWORK_STACK_LOADED=1

NETWORK_STACK_NETPLAN_DIR="${NETWORK_STACK_NETPLAN_DIR:-/etc/netplan}"
NETWORK_STACK_NETWORKMANAGER_DIR="${NETWORK_STACK_NETWORKMANAGER_DIR:-/etc/NetworkManager}"
NETWORK_STACK_NETWORKD_DIR="${NETWORK_STACK_NETWORKD_DIR:-/etc/systemd/network}"
NETWORK_STACK_RESOLV_CONF="${NETWORK_STACK_RESOLV_CONF:-/etc/resolv.conf}"
NETWORK_STACK_JOURNAL_LINES="${NETWORK_STACK_JOURNAL_LINES:-40}"

network_stack_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

network_stack_join_unique_csv() {
    awk 'NF && !seen[$0]++ { items[++count] = $0 } END { for (i = 1; i <= count; i++) printf "%s%s", items[i], (i < count ? "," : "") }'
}

network_stack_has_netplan_files() {
    local file

    [[ -d "$NETWORK_STACK_NETPLAN_DIR" ]] || return 1
    for file in "$NETWORK_STACK_NETPLAN_DIR"/*.yaml "$NETWORK_STACK_NETPLAN_DIR"/*.yml; do
        [[ -f "$file" ]] && return 0
    done
    return 1
}

network_stack_detect_manager() {
    if network_stack_has_netplan_files; then
        printf 'netplan\n'
    elif [[ -d "$NETWORK_STACK_NETWORKMANAGER_DIR" ]] || command -v nmcli >/dev/null 2>&1; then
        printf 'NetworkManager\n'
    elif [[ -d "$NETWORK_STACK_NETWORKD_DIR" ]] || command -v networkctl >/dev/null 2>&1; then
        printf 'systemd-networkd\n'
    else
        printf 'unknown\n'
    fi
}

network_stack_summarize_netplan_configs() {
    local file count=0
    local -a files=()
    local renderers interfaces

    if ! network_stack_has_netplan_files; then
        printf 'files=0;renderers=none;interfaces=none'
        return 0
    fi

    for file in "$NETWORK_STACK_NETPLAN_DIR"/*.yaml "$NETWORK_STACK_NETPLAN_DIR"/*.yml; do
        [[ -f "$file" ]] || continue
        files+=("$file")
    done

    count="${#files[@]}"

    renderers="$({
        for file in "${files[@]}"; do
            sed -nE 's/^[[:space:]]*renderer:[[:space:]]*"?([^"#]+)"?.*/\1/p' "$file"
        done
    } | sed 's/[[:space:]]*$//' | sed '/^[[:space:]]*$/d' | LC_ALL=C sort | network_stack_join_unique_csv)"

    interfaces="$({
        for file in "${files[@]}"; do
            awk '
                /^[[:space:]]*(ethernets|wifis|bridges|bonds|vlans):[[:space:]]*$/ {
                    in_section = 1
                    next
                }

                in_section && /^[[:space:]]{4}[[:alnum:]_.:-]+:[[:space:]]*$/ {
                    item = $0
                    sub(/^[[:space:]]+/, "", item)
                    sub(/:[[:space:]]*$/, "", item)
                    print item
                    next
                }

                in_section && /^[[:space:]]{0,3}[[:alnum:]_.:-]+:[[:space:]]*$/ {
                    in_section = 0
                }
            ' "$file"
        done
    } | sort | network_stack_join_unique_csv)"

    [[ -z "$renderers" ]] && renderers="none"
    [[ -z "$interfaces" ]] && interfaces="none"

    printf 'files=%s;renderers=%s;interfaces=%s' "$count" "$renderers" "$interfaces"
}

network_stack_extract_default_routes_from_text() {
    local text="$1"
    local line trimmed via dev metric summary=""

    while IFS= read -r line; do
        trimmed="$(network_stack_trim "$line")"
        [[ "$trimmed" == default* ]] || continue

        via="?"
        dev="?"
        metric="?"

        [[ "$trimmed" =~ via[[:space:]]+([^[:space:]]+) ]] && via="${BASH_REMATCH[1]}"
        [[ "$trimmed" =~ dev[[:space:]]+([^[:space:]]+) ]] && dev="${BASH_REMATCH[1]}"
        [[ "$trimmed" =~ metric[[:space:]]+([^[:space:]]+) ]] && metric="${BASH_REMATCH[1]}"

        if [[ -n "$summary" ]]; then
            summary+="; "
        fi
        summary+="$dev via $via metric $metric"
    done <<< "$text"

    [[ -z "$summary" ]] && summary="none"
    printf '%s' "$summary"
}

network_stack_extract_dns_servers_from_text() {
    local text="$1"

    printf '%s\n' "$text" | awk '
        /^[[:space:]]*nameserver[[:space:]]+/ {
            print $2
            next
        }

        /DNS Servers:/ {
            line = $0
            sub(/^.*DNS Servers:[[:space:]]*/, "", line)
            split(line, parts, /[[:space:]]+/)
            for (i in parts) {
                if (parts[i] ~ /[0-9a-fA-F:.]+/) {
                    print parts[i]
                }
            }
            next
        }

        /IP[46]\.DNS\[[0-9]+\]:/ {
            line = $0
            sub(/^.*IP[46]\.DNS\[[0-9]+\]:[[:space:]]*/, "", line)
            split(line, parts, /[[:space:]]+/)
            for (i in parts) {
                if (parts[i] ~ /[0-9a-fA-F:.]+/) {
                    print parts[i]
                }
            }
        }
    ' | network_stack_join_unique_csv
}

network_stack_summarize_nmcli_status_from_text() {
    local text="$1"

    printf '%s\n' "$text" | awk '
        BEGIN {
            connected = 0
            disconnected = 0
            count = 0
        }

        NR == 1 && $1 == "DEVICE" {
            next
        }

        NF >= 3 {
            device = $1
            type = $2
            state = $3

            if (state ~ /^connected/) {
                connected++
            } else if (state ~ /^disconnected/) {
                disconnected++
            }

            items[++count] = device "(" type ":" state ")"
        }

        END {
            printf "tool=nmcli;connected=%d;disconnected=%d;devices=", connected, disconnected
            if (count == 0) {
                printf "none"
            } else {
                for (i = 1; i <= count; i++) {
                    printf "%s%s", items[i], (i < count ? "," : "")
                }
            }
        }
    '
}

network_stack_summarize_networkctl_status_from_text() {
    local text="$1"

    printf '%s\n' "$text" | awk '
        BEGIN {
            routable = 0
            degraded = 0
            count = 0
        }

        $1 == "IDX" || $1 == "LINK" || /^-/ || NF < 4 {
            next
        }

        {
            if ($1 ~ /^[0-9]+$/) {
                link = $2
                operational = $4
                setup = $5
            } else {
                link = $1
                operational = $3
                setup = $4
            }

            if (operational == "routable") {
                routable++
            }
            if (operational ~ /degraded|carrier|off/) {
                degraded++
            }

            items[++count] = link "(" operational ":" setup ")"
        }

        END {
            printf "tool=networkctl;routable=%d;degraded=%d;links=", routable, degraded
            if (count == 0) {
                printf "none"
            } else {
                for (i = 1; i <= count; i++) {
                    printf "%s%s", items[i], (i < count ? "," : "")
                }
            }
        }
    '
}

network_stack_summarize_journal_from_text() {
    local text="$1"

    printf '%s\n' "$text" | awk '
        BEGIN {
            lines = 0
            warnings = 0
            errors = 0
            preview_count = 0
        }

        NF {
            lines++
            lower = tolower($0)

            if (lower ~ /<err>| error| failed| failure|critical|fatal/) {
                errors++
            } else if (lower ~ /<warn>| warning| timeout| degraded|no-carrier|link down/) {
                warnings++
            }

            if (preview_count < 3) {
                preview[++preview_count] = $0
            }
        }

        END {
            printf "lines=%d;warnings=%d;errors=%d;preview=", lines, warnings, errors
            if (preview_count == 0) {
                printf "none"
            } else {
                for (i = 1; i <= preview_count; i++) {
                    printf "%s%s", preview[i], (i < preview_count ? " | " : "")
                }
            }
        }
    '
}

network_stack_get_default_route_raw() {
    if command -v ip >/dev/null 2>&1; then
        ip route show default 2>/dev/null || true
    fi
}

network_stack_get_dns_raw() {
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status 2>/dev/null || true
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli device show 2>/dev/null || true
    elif [[ -f "$NETWORK_STACK_RESOLV_CONF" ]]; then
        cat "$NETWORK_STACK_RESOLV_CONF" 2>/dev/null || true
    fi
}

network_stack_get_nmcli_status_raw() {
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device status 2>/dev/null || true
    fi
}

network_stack_get_networkctl_status_raw() {
    if command -v networkctl >/dev/null 2>&1; then
        networkctl --no-pager 2>/dev/null || true
    fi
}

network_stack_get_recent_journal_raw() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --no-pager -n "$NETWORK_STACK_JOURNAL_LINES" \
            -u NetworkManager -u systemd-networkd -u systemd-resolved 2>/dev/null || true
    fi
}

network_stack_collect_report() {
    local manager netplan_summary default_routes dns_servers
    local nmcli_raw networkctl_raw status_summary journal_summary

    manager="$(network_stack_detect_manager)"
    netplan_summary="$(network_stack_summarize_netplan_configs)"
    default_routes="$(network_stack_extract_default_routes_from_text "$(network_stack_get_default_route_raw)")"
    dns_servers="$(network_stack_extract_dns_servers_from_text "$(network_stack_get_dns_raw)")"
    [[ -z "$dns_servers" ]] && dns_servers="none"

    nmcli_raw="$(network_stack_get_nmcli_status_raw)"
    networkctl_raw="$(network_stack_get_networkctl_status_raw)"

    if [[ -n "$nmcli_raw" ]]; then
        status_summary="$(network_stack_summarize_nmcli_status_from_text "$nmcli_raw")"
    elif [[ -n "$networkctl_raw" ]]; then
        status_summary="$(network_stack_summarize_networkctl_status_from_text "$networkctl_raw")"
    else
        status_summary="tool=none"
    fi

    journal_summary="$(network_stack_summarize_journal_from_text "$(network_stack_get_recent_journal_raw)")"

    printf '%s\n' \
        "manager=$manager" \
        "netplan_summary=$netplan_summary" \
        "default_routes=$default_routes" \
        "dns_servers=$dns_servers" \
        "status_summary=$status_summary" \
        "journal_summary=$journal_summary"
}

show_network_stack_panel() {
    local report line key value
    local manager="unknown" netplan_summary="files=0;renderers=none;interfaces=none"
    local default_routes="none" dns_servers="none" status_summary="tool=none"
    local journal_summary="lines=0;warnings=0;errors=0;preview=none"

    if declare -F draw_header >/dev/null 2>&1; then
        draw_header "Ubuntu 网络栈诊断"
    else
        printf 'Ubuntu 网络栈诊断\n'
    fi

    report="$(network_stack_collect_report)"
    while IFS='=' read -r key value; do
        case "$key" in
            manager) manager="$value" ;;
            netplan_summary) netplan_summary="$value" ;;
            default_routes) default_routes="$value" ;;
            dns_servers) dns_servers="$value" ;;
            status_summary) status_summary="$value" ;;
            journal_summary) journal_summary="$value" ;;
        esac
    done <<< "$report"

    if declare -F draw_info_card >/dev/null 2>&1; then
        draw_info_card "网络管理器:" "$manager"
        draw_info_card "Netplan 摘要:" "$netplan_summary"
        draw_info_card "默认路由:" "$default_routes"
        draw_info_card "DNS:" "$dns_servers"
        draw_info_card "链路状态:" "$status_summary"
        draw_info_card "最近日志:" "$journal_summary"
    else
        printf '网络管理器: %s\n' "$manager"
        printf 'Netplan 摘要: %s\n' "$netplan_summary"
        printf '默认路由: %s\n' "$default_routes"
        printf 'DNS: %s\n' "$dns_servers"
        printf '链路状态: %s\n' "$status_summary"
        printf '最近日志: %s\n' "$journal_summary"
    fi

    echo ""
}

# ============================================================
# 网络信息查询（从 common.sh 迁移）
# ============================================================

# 获取本机 IP 地址
get_local_ip() {
    local ip=""
    
    # 尝试 ip 命令
    if command -v ip &>/dev/null; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)
    fi
    
    # 回退到 ifconfig
    if [[ -z "$ip" ]] && command -v ifconfig &>/dev/null; then
        ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | 
             grep -Eo '([0-9]*\.){3}[0-9]*' | 
             grep -v '127.0.0.1' | head -n 1 || true)
    fi
    
    # 回退到 hostname
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    
    echo "$ip"
}

# 获取公网 IP 地址
get_public_ip() {
    local ip=""
    
    local services=(
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://icanhazip.com"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -fsSL --max-time 10 "$service" 2>/dev/null || true)
        if [[ -n "$ip" ]]; then
            break
        fi
    done
    
    echo "$ip"
}

# 获取 Tailscale IP 地址
get_tailscale_ip() {
    local ip=""
    
    if command -v tailscale &>/dev/null; then
        ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
    fi
    
    if [[ -z "$ip" ]] && command -v ip &>/dev/null; then
        ip=$(ip addr show tailscale0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n 1 || true)
    fi
    
    echo "$ip"
}

# 显示完整的网络信息
show_network_info() {
    echo ""
    draw_header "网络信息"
    
    local local_ip
    local_ip=$(get_local_ip)
    echo ""
    msg_info "本机 IP 地址:"
    if [[ -n "$local_ip" ]]; then
        echo -e "  ${C_BGREEN}$local_ip${C_RESET}"
    else
        echo -e "  ${C_BRED}无法检测${C_RESET}"
    fi
    
    local public_ip
    public_ip=$(get_public_ip)
    echo ""
    msg_info "公网 IP 地址:"
    if [[ -n "$public_ip" ]]; then
        echo -e "  ${C_BGREEN}$public_ip${C_RESET}"
    else
        echo -e "  ${C_BYELLOW}无法检测（可能无网络连接）${C_RESET}"
    fi
    
    local tailscale_ip
    tailscale_ip=$(get_tailscale_ip)
    echo ""
    msg_info "Tailscale IP 地址 (远程连接):"
    if [[ -n "$tailscale_ip" ]]; then
        echo -e "  ${C_BGREEN}$tailscale_ip${C_RESET}"
        echo -e "  ${C_CYAN}这是您的 Tailscale VPN IP，用于远程连接${C_RESET}"
    else
        echo -e "  ${C_BYELLOW}未检测到 Tailscale${C_RESET}"
    fi
    
    echo ""
    draw_line "$MENU_WIDTH"
    echo ""
}
