#!/bin/bash
# dns_core.sh - DNS 白名单管理模块 v5.0
# 通过 iptables owner match 规则限制用户只能访问白名单域名
# 原理：按用户 UID 阻止出站 DNS/HTTP/HTTPS 流量，再放行白名单域名解析的 IP

# ============================================================
# 白名单配置管理
# ============================================================

# 初始化 DNS 白名单配置文件
init_dns_whitelist() {
    mkdir -p "$(dirname "$DNS_CONFIG_FILE")"

    if [[ -f "$DNS_CONFIG_FILE" ]]; then
        msg_info "DNS 白名单配置已存在: ${C_DIM}$DNS_CONFIG_FILE${C_RESET}"
        return 0
    fi

    msg_step "创建 DNS 白名单配置文件..."

    cat > "$DNS_CONFIG_FILE" << 'EOF'
# DNS 白名单配置 - 每行一个域名
# 以 # 开头的行为注释，空行会被忽略
# 修改后需执行 refresh_dns_rules 使其生效

# === 系统软件源 ===
mirrors.aliyun.com
mirrors.tuna.tsinghua.edu.cn
archive.ubuntu.com
security.ubuntu.com
packages.microsoft.com

# === 编程语言包管理 ===
pypi.org
files.pythonhosted.org
registry.npmjs.org
rubygems.org
crates.io

# === 代码托管 ===
github.com
github.githubassets.com
raw.githubusercontent.com
gitlab.com
bitbucket.org

# === 容器与工具 ===
registry.hub.docker.com
download.docker.com
conda.anaconda.org
repo.anaconda.com
EOF

    msg_ok "DNS 白名单已初始化: ${C_BOLD}$DNS_CONFIG_FILE${C_RESET}"
    local count
    count=$(grep -cvE '^\s*(#|$)' "$DNS_CONFIG_FILE")
    msg_info "包含 ${C_BOLD}$count${C_RESET} 个默认域名"
}

# 显示当前白名单内容（彩色输出）
show_dns_whitelist() {
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        msg_warn "DNS 白名单尚未初始化，请先执行 ${C_BOLD}init_dns_whitelist${C_RESET}"
        return 1
    fi

    draw_header "🌐 DNS 白名单"

    local idx=0
    while IFS= read -r line; do
        # 跳过空行
        [[ -z "$line" ]] && continue
        # 注释行
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            echo -e "  ${C_DIM}$line${C_RESET}"
        else
            ((idx+=1))
            printf "  ${C_BGREEN}%3d${C_RESET}  ${C_BCYAN}%s${C_RESET}\n" "$idx" "$line"
        fi
    done < "$DNS_CONFIG_FILE"

    echo ""
    draw_line 50
    msg_info "共 ${C_BOLD}$idx${C_RESET} 个白名单域名"
    echo ""
}

# 添加域名到白名单
# 参数: $1=域名
add_dns_entry() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        msg_err "域名不能为空"
        return 1
    fi

    # 验证域名格式 (允许通配符 * 和星号前缀如 *.example.com)
    if ! [[ "$domain" =~ ^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})$ ]]; then
        msg_err "无效的域名格式: ${C_BOLD}$domain${C_RESET}"
        return 1
    fi

    init_dns_whitelist

    # 检查是否重复
    if grep -qxF "$domain" "$DNS_CONFIG_FILE" 2>/dev/null; then
        msg_warn "域名 ${C_BCYAN}$domain${C_RESET} 已存在于白名单中"
        return 1
    fi

    echo "$domain" >> "$DNS_CONFIG_FILE"
    msg_ok "已添加域名: ${C_BCYAN}$domain${C_RESET}"
    msg_info "提示: 执行 ${C_BOLD}refresh_dns_rules${C_RESET} 使更改生效"
    return 0
}

# 从白名单移除域名
# 参数: $1=域名
remove_dns_entry() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        msg_err "域名不能为空"
        return 1
    fi

    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        msg_err "DNS 白名单文件不存在"
        return 1
    fi

    if ! grep -qxF "$domain" "$DNS_CONFIG_FILE" 2>/dev/null; then
        msg_warn "域名 ${C_BCYAN}$domain${C_RESET} 不在白名单中"
        return 1
    fi

    remove_file_entry "$DNS_CONFIG_FILE" "^${domain}$"
    msg_ok "已移除域名: ${C_BCYAN}$domain${C_RESET}"
    msg_info "提示: 执行 ${C_BOLD}refresh_dns_rules${C_RESET} 使更改生效"
    return 0
}

# ============================================================
# iptables 规则管理（内部辅助函数）
# ============================================================

# 获取 DNS 管理链名称
_dns_chain_name() {
    local username="$1"
    echo "DNS_WL_${username}"
}

# 解析域名到 IP 列表
# 参数: $1=域名
_resolve_domain() {
    local domain="$1"
    # 使用 getent 或 dig 或 host 解析
    if command -v dig &>/dev/null; then
        dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.'
    elif command -v host &>/dev/null; then
        host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}'
    elif command -v getent &>/dev/null; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
    else
        msg_warn "没有可用的 DNS 解析工具 (dig/host/getent)"
        return 1
    fi
}

# 读取白名单中的纯域名列表（跳过注释和空行）
_get_whitelist_domains() {
    [[ -f "$DNS_CONFIG_FILE" ]] || return 1
    grep -vE '^\s*(#|$)' "$DNS_CONFIG_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ============================================================
# DNS 限制规则操作
# ============================================================

# 为用户应用 DNS/网络限制
# 参数: $1=用户名
apply_dns_restrictions() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        msg_err "DNS 白名单文件不存在，请先执行 ${C_BOLD}init_dns_whitelist${C_RESET}"
        return 1
    fi

    local uid
    uid=$(id -u "$username")
    local chain
    chain=$(_dns_chain_name "$username")

    draw_header "为用户 $username 应用 DNS 限制"
    msg_info "用户 UID: ${C_BOLD}$uid${C_RESET}"

    # --- 清理旧规则（如果存在）---
    msg_step "清理已有规则..."
    # 删除 OUTPUT 链中对该自定义链的引用
    run_privileged iptables -D OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null || true
    # 清空并删除自定义链
    run_privileged iptables -F "$chain" 2>/dev/null || true
    run_privileged iptables -X "$chain" 2>/dev/null || true

    # --- 创建自定义链 ---
    msg_step "创建自定义规则链: ${C_CYAN}$chain${C_RESET}"
    run_privileged iptables -N "$chain"

    # --- 允许已建立连接 ---
    msg_step "允许已建立的连接..."
    run_privileged iptables -A "$chain" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # --- 允许本地回环 ---
    run_privileged iptables -A "$chain" -o lo -j ACCEPT

    # --- 解析白名单域名并添加放行规则 ---
    msg_step "解析白名单域名并添加放行规则..."
    local domain ip_list resolved_count=0 domain_count=0

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        ((domain_count+=1))

        ip_list=$(_resolve_domain "$domain")
        if [[ -z "$ip_list" ]]; then
            msg_warn "  无法解析: ${C_DIM}$domain${C_RESET}"
            continue
        fi

        local ip_count=0
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            # 允许到该 IP 的 HTTP/HTTPS/DNS 流量
            run_privileged iptables -A "$chain" -d "$ip" -p tcp --dport 80  -j ACCEPT
            run_privileged iptables -A "$chain" -d "$ip" -p tcp --dport 443 -j ACCEPT
            run_privileged iptables -A "$chain" -d "$ip" -p udp --dport 53  -j ACCEPT
            run_privileged iptables -A "$chain" -d "$ip" -p tcp --dport 53  -j ACCEPT
            ((ip_count+=1))
        done <<< "$ip_list"

        ((resolved_count+=1))
        msg_info "  ${C_BCYAN}$domain${C_RESET} → ${C_BGREEN}$ip_count${C_RESET} 个 IP"
    done < <(_get_whitelist_domains)

    # --- 阻止该用户所有出站 DNS/HTTP/HTTPS ---
    msg_step "添加默认阻止规则..."
    run_privileged iptables -A "$chain" -p tcp --dport 80  -j DROP
    run_privileged iptables -A "$chain" -p tcp --dport 443 -j DROP
    run_privileged iptables -A "$chain" -p udp --dport 53  -j DROP
    run_privileged iptables -A "$chain" -p tcp --dport 53  -j DROP

    # --- 将自定义链挂载到 OUTPUT ---
    msg_step "应用规则到 OUTPUT 链..."
    run_privileged iptables -A OUTPUT -m owner --uid-owner "$uid" -j "$chain"

    echo ""
    msg_ok "DNS 限制已应用 — 用户: ${C_BOLD}$username${C_RESET}"
    msg_info "白名单域名: ${C_BOLD}$domain_count${C_RESET} 个，成功解析: ${C_BGREEN}$resolved_count${C_RESET} 个"
    record_user_event "$username" "dns_restrict" "应用 DNS 白名单限制"
    return 0
}

# 移除用户的 DNS/网络限制
# 参数: $1=用户名
remove_dns_restrictions() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local uid
    uid=$(id -u "$username" 2>/dev/null)
    if [[ -z "$uid" ]]; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    local chain
    chain=$(_dns_chain_name "$username")

    msg_step "移除用户 ${C_BOLD}$username${C_RESET} 的 DNS 限制..."

    # 从 OUTPUT 中移除引用（可能有多条，循环删除）
    local removed=0
    while run_privileged iptables -D OUTPUT -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null; do
        ((removed+=1))
    done

    # 清空并删除自定义链
    if run_privileged iptables -F "$chain" 2>/dev/null; then
        run_privileged iptables -X "$chain" 2>/dev/null
    fi

    if (( removed > 0 )); then
        msg_ok "DNS 限制已移除 — 用户: ${C_BOLD}$username${C_RESET}"
        record_user_event "$username" "dns_unrestrict" "移除 DNS 白名单限制"
    else
        msg_info "用户 ${C_BOLD}$username${C_RESET} 未设置 DNS 限制"
    fi
    return 0
}

# 查看用户的 DNS 限制状态
# 参数: $1=用户名
show_dns_status() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local uid
    uid=$(id -u "$username" 2>/dev/null)
    if [[ -z "$uid" ]]; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    local chain
    chain=$(_dns_chain_name "$username")

    draw_header "用户 $username 的 DNS 限制状态"

    draw_info_card "用户名:" "$username"
    draw_info_card "UID:" "$uid"

    # 检查自定义链是否存在
    if run_privileged iptables -L "$chain" -n &>/dev/null; then
        draw_info_card "限制状态:" "${C_BRED}已启用${C_RESET}" "$C_RESET"
        echo ""

        # 统计规则
        local total_rules
        total_rules=$(run_privileged iptables -L "$chain" -n 2>/dev/null | grep -cE '^(ACCEPT|DROP)')
        local accept_rules
        accept_rules=$(run_privileged iptables -L "$chain" -n 2>/dev/null | grep -c '^ACCEPT')
        local drop_rules
        drop_rules=$(run_privileged iptables -L "$chain" -n 2>/dev/null | grep -c '^DROP')

        draw_info_card "总规则数:" "$total_rules"
        draw_info_card "放行规则:" "$accept_rules"
        draw_info_card "阻止规则:" "$drop_rules"

        echo ""
        msg_info "详细规则列表:"
        draw_line 70

        # 显示规则（彩色）
        run_privileged iptables -L "$chain" -n --line-numbers 2>/dev/null | while IFS= read -r line; do
            if [[ "$line" =~ ^[0-9] ]]; then
                if [[ "$line" =~ ACCEPT ]]; then
                    echo -e "  ${C_BGREEN}$line${C_RESET}"
                elif [[ "$line" =~ DROP ]]; then
                    echo -e "  ${C_BRED}$line${C_RESET}"
                else
                    echo -e "  $line"
                fi
            else
                echo -e "  ${C_DIM}$line${C_RESET}"
            fi
        done
    else
        draw_info_card "限制状态:" "${C_BGREEN}未启用${C_RESET}" "$C_RESET"
        msg_info "该用户当前没有 DNS 访问限制"
    fi

    echo ""
}

# 对所有被管理的用户应用 DNS 限制
apply_all_dns_restrictions() {
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        msg_err "DNS 白名单文件不存在，请先执行 ${C_BOLD}init_dns_whitelist${C_RESET}"
        return 1
    fi

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_err "用户创建日志不存在"
        return 1
    fi

    draw_header "🌐 批量应用 DNS 限制"

    # 从创建日志中获取所有用户名（跳过表头，提取用户名列）
    local users=()
    while IFS=, read -r _ts uname action _rest; do
        # 跳过表头和非创建记录
        [[ "$_ts" == "timestamp" ]] && continue
        [[ "$action" != "create" ]] && continue
        # 跳过重复
        local already=false
        for u in "${users[@]}"; do
            [[ "$u" == "$uname" ]] && { already=true; break; }
        done
        $already && continue
        # 检查用户是否仍然存在
        id "$uname" &>/dev/null && users+=("$uname")
    done < "$USER_CREATION_LOG"

    if (( ${#users[@]} == 0 )); then
        msg_warn "没有找到任何被管理的用户"
        return 0
    fi

    msg_info "即将对 ${C_BOLD}${#users[@]}${C_RESET} 个用户应用 DNS 限制"
    echo ""

    local success=0 fail=0
    for uname in "${users[@]}"; do
        if apply_dns_restrictions "$uname"; then
            ((success+=1))
        else
            ((fail+=1))
        fi
        echo ""
    done

    draw_line 50
    msg_ok "批量应用完成: ${C_BGREEN}$success${C_RESET} 成功, ${C_BRED}$fail${C_RESET} 失败"
}

# 刷新 DNS 规则（重新解析域名 IP 并更新 iptables）
refresh_dns_rules() {
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        msg_err "DNS 白名单文件不存在，请先执行 ${C_BOLD}init_dns_whitelist${C_RESET}"
        return 1
    fi

    draw_header "🔄 刷新 DNS 白名单规则"
    msg_info "域名 IP 可能已变更，重新解析并更新规则..."
    echo ""

    # 查找所有 DNS_WL_ 开头的自定义链，提取用户名
    local chains
    chains=$(run_privileged iptables -S 2>/dev/null | grep -oP '(?<=-N DNS_WL_)\S+' | sort -u)

    if [[ -z "$chains" ]]; then
        msg_warn "当前没有任何用户启用了 DNS 限制"
        return 0
    fi

    local refreshed=0 failed=0
    for chain_suffix in $chains; do
        local username="$chain_suffix"
        if id "$username" &>/dev/null; then
            msg_step "刷新用户: ${C_BOLD}$username${C_RESET}"
            if apply_dns_restrictions "$username"; then
                ((refreshed+=1))
            else
                ((failed+=1))
            fi
        else
            msg_warn "用户 ${C_BOLD}$username${C_RESET} 不存在，跳过（链: DNS_WL_${chain_suffix}）"
        fi
        echo ""
    done

    draw_line 50
    msg_ok "刷新完成: ${C_BGREEN}$refreshed${C_RESET} 成功, ${C_BRED}$failed${C_RESET} 失败"
}
