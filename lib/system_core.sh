#!/bin/bash
# system_core.sh - 系统维护与监控模块 v0.2.1
# 提供系统信息、内存信息、日志分析、崩溃诊断、资源监控等功能

# ============================================================
# 系统信息显示
# ============================================================

# 显示系统信息
show_system_info() {
    draw_header "系统信息概览"

    local system_vendor product_name bios_version os_release kernel cmdline init_system boot_mode suspend_modes

    system_vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || echo "N/A")
    product_name=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "N/A")
    bios_version=$(cat /sys/devices/virtual/dmi/id/bios_version 2>/dev/null || echo "N/A")

    if [[ -f /etc/os-release ]]; then
        os_release=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release)
    else
        os_release="N/A"
    fi

    kernel=$(uname -r 2>/dev/null || echo "N/A")
    cmdline=$(cat /proc/cmdline 2>/dev/null || echo "N/A")
    init_system=$(ps -p 1 -o comm= 2>/dev/null || echo "N/A")

    if [[ -d /sys/firmware/efi ]]; then
        boot_mode="UEFI"
    else
        boot_mode="Legacy BIOS"
    fi

    suspend_modes=$(cat /sys/power/mem_sleep 2>/dev/null || echo "N/A")

    draw_info_card "系统:" "${system_vendor} ${product_name}" "$C_BOLD"
    draw_info_card "BIOS:" "$bios_version" "$C_BOLD"
    draw_info_card "操作系统:" "${os_release:-N/A}"
    draw_info_card "内核版本:" "$kernel"
    draw_info_card "启动参数:" "$cmdline"
    draw_info_card "Init系统:" "$init_system"
    draw_info_card "启动模式:" "$boot_mode"
    draw_info_card "休眠模式:" "${suspend_modes}"

    echo ""
}

# ============================================================
# 内存信息显示 (dmidecode)
# ============================================================

# 显示内存信息
show_memory_info() {
    draw_header "内存信息"

    # 检查 dmidecode 是否可用
    if ! command -v dmidecode &>/dev/null; then
        msg_warn "未检测到 dmidecode"
        if confirm_action "是否安装 dmidecode？" "Y"; then
            run_privileged apt-get update || return 1
            run_privileged apt-get install -y dmidecode || return 1
            msg_ok "dmidecode 安装完成"
        else
            msg_info "已取消安装"
            return 0
        fi
    fi

    msg_step "正在获取内存信息..."
    echo ""

    # 获取内存信息
    local mem_info
    mem_info=$(priv_exec dmidecode -t memory 2>/dev/null | grep -i -E "Size:|Locator:|Speed:|Manufacturer:|Type:|Part Number:" || echo "")

    if [[ -z "$mem_info" ]]; then
        msg_warn "无法获取内存信息，可能需要 root 权限"
        return 1
    fi

    # 解析并格式化显示
    local current_device=""
    local device_num=0
    local -A device_info

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*$ ]]; then
            # 空行表示新设备
            if [[ -n "$current_device" ]] && [[ -n "${device_info[size]:-}" ]]; then
                ((device_num++))
                echo -e "  ${C_BCYAN}━━━ 内存设备 #$device_num ━━━${C_RESET}"
                draw_info_card "大小:" "${device_info[size]:-N/A}" "$C_BOLD"
                draw_info_card "定位器:" "${device_info[locator]:-N/A}"
                draw_info_card "类型:" "${device_info[type]:-N/A}"
                draw_info_card "速度:" "${device_info[speed]:-N/A}"
                draw_info_card "制造商:" "${device_info[manufacturer]:-N/A}"
                draw_info_card "部件号:" "${device_info[part]:-N/A}"
                echo ""
            fi
            current_device=""
            device_info=()
        elif [[ "$line" =~ Size:[[:space:]]*(.*) ]]; then
            device_info[size]="${BASH_REMATCH[1]}"
            current_device="active"
        elif [[ "$line" =~ Locator:[[:space:]]*(.*) ]]; then
            device_info[locator]="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Speed:[[:space:]]*(.*) ]]; then
            device_info[speed]="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Manufacturer:[[:space:]]*(.*) ]]; then
            device_info[manufacturer]="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Type:[[:space:]]*(.*) ]]; then
            device_info[type]="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ "Part Number:"[[:space:]]*(.*) ]]; then
            device_info[part]="${BASH_REMATCH[1]}"
        fi
    done <<< "$mem_info"

    # 处理最后一个设备
    if [[ -n "$current_device" ]] && [[ -n "${device_info[size]:-}" ]]; then
        ((device_num++))
        echo -e "  ${C_BCYAN}━━━ 内存设备 #$device_num ━━━${C_RESET}"
        draw_info_card "大小:" "${device_info[size]:-N/A}" "$C_BOLD"
        draw_info_card "定位器:" "${device_info[locator]:-N/A}"
        draw_info_card "类型:" "${device_info[type]:-N/A}"
        draw_info_card "速度:" "${device_info[speed]:-N/A}"
        draw_info_card "制造商:" "${device_info[manufacturer]:-N/A}"
        draw_info_card "部件号:" "${device_info[part]:-N/A}"
        echo ""
    fi

    # 显示系统内存概览
    echo -e "  ${C_BYELLOW}━━━ 系统内存概览 ━━━${C_RESET}"
    local total_mem free_mem used_mem
    total_mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    used_mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')
    free_mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $4}')

    draw_info_card "总内存:" "$total_mem" "$C_BGREEN"
    draw_info_card "已使用:" "$used_mem"
    draw_info_card "可用:" "$free_mem"

    # 显示 Swap 信息
    local swap_total swap_used swap_free
    swap_total=$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')
    swap_used=$(free -h 2>/dev/null | awk '/^Swap:/{print $3}')
    swap_free=$(free -h 2>/dev/null | awk '/^Swap:/{print $4}')

    if [[ "$swap_total" != "0B" ]] && [[ -n "$swap_total" ]]; then
        draw_info_card "Swap总量:" "$swap_total"
        draw_info_card "Swap已用:" "$swap_used"
        draw_info_card "Swap可用:" "$swap_free"
    fi

    echo ""
}

# ============================================================
# 日志分析功能
# ============================================================

# 分析系统日志
analyze_system_logs() {
    draw_header "系统日志分析"

    local lines="${1:-100}"
    # shellcheck disable=SC2034
    local log_type="${2:-all}"  # 保留参数供未来扩展

    echo -e "  ${C_DIM}分析最近 $lines 条日志记录...${C_RESET}"
    echo ""

    # 分析 journalctl 日志
    if command -v journalctl &>/dev/null; then
        echo -e "  ${C_BCYAN}━━━ Journalctl 错误日志 ━━━${C_RESET}"
        journalctl -p err -n "$lines" --no-pager 2>/dev/null | tail -20 || msg_warn "无法读取 journalctl"
        echo ""
    fi

    # 分析 syslog
    if [[ -f /var/log/syslog ]]; then
        echo -e "  ${C_BCYAN}━━━ Syslog 错误记录 ━━━${C_RESET}"
        grep -i -E "(error|fail|critical|fatal)" /var/log/syslog 2>/dev/null | tail -20 || msg_warn "无法读取 syslog"
        echo ""
    fi

    # 分析 kern.log
    if [[ -f /var/log/kern.log ]]; then
        echo -e "  ${C_BCYAN}━━━ 内核日志错误 ━━━${C_RESET}"
        grep -i -E "(error|fail|critical|warn|hardware|mce)" /var/log/kern.log 2>/dev/null | tail -20 || msg_warn "无法读取 kern.log"
        echo ""
    fi

    # 分析 dmesg
    if command -v dmesg &>/dev/null; then
        echo -e "  ${C_BCYAN}━━━ 内核消息 (dmesg) ━━━${C_RESET}"
        dmesg -T 2>/dev/null | grep -i -E "(error|fail|warn|hardware|mce)" | tail -20 || msg_warn "无法读取 dmesg"
        echo ""
    fi

    # 显示日志统计
    echo -e "  ${C_BYELLOW}━━━ 日志统计 ━━━${C_RESET}"
    local syslog_err kern_err journ_err

    if [[ -f /var/log/syslog ]]; then
        syslog_err=$(grep -c -i -E "(error|fail|critical|fatal)" /var/log/syslog 2>/dev/null || echo "0")
        draw_info_card "Syslog 错误数:" "$syslog_err"
    fi

    if [[ -f /var/log/kern.log ]]; then
        kern_err=$(grep -c -i -E "(error|fail|critical|warn)" /var/log/kern.log 2>/dev/null || echo "0")
        draw_info_card "内核日志错误数:" "$kern_err"
    fi

    if command -v journalctl &>/dev/null; then
        journ_err=$(journalctl -p err --no-pager 2>/dev/null | wc -l || echo "0")
        draw_info_card "Journalctl 错误数:" "$journ_err"
    fi

    echo ""
}

# 分析崩溃原因
analyze_crash_causes() {
    draw_header "崩溃原因分析"

    local found_issues=false

    # 1. 检查系统崩溃记录
    echo -e "  ${C_BCYAN}━━━ 系统崩溃记录 ━━━${C_RESET}"
    if [[ -f /var/crash ]]; then
        if [[ -d /var/crash ]] && [[ -n "$(find /var/crash -maxdepth 1 -mindepth 1 2>/dev/null)" ]]; then
            msg_warn "发现崩溃转储文件:"
            find /var/crash -maxdepth 1 -mindepth 1 -printf '%M %u %g %s %T+ %p\n' 2>/dev/null | tail -10
            found_issues=true
        else
            msg_ok "无崩溃转储文件"
        fi
    else
        msg_info "崩溃转储目录不存在"
    fi
    echo ""

    # 2. 检查内核恐慌记录
    echo -e "  ${C_BCYAN}━━━ 内核恐慌 (Kernel Panic) ━━━${C_RESET}"
    local panic_count
    if command -v journalctl &>/dev/null; then
        panic_count=$(journalctl -k --no-pager 2>/dev/null | grep -c -i "kernel panic" || echo "0")
        if [[ "$panic_count" -gt 0 ]]; then
            msg_warn "发现 $panic_count 次内核恐慌记录"
            journalctl -k --no-pager 2>/dev/null | grep -i "kernel panic" | tail -5
            found_issues=true
        else
            msg_ok "无内核恐慌记录"
        fi
    fi
    echo ""

    # 3. 检查硬件错误 (MCE - Machine Check Exception)
    echo -e "  ${C_BCYAN}━━━ 硬件错误 (MCE) ━━━${C_RESET}"
    local mce_count
    if [[ -f /var/log/mcelog ]]; then
        mce_count=$(wc -l < /var/log/mcelog 2>/dev/null || echo "0")
        if [[ "$mce_count" -gt 0 ]]; then
            msg_warn "发现硬件错误记录:"
            tail -20 /var/log/mcelog
            found_issues=true
        else
            msg_ok "无 MCE 硬件错误"
        fi
    else
        # 检查 dmesg 中的 MCE
        if command -v dmesg &>/dev/null; then
            mce_count=$(dmesg 2>/dev/null | grep -c -i "mce\|hardware error" || echo "0")
            if [[ "$mce_count" -gt 0 ]]; then
                msg_warn "发现硬件错误记录:"
                dmesg 2>/dev/null | grep -i "mce\|hardware error" | tail -10
                found_issues=true
            else
                msg_ok "无硬件错误记录"
            fi
        fi
    fi
    echo ""

    # 4. 检查 OOM (Out of Memory) 杀手记录
    echo -e "  ${C_BCYAN}━━━ OOM 杀手记录 ━━━${C_RESET}"
    local oom_count
    if command -v journalctl &>/dev/null; then
        oom_count=$(journalctl --no-pager 2>/dev/null | grep -c "Out of memory\|oom-killer\|Killed process" || echo "0")
        if [[ "$oom_count" -gt 0 ]]; then
            msg_warn "发现 $oom_count 次 OOM 事件:"
            journalctl --no-pager 2>/dev/null | grep -E "Out of memory|oom-killer|Killed process" | tail -10
            found_issues=true
        else
            msg_ok "无 OOM 记录"
        fi
    fi
    echo ""

    # 5. 检查系统重启记录
    echo -e "  ${C_BCYAN}━━━ 系统重启记录 ━━━${C_RESET}"
    if command -v last &>/dev/null; then
        last -x reboot 2>/dev/null | head -10 || msg_warn "无法读取重启记录"
    fi
    echo ""

    # 6. 检查服务失败
    echo -e "  ${C_BCYAN}━━━ 失败的服务 ━━━${C_RESET}"
    if command -v systemctl &>/dev/null; then
        local failed_services
        failed_services=$(systemctl --failed --no-pager 2>/dev/null | grep -E "●|failed" | head -10)
        if [[ -n "$failed_services" ]]; then
            msg_warn "发现失败的服务:"
            echo "$failed_services"
            found_issues=true
        else
            msg_ok "无失败的服务"
        fi
    fi
    echo ""

    # 7. 检查磁盘错误
    echo -e "  ${C_BCYAN}━━━ 磁盘错误检查 ━━━${C_RESET}"
    if [[ -f /var/log/kern.log ]]; then
        local disk_err
        disk_err=$(grep -i -E "(I/O error|disk error|ata.*error|sda.*error)" /var/log/kern.log 2>/dev/null | tail -10)
        if [[ -n "$disk_err" ]]; then
            msg_warn "发现磁盘错误:"
            echo "$disk_err"
            found_issues=true
        else
            msg_ok "无磁盘错误记录"
        fi
    fi
    echo ""

    # 总结
    echo -e "  ${C_BYELLOW}━━━ 分析总结 ━━━${C_RESET}"
    if $found_issues; then
        msg_warn "发现潜在问题，请检查上述日志"
    else
        msg_ok "未发现明显的系统崩溃问题"
    fi

    echo ""
}

# ============================================================
# 资源监控
# ============================================================

# 配置 systemd-oomd 防护
configure_oom_protection() {
    draw_header "OOM 防护配置"

    if ! systemctl list-unit-files systemd-oomd.service &>/dev/null; then
        msg_err "systemd-oomd 未安装或不可用"
        return 1
    fi

    msg_info "将启用 systemd-oomd 并写入推荐配置"
    msg_info "默认内存压力阈值: 60% / 30s"
    msg_info "Swap 使用阈值: 90%"

    if ! confirm_action "是否继续配置？"; then
        msg_info "操作已取消"
        return 0
    fi

    local conf_dir="/etc/systemd/oomd.conf.d"
    local conf_file="${conf_dir}/90-user-manager.conf"
    local dropin_dir="/etc/systemd/system/systemd-oomd.service.d"
    local dropin_file="${dropin_dir}/90-user-manager.conf"
    local tmp_conf tmp_dropin

    tmp_conf=$(mktemp) || {
        msg_err "无法创建临时文件"
        return 1
    }
    cat <<'EOF' > "$tmp_conf"
[OOM]
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=30s
SwapUsedLimit=90%
EOF
    
    tmp_dropin=$(mktemp) || {
        rm -f "$tmp_conf"
        msg_err "无法创建临时文件"
        return 1
    }
    cat <<'EOF' > "$tmp_dropin"
[Service]
OOMScoreAdjust=-900
EOF

    run_privileged mkdir -p "$conf_dir" || { rm -f "$tmp_conf" "$tmp_dropin"; return 1; }
    run_privileged mkdir -p "$dropin_dir" || { rm -f "$tmp_conf" "$tmp_dropin"; return 1; }
    run_privileged mv "$tmp_conf" "$conf_file" || { rm -f "$tmp_conf" "$tmp_dropin"; return 1; }
    run_privileged mv "$tmp_dropin" "$dropin_file" || { rm -f "$tmp_conf" "$tmp_dropin"; return 1; }

    priv_systemctl daemon-reload || return 1
    priv_systemctl enable --now systemd-oomd.service || return 1
    priv_systemctl restart systemd-oomd.service || return 1

    msg_ok "systemd-oomd 已启用并生效"
    msg_info "配置文件: ${conf_file}"
    msg_info "服务保护: ${dropin_file}"
    echo ""
}

# 启动 htop 资源监控
launch_htop_monitor() {
    draw_header "htop 资源监控"

    if ! command -v htop &>/dev/null; then
        msg_warn "未检测到 htop"
        if confirm_action "是否安装 htop？" "Y"; then
            run_privileged apt-get update || return 1
            run_privileged apt-get install -y htop || return 1
            msg_ok "htop 安装完成"
        else
            msg_info "已取消安装"
            return 0
        fi
    fi

    msg_info "退出 htop 后将返回菜单"
    htop
    echo ""
}

# 启动 btop 资源监控
launch_btop_monitor() {
    draw_header "btop 资源监控"

    if ! command -v btop &>/dev/null; then
        msg_warn "未检测到 btop"
        if confirm_action "是否安装 btop？" "Y"; then
            run_privileged apt-get update || return 1
            run_privileged apt-get install -y btop || return 1
            msg_ok "btop 安装完成"
        else
            msg_info "已取消安装"
            return 0
        fi
    fi

    msg_info "退出 btop 后将返回菜单 (按 q 退出)"
    echo ""

    # btop 可能需要终端重置
    btop

    # 清理终端
    clear
    echo ""
}

# ============================================================
# 硬件健康检查
# ============================================================

# 检查硬件健康状态
# ============================================================
# check_hardware_health - 硬件健康检查
# ============================================================
# 无参数函数，检查 CPU 温度、风扇、电池、磁盘 SMART、内存错误
# Returns: 0 始终成功
# ============================================================
check_hardware_health() {
    draw_header "硬件健康检查"

    local issues=0

    # CPU 温度检查
    echo -e "  ${C_BCYAN}━━━ CPU 温度 ━━━${C_RESET}"
    if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -E "(Core|Package|temp|°C)" | head -10 || msg_info "无法读取传感器数据"
    else
        msg_warn "lm-sensors 未安装"
        if [[ -d /sys/class/thermal ]]; then
            for zone in /sys/class/thermal/thermal_zone*; do
                if [[ -f "$zone/temp" ]]; then
                    local temp type
                    temp=$(cat "$zone/temp" 2>/dev/null)
                    type=$(cat "$zone/type" 2>/dev/null || echo "Unknown")
                    if [[ "$temp" =~ ^[0-9]+$ ]]; then
                        local temp_c=$((temp / 1000))
                        draw_info_card "$type:" "${temp_c}°C"
                    fi
                fi
            done
        fi
    fi
    echo ""

    # 风扇状态
    echo -e "  ${C_BCYAN}━━━ 风扇状态 ━━━${C_RESET}"
    if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -i fan | head -5 || msg_info "无风扇信息"
    else
        msg_info "需要 lm-sensors 读取风扇状态"
    fi
    echo ""

    # 电池状态 (笔记本)
    echo -e "  ${C_BCYAN}━━━ 电池状态 ━━━${C_RESET}"
    if [[ -d /sys/class/power_supply ]]; then
        for bat in /sys/class/power_supply/BAT*; do
            if [[ -d "$bat" ]]; then
                local capacity status
                capacity=$(cat "$bat/capacity" 2>/dev/null || echo "N/A")
                status=$(cat "$bat/status" 2>/dev/null || echo "N/A")
                draw_info_card "电池:" "$capacity% ($status)"
            fi
        done
    else
        msg_info "无电池检测"
    fi
    echo ""

    # 磁盘健康 (SMART)
    echo -e "  ${C_BCYAN}━━━ 磁盘健康 (SMART) ━━━${C_RESET}"
    if command -v smartctl &>/dev/null; then
        local disks
        disks=$(lsblk -d -o NAME 2>/dev/null | grep -E "^sd|^nvme|^vd" | head -5)
        for disk in $disks; do
            local smart_status
            smart_status=$(run_privileged smartctl -H "/dev/$disk" 2>/dev/null | grep -E "SMART|PASSED|FAILED" | head -1)
            if [[ -n "$smart_status" ]]; then
                draw_info_card "/dev/$disk:" "$smart_status"
            fi
        done
    else
        msg_info "smartmontools 未安装，跳过 SMART 检查"
    fi
    echo ""

    # 内存错误检查
    echo -e "  ${C_BCYAN}━━━ 内存错误 ━━━${C_RESET}"
    if [[ -f /sys/devices/system/edac/mc/mc0/ce_count ]]; then
        local ce_count ue_count
        ce_count=$(cat /sys/devices/system/edac/mc/mc0/ce_count 2>/dev/null || echo "0")
        ue_count=$(cat /sys/devices/system/edac/mc/mc0/ue_count 2>/dev/null || echo "0")
        draw_info_card "可纠正错误 (CE):" "$ce_count"
        draw_info_card "不可纠正错误 (UE):" "$ue_count"
        if [[ "$ue_count" -gt 0 ]]; then
            msg_err "发现内存硬件错误！"
            ((issues++))
        fi
    else
        msg_info "无 EDAC 内存错误计数"
    fi
    echo ""

    # 总结
    echo -e "  ${C_BYELLOW}━━━ 检查总结 ━━━${C_RESET}"
    if [[ $issues -gt 0 ]]; then
        msg_warn "发现 $issues 个硬件问题，请检查详细日志"
    else
        msg_ok "硬件健康状态正常"
    fi

    echo ""
}