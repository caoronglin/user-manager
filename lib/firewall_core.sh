#!/bin/bash
# firewall_core.sh - 防火墙管理核心模块 v5.0
# 提供基于 UFW 的防火墙规则管理、端口映射、服务模板功能

# ============================================================
# UFW 状态检查与初始化
# ============================================================

# 检查 UFW 是否已安装和启用
check_ufw_status() {
    if ! command -v ufw &>/dev/null; then
        msg_err "UFW 未安装，请先安装: ${C_BOLD}sudo apt install ufw${C_RESET}"
        return 1
    fi

    local status
    status=$(priv_ufw status 2>/dev/null | head -n1)
    if [[ "$status" =~ inactive ]]; then
        msg_warn "UFW 防火墙当前状态: ${C_BYELLOW}未启用${C_RESET}"
        return 2
    fi

    return 0
}

# 初始化 UFW（首次使用）
init_ufw() {
    draw_header "初始化 UFW 防火墙"

    msg_step "设置默认策略: ${C_CYAN}拒绝所有入站${C_RESET}"
    priv_ufw default deny incoming

    msg_step "设置默认策略: ${C_CYAN}允许所有出站${C_RESET}"
    priv_ufw default allow outgoing

    msg_step "添加安全规则: ${C_CYAN}允许 SSH 连接${C_RESET}"
    priv_ufw allow ssh

    msg_step "启用 UFW 防火墙..."
    echo "y" | priv_ufw enable

    msg_ok "UFW 防火墙已初始化并启用"
}

# ============================================================
# 端口规则管理
# ============================================================

# 为用户添加端口访问规则
# 参数: $1=用户名  $2=端口号  $3=协议(tcp/udp,默认tcp)  $4=来源IP(可选)
add_port_rule() {
    local username="$1"
    local port="$2"
    local protocol="${3:-tcp}"
    local from_ip="${4:-}"

    if [[ -z "$username" || -z "$port" ]]; then
        msg_err "用户名和端口号不能为空"
        return 1
    fi

    # 验证端口号范围 1-65535
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        msg_err "无效的端口号: ${C_BOLD}$port${C_RESET} (有效范围: 1-65535)"
        return 1
    fi

    # 验证协议
    if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
        msg_err "无效的协议: ${C_BOLD}$protocol${C_RESET}，只支持 ${C_CYAN}tcp${C_RESET} 或 ${C_CYAN}udp${C_RESET}"
        return 1
    fi

    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    check_ufw_status || return 1

    # 构建并执行规则
    local rule_desc="Port $port/$protocol for user $username"

    if [[ -n "$from_ip" ]]; then
        msg_step "添加规则: 允许 ${C_BCYAN}$from_ip${C_RESET} → 端口 ${C_BGREEN}$port${C_RESET}/${C_CYAN}$protocol${C_RESET} (用户: ${C_BOLD}$username${C_RESET})"
        if priv_ufw allow from "$from_ip" to any port "$port" proto "$protocol" comment "$rule_desc"; then
            msg_ok "规则添加成功"
        else
            msg_err "规则添加失败"
            return 1
        fi
    else
        msg_step "添加规则: 允许 ${C_BCYAN}任意来源${C_RESET} → 端口 ${C_BGREEN}$port${C_RESET}/${C_CYAN}$protocol${C_RESET} (用户: ${C_BOLD}$username${C_RESET})"
        if priv_ufw allow "$port/$protocol" comment "$rule_desc"; then
            msg_ok "规则添加成功"
        else
            msg_err "规则添加失败"
            return 1
        fi
    fi

    record_user_event "$username" "firewall_add" "添加端口规则: $port/$protocol"

    # 记录到用户端口映射文件
    mkdir -p "$(dirname "$USER_PORT_MAP_FILE")"
    echo "$username:$port:$protocol:${from_ip:-any}:$(date +%Y-%m-%d)" >> "$USER_PORT_MAP_FILE"
    return 0
}

# 删除用户的端口访问规则
# 参数: $1=用户名  $2=端口号  $3=协议(tcp/udp,默认tcp)
# 删除用户的端口访问规则
delete_port_rule() {
    local username="$1"
    local port="$2"
    local protocol="${3:-tcp}"

    # 参数验证
    if [[ -z "$username" || -z "$port" ]]; then
        msg_err "用户名和端口号不能为空"
        return 1
    fi

    # 验证端口号范围 1-65535
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        msg_err "无效的端口号: ${C_BOLD}$port${C_RESET} (有效范围: 1-65535)"
        return 1
    fi

    # 验证协议
    if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
        msg_err "无效的协议: ${C_BOLD}$protocol${C_RESET}，只支持 tcp 或 udp"
        return 1
    fi

    check_ufw_status || return 1
    local username="$1"
    local port="$2"
    local protocol="${3:-tcp}"

    if [[ -z "$username" || -z "$port" ]]; then
        msg_err "用户名和端口号不能为空"
        return 1
    fi

    check_ufw_status || return 1

    msg_step "删除防火墙规则: 端口 ${C_BGREEN}$port${C_RESET}/${C_CYAN}$protocol${C_RESET} (用户: ${C_BOLD}$username${C_RESET})"

    # 查找匹配的规则编号（从大到小排序避免编号偏移）
    local rule_nums
    rule_nums=$(priv_ufw status numbered | grep "$port/$protocol" | grep -o "^\[[[:space:]]*[0-9]*\]" | tr -d '[] ' | sort -rn)

    if [[ -z "$rule_nums" ]]; then
        msg_warn "未找到端口 ${C_BOLD}$port/$protocol${C_RESET} 的规则"
        return 1
    fi

    local deleted=0
    for num in $rule_nums; do
        msg_info "  删除规则 ${C_DIM}#${num}${C_RESET}"
        echo "y" | priv_ufw delete "$num"
        ((deleted+=1))
    done

    if (( deleted > 0 )); then
        msg_ok "成功删除 ${C_BGREEN}$deleted${C_RESET} 条规则"
        record_user_event "$username" "firewall_del" "删除端口规则: $port/$protocol"

        # 从映射文件中移除
        if [[ -f "$USER_PORT_MAP_FILE" ]]; then
            remove_file_entry "$USER_PORT_MAP_FILE" "^${username}:${port}:${protocol}:"
        fi
        return 0
    else
        msg_err "规则删除失败"
        return 1
    fi
}

# 删除用户的所有端口规则
# 参数: $1=用户名
delete_user_all_rules() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    check_ufw_status || return 1

    draw_header "删除用户 $username 的所有防火墙规则"

    if [[ ! -f "$USER_PORT_MAP_FILE" ]]; then
        msg_info "没有端口映射记录"
        return 0
    fi

    # 先收集该用户的端口信息
    local ports=()
    while IFS=: read -r user port protocol _source _date; do
        if [[ "$user" == "$username" ]]; then
            ports+=("$port:$protocol")
        fi
    done < "$USER_PORT_MAP_FILE"

    if (( ${#ports[@]} == 0 )); then
        msg_info "用户 ${C_BOLD}$username${C_RESET} 没有防火墙规则"
        return 0
    fi

    local deleted=0
    for entry in "${ports[@]}"; do
        local p="${entry%%:*}"
        local proto="${entry##*:}"
        delete_port_rule "$username" "$p" "$proto" && ((deleted+=1))
    done

    msg_ok "共删除 ${C_BGREEN}$deleted${C_RESET} 条规则"
    record_user_event "$username" "firewall_del_all" "删除所有防火墙规则"
    return 0
}

# ============================================================
# 规则查询与展示
# ============================================================

# 列出所有防火墙规则（彩色输出）
list_firewall_rules() {
    check_ufw_status || return 1

    draw_header "🔥 防火墙规则列表"

    local status_output
    status_output=$(priv_ufw status verbose 2>/dev/null)

    # 显示状态摘要
    local fw_status
    fw_status=$(echo "$status_output" | head -n1)
    echo -e "  ${C_DIM}状态:${C_RESET} ${C_BGREEN}$fw_status${C_RESET}"
    draw_line 60
    echo ""

    # 显示编号规则（按类型着色）
    priv_ufw status numbered 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" =~ ALLOW ]]; then
            echo -e "  ${C_BGREEN}$line${C_RESET}"
        elif [[ "$line" =~ DENY ]]; then
            echo -e "  ${C_BRED}$line${C_RESET}"
        elif [[ "$line" =~ REJECT ]]; then
            echo -e "  ${C_BYELLOW}$line${C_RESET}"
        elif [[ "$line" =~ LIMIT ]]; then
            echo -e "  ${C_BCYAN}$line${C_RESET}"
        else
            echo -e "  ${C_DIM}$line${C_RESET}"
        fi
    done

    echo ""
}

# 列出指定用户的防火墙规则（彩色表格）
# 参数: $1=用户名
# 列出指定用户的防火墙规则（彩色表格）
list_user_firewall_rules() {
    local username="$1"

    # 参数验证
    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    if [[ ! -f "$USER_PORT_MAP_FILE" ]]; then
        msg_info "用户 ${C_BOLD}$username${C_RESET} 没有防火墙规则记录"
        return 0
    fi

    draw_header "用户 $username 的防火墙规则"

    # 表头
    printf "  ${C_BOLD}${C_WHITE}%-12s %-10s %-18s %-14s${C_RESET}\n" "端口" "协议" "来源" "添加日期"
    printf "  ${C_DIM}%-12s %-10s %-18s %-14s${C_RESET}\n" "──────────" "────────" "────────────────" "────────────"

    local found=0
    while IFS=: read -r user port protocol source date; do
        if [[ "$user" == "$username" ]]; then
            local proto_color="$C_CYAN"
            [[ "$protocol" == "udp" ]] && proto_color="$C_YELLOW"
            printf "  ${C_BGREEN}%-12s${C_RESET} ${proto_color}%-10s${C_RESET} ${C_BCYAN}%-18s${C_RESET} ${C_DIM}%-14s${C_RESET}\n" \
                "$port" "$protocol" "$source" "$date"
            ((found+=1))
        fi
    done < "$USER_PORT_MAP_FILE"

    if (( found == 0 )); then
        msg_info "该用户没有防火墙规则"
    else
        echo ""
        msg_info "共 ${C_BOLD}$found${C_RESET} 条规则"
    fi
    echo ""
}

# 显示所有端口使用情况（彩色表格）
show_port_usage() {
    if [[ ! -f "$USER_PORT_MAP_FILE" ]] || [[ ! -s "$USER_PORT_MAP_FILE" ]]; then
        msg_info "没有端口使用记录"
        return 0
    fi

    draw_header "📊 端口使用情况"

    # 表头
    printf "  ${C_BOLD}${C_WHITE}%-16s %-12s %-10s %-18s %-14s${C_RESET}\n" \
        "用户" "端口" "协议" "来源" "添加日期"
    printf "  ${C_DIM}%-16s %-12s %-10s %-18s %-14s${C_RESET}\n" \
        "──────────────" "──────────" "────────" "────────────────" "────────────"

    local total=0
    while IFS=: read -r user port protocol source date; do
        [[ -z "$user" ]] && continue
        local proto_color="$C_CYAN"
        [[ "$protocol" == "udp" ]] && proto_color="$C_YELLOW"
        printf "  ${C_BOLD}%-16s${C_RESET} ${C_BGREEN}%-12s${C_RESET} ${proto_color}%-10s${C_RESET} ${C_BCYAN}%-18s${C_RESET} ${C_DIM}%-14s${C_RESET}\n" \
            "$user" "$port" "$protocol" "$source" "$date"
        ((total+=1))
    done < "$USER_PORT_MAP_FILE"

    echo ""
    draw_line 60
    msg_info "共 ${C_BOLD}$total${C_RESET} 条端口规则"

    # 按用户统计
    echo ""
    msg_info "按用户统计:"
    awk -F: '{count[$1]++} END {for (u in count) printf "    %-16s %d 条规则\n", u, count[u]}' \
        "$USER_PORT_MAP_FILE" | sort
    echo ""
}

# ============================================================
# 批量操作
# ============================================================

# 为用户添加端口范围规则
# 参数: $1=用户名  $2=起始端口  $3=结束端口  $4=协议(默认tcp)
add_port_range() {
    local username="$1"
    local start_port="$2"
    local end_port="$3"
    local protocol="${4:-tcp}"

    if [[ -z "$username" || -z "$start_port" || -z "$end_port" ]]; then
        msg_err "参数不完整: 需要 ${C_BOLD}用户名 起始端口 结束端口${C_RESET}"
        return 1
    fi

    # 验证端口范围
    if ! [[ "$start_port" =~ ^[0-9]+$ ]] || (( start_port < 1 || start_port > 65535 )); then
        msg_err "无效的起始端口: ${C_BOLD}$start_port${C_RESET}"
        return 1
    fi
    if ! [[ "$end_port" =~ ^[0-9]+$ ]] || (( end_port < 1 || end_port > 65535 )); then
        msg_err "无效的结束端口: ${C_BOLD}$end_port${C_RESET}"
        return 1
    fi
    if (( start_port > end_port )); then
        msg_err "起始端口 ${C_BOLD}$start_port${C_RESET} 不能大于结束端口 ${C_BOLD}$end_port${C_RESET}"
        return 1
    fi

    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    check_ufw_status || return 1

    msg_step "为用户 ${C_BOLD}$username${C_RESET} 添加端口范围: ${C_BGREEN}$start_port-$end_port${C_RESET}/${C_CYAN}$protocol${C_RESET}"

    local rule_desc="Port range $start_port:$end_port/$protocol for user $username"
    if priv_ufw allow "$start_port:$end_port/$protocol" comment "$rule_desc"; then
        msg_ok "端口范围规则添加成功"
        record_user_event "$username" "firewall_add_range" "添加端口范围: $start_port-$end_port/$protocol"

        # 记录到映射文件
        mkdir -p "$(dirname "$USER_PORT_MAP_FILE")"
        echo "$username:$start_port-$end_port:$protocol:any:$(date +%Y-%m-%d)" >> "$USER_PORT_MAP_FILE"
        return 0
    else
        msg_err "端口范围规则添加失败"
        return 1
    fi
}

# ============================================================
# 预设服务模板
# ============================================================

# 应用常用服务的预设规则
apply_service_template() {
    local username="$1"
    local service="$2"

    # 参数验证
    if [[ -z "$username" || -z "$service" ]]; then
        msg_err "用户名和服务类型不能为空"
        return 1
    fi

    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    # 验证服务类型
    local valid_services="web|database|ssh|jupyter|ml|all"
    if ! [[ "$service" =~ ^($valid_services)$ ]]; then
        msg_err "无效的服务类型: ${C_BOLD}$service${C_RESET}"
        msg_info "支持的服务类型: web, database, ssh, jupyter, ml, all"
        return 1
    fi

    case "$service" in
        web)
            draw_header "应用 Web 服务模板"
            msg_step "添加 HTTP  (${C_BGREEN}80/tcp${C_RESET})"
            add_port_rule "$username" 80 tcp
            msg_step "添加 HTTPS (${C_BGREEN}443/tcp${C_RESET})"
            add_port_rule "$username" 443 tcp
            ;;
        database)
            draw_header "应用数据库服务模板"
            echo ""
            msg_info "选择数据库类型:"
            echo -e "  ${C_DIM}[${C_RESET}${C_BCYAN} 1${C_RESET}${C_DIM}]${C_RESET}  MySQL      ${C_DIM}(3306/tcp)${C_RESET}"
            echo -e "  ${C_DIM}[${C_RESET}${C_BCYAN} 2${C_RESET}${C_DIM}]${C_RESET}  PostgreSQL ${C_DIM}(5432/tcp)${C_RESET}"
            echo -e "  ${C_DIM}[${C_RESET}${C_BCYAN} 3${C_RESET}${C_DIM}]${C_RESET}  MongoDB    ${C_DIM}(27017/tcp)${C_RESET}"
            echo ""
            echo -ne "  ${C_BYELLOW}❯${C_RESET} "
            read -r db_choice
            case "$db_choice" in
                1|mysql)
                    msg_step "添加 MySQL (${C_BGREEN}3306/tcp${C_RESET})"
                    add_port_rule "$username" 3306 tcp
                    ;;
                2|postgresql|pg)
                    msg_step "添加 PostgreSQL (${C_BGREEN}5432/tcp${C_RESET})"
                    add_port_rule "$username" 5432 tcp
                    ;;
                3|mongodb|mongo)
                    msg_step "添加 MongoDB (${C_BGREEN}27017/tcp${C_RESET})"
                    add_port_rule "$username" 27017 tcp
                    ;;
                *)
                    msg_err "不支持的数据库类型: ${C_BOLD}$db_choice${C_RESET}"
                    return 1
                    ;;
            esac
            ;;
        ssh)
            draw_header "应用 SSH 服务模板"
            echo -ne "  ${C_BYELLOW}❯${C_RESET} 输入 SSH 端口 ${C_DIM}(默认 22)${C_RESET}: "
            read -r ssh_port
            ssh_port="${ssh_port:-22}"
            if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
                msg_err "无效的端口号: ${C_BOLD}$ssh_port${C_RESET}"
                return 1
            fi
            msg_step "添加 SSH (${C_BGREEN}${ssh_port}/tcp${C_RESET})"
            add_port_rule "$username" "$ssh_port" tcp
            ;;
        jupyter)
            draw_header "应用 Jupyter Notebook 模板"
            msg_step "添加 Jupyter (${C_BGREEN}8888/tcp${C_RESET})"
            add_port_rule "$username" 8888 tcp
            ;;
        *)
            msg_err "未知的服务类型: ${C_BOLD}$service${C_RESET}"
            msg_info "支持的类型: ${C_CYAN}web${C_RESET} | ${C_CYAN}database${C_RESET} | ${C_CYAN}ssh${C_RESET} | ${C_CYAN}jupyter${C_RESET}"
            return 1
            ;;
    esac

    msg_ok "服务模板 ${C_BOLD}$service${C_RESET} 应用完成"
}
