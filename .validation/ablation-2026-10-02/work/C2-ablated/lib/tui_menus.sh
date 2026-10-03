#!/bin/bash
# tui_menus.sh - TUI 菜单数据定义与通用渲染引擎
# 将 tui_manager.sh 中 18+ 重复的 draw/handler 函数替换为数据驱动方式

# ============================================================
# 菜单数据定义
# ============================================================

# 声明所有关联数组（set -u 必须先 declare 再赋值）
declare -A _TUI_MENU_TITLE
declare -A _TUI_MENU_ITEMS
declare -A _TUI_MENU_WIDTH
declare -A _TUI_MENU_ROW
declare -A _TUI_MENU_STATUS_LEFT
declare -A _TUI_MENU_STATUS_RIGHT

# 主菜单
_TUI_MENU_TITLE["main"]="用户与系统管理器 TUI"
_TUI_MENU_ITEMS["main"]="用户管理|磁盘与配额管理|网络与安全管理|备份与恢复|报告与统计|系统维护|审计与日志|实时监控|查看日志|退出"
_TUI_MENU_WIDTH["main"]=50
_TUI_MENU_ROW["main"]=4
_TUI_MENU_STATUS_LEFT["main"]="托管用户"
_TUI_MENU_STATUS_RIGHT["main"]="运行时间"

# 用户管理
_TUI_MENU_TITLE["user"]="用户管理"
_TUI_MENU_ITEMS["user"]="创建/更新用户|修改用户密码|删除用户账户|重命名用户账户|暂停/恢复用户|调整用户配额|配置资源限制|查看托管用户|用户组管理|权限管理|返回主菜单"
_TUI_MENU_WIDTH["user"]=50
_TUI_MENU_STATUS_LEFT["user"]="用户管理"
_TUI_MENU_STATUS_RIGHT["user"]="↑/↓ 导航  Enter 选择  q 返回"

# 用户组管理
_TUI_MENU_TITLE["user_group"]="用户组管理"
_TUI_MENU_ITEMS["user_group"]="将用户加入用户组|将用户移出用户组|查看用户所属组|查看用户组成员|创建用户组|删除用户组|返回上级"
_TUI_MENU_WIDTH["user_group"]=52
_TUI_MENU_STATUS_LEFT["user_group"]="用户组管理"
_TUI_MENU_STATUS_RIGHT["user_group"]="↑/↓ 导航  Enter 选择  q 返回"

# 权限管理
_TUI_MENU_TITLE["permission"]="权限管理"
_TUI_MENU_ITEMS["permission"]="查看用户权限详情|设置主目录权限|设置主目录属组|授予管理员权限|移除管理员权限|返回上级"
_TUI_MENU_WIDTH["permission"]=52
_TUI_MENU_STATUS_LEFT["permission"]="权限管理"
_TUI_MENU_STATUS_RIGHT["permission"]="↑/↓ 导航  Enter 选择  q 返回"

# 磁盘与配额管理
_TUI_MENU_TITLE["disk"]="磁盘与配额管理"
_TUI_MENU_ITEMS["disk"]="数据盘概览|调整用户配额|查看用户配额|配置资源限制|查看资源使用|返回主菜单"
_TUI_MENU_WIDTH["disk"]=50
_TUI_MENU_STATUS_LEFT["disk"]="磁盘与配额管理"
_TUI_MENU_STATUS_RIGHT["disk"]="↑/↓ 导航  Enter 选择  q 返回"

# 网络与安全管理
_TUI_MENU_TITLE["network"]="网络与安全管理"
_TUI_MENU_ITEMS["network"]="防火墙规则|DNS 访问控制|符号链接与共享|SSH 与 Fail2ban|网络栈诊断|SMB 管理|返回主菜单"
_TUI_MENU_WIDTH["network"]=50
_TUI_MENU_STATUS_LEFT["network"]="网络与安全管理"
_TUI_MENU_STATUS_RIGHT["network"]="↑/↓ 导航  Enter 选择  q 返回"

# SMB 管理
_TUI_MENU_TITLE["smb"]="SMB 管理"
_TUI_MENU_ITEMS["smb"]="SMB 服务状态|列出 SMB 用户|查看用户 SMB 状态|设置 SMB 密码|禁用 SMB 用户|启用 SMB 用户|移除 SMB 用户|列出 SMB 共享|新增 SMB 共享|移除 SMB 共享|主配置 include 托管配置|返回上级"
_TUI_MENU_WIDTH["smb"]=50
_TUI_MENU_STATUS_LEFT["smb"]="SMB 管理"
_TUI_MENU_STATUS_RIGHT["smb"]="↑/↓ 导航  Enter 选择  q 返回"

# 防火墙规则
_TUI_MENU_TITLE["firewall"]="防火墙规则"
_TUI_MENU_ITEMS["firewall"]="添加端口规则|删除端口规则|查看全部规则|查看用户规则|端口使用概览|添加端口范围|应用服务模板|初始化 UFW|返回上级"
_TUI_MENU_WIDTH["firewall"]=50
_TUI_MENU_STATUS_LEFT["firewall"]="防火墙规则"
_TUI_MENU_STATUS_RIGHT["firewall"]="↑/↓ 导航  Enter 选择  q 返回"

# DNS 访问控制
_TUI_MENU_TITLE["dns"]="DNS 访问控制"
_TUI_MENU_ITEMS["dns"]="查看白名单|添加域名|移除域名|启用 DNS 限制|移除 DNS 限制|查看用户状态|批量应用限制|刷新 DNS 规则|返回上级"
_TUI_MENU_WIDTH["dns"]=50
_TUI_MENU_STATUS_LEFT["dns"]="DNS 访问控制"
_TUI_MENU_STATUS_RIGHT["dns"]="↑/↓ 导航  Enter 选择  q 返回"

# 符号链接与共享
_TUI_MENU_TITLE["symlink"]="符号链接与共享"
_TUI_MENU_ITEMS["symlink"]="创建用户符号链接|创建跨盘链接|查看用户符号链接|删除用户符号链接|清理断链|创建共享链接|为所有用户创建共享链接|符号链接概览|返回上级"
_TUI_MENU_WIDTH["symlink"]=52
_TUI_MENU_STATUS_LEFT["symlink"]="符号链接与共享"
_TUI_MENU_STATUS_RIGHT["symlink"]="↑/↓ 导航  Enter 选择  q 返回"

# SSH 与 Fail2ban
_TUI_MENU_TITLE["ssh_fail2ban"]="SSH 与 Fail2ban"
_TUI_MENU_ITEMS["ssh_fail2ban"]="SSH 安全基线摘要|最近认证失败|Fail2ban 状态|配置 sshd jail|列出全部 jails|返回上级"
_TUI_MENU_WIDTH["ssh_fail2ban"]=52
_TUI_MENU_STATUS_LEFT["ssh_fail2ban"]="SSH 与 Fail2ban"
_TUI_MENU_STATUS_RIGHT["ssh_fail2ban"]="↑/↓ 导航  Enter 选择  q 返回"

# 备份与恢复
_TUI_MENU_TITLE["backup"]="备份与恢复"
_TUI_MENU_ITEMS["backup"]="手动备份用户|恢复用户数据|查看备份状态|列出备份用户|更多备份选项|返回主菜单"
_TUI_MENU_WIDTH["backup"]=50
_TUI_MENU_STATUS_LEFT["backup"]="备份与恢复"
_TUI_MENU_STATUS_RIGHT["backup"]="↑/↓ 导航  Enter 选择  q 返回"

# 详细备份选项
_TUI_MENU_TITLE["backup_advanced"]="详细备份选项"
_TUI_MENU_ITEMS["backup_advanced"]="设置定时备份|取消定时备份|查看备份计划|备份所有用户|并行备份所有用户|查看批次记录|从批次恢复|返回上级"
_TUI_MENU_WIDTH["backup_advanced"]=52
_TUI_MENU_STATUS_LEFT["backup_advanced"]="详细备份选项"
_TUI_MENU_STATUS_RIGHT["backup_advanced"]="↑/↓ 导航  Enter 选择  q 返回"

# 报告与统计
_TUI_MENU_TITLE["report_stats"]="报告与统计"
_TUI_MENU_ITEMS["report_stats"]="生成系统 HTML 报告|用户统计报告|作业统计|密码轮换|更多报告选项|返回主菜单"
_TUI_MENU_WIDTH["report_stats"]=50
_TUI_MENU_STATUS_LEFT["report_stats"]="报告与统计"
_TUI_MENU_STATUS_RIGHT["report_stats"]="↑/↓ 导航  Enter 选择  q 返回"

# 作业统计
_TUI_MENU_TITLE["job_stats"]="作业统计"
_TUI_MENU_ITEMS["job_stats"]="收集全部用户统计|查看周统计|查看月统计|查看当前进程|返回上级"
_TUI_MENU_WIDTH["job_stats"]=50
_TUI_MENU_STATUS_LEFT["job_stats"]="作业统计"
_TUI_MENU_STATUS_RIGHT["job_stats"]="↑/↓ 导航  Enter 选择  q 返回"

# 密码轮换
_TUI_MENU_TITLE["password_rotation"]="密码轮换"
_TUI_MENU_ITEMS["password_rotation"]="查看轮换状态|设置定时轮换|取消定时轮换|立即执行轮换|返回上级"
_TUI_MENU_WIDTH["password_rotation"]=50
_TUI_MENU_STATUS_LEFT["password_rotation"]="密码轮换"
_TUI_MENU_STATUS_RIGHT["password_rotation"]="↑/↓ 导航  Enter 选择  q 返回"

# 详细报告
_TUI_MENU_TITLE["report"]="详细报告"
_TUI_MENU_ITEMS["report"]="生成系统 HTML 报告|用户统计报告|配额使用报告|资源限制报告|实时资源使用|单用户资源详情|查看操作日志|查询用户历史|按日期查询|操作趋势分析|异常检测分析|日志摘要报告|导出完整报告|导出用户 CSV|生成并发送个人报告|为所有用户发送报告|设置每周自动报告|取消每周自动报告|查看自动报告日志|查看审计日志|审计统计分析|返回上级"
_TUI_MENU_WIDTH["report"]=56
_TUI_MENU_ROW["report"]=2
_TUI_MENU_STATUS_LEFT["report"]="详细报告"
_TUI_MENU_STATUS_RIGHT["report"]="↑/↓ 导航  Enter 选择  q 返回"

# 系统维护
_TUI_MENU_TITLE["system"]="系统维护"
_TUI_MENU_ITEMS["system"]="系统信息概览|内存信息|硬件健康检查|系统日志分析|Ubuntu APT/重启维护|网络栈诊断|Systemd Timers|更多系统选项|虚拟机与显卡管理|返回主菜单"
_TUI_MENU_WIDTH["system"]=52
_TUI_MENU_STATUS_LEFT["system"]="系统维护"
_TUI_MENU_STATUS_RIGHT["system"]="↑/↓ 导航  Enter 选择  q 返回"

# 详细系统选项
_TUI_MENU_TITLE["system_details"]="详细系统选项"
_TUI_MENU_ITEMS["system_details"]="CPU 详细信息|内存详细信息|磁盘信息|网络硬件信息|完整硬件检测|查看 Boot 日志|列出失败服务|诊断指定服务|启动错误对比|启动 btop 监控|启动 htop 监控|崩溃原因分析|配置 OOM 防护|显示网络信息|返回上级"
_TUI_MENU_WIDTH["system_details"]=54
_TUI_MENU_ROW["system_details"]=2
_TUI_MENU_STATUS_LEFT["system_details"]="详细系统选项"
_TUI_MENU_STATUS_RIGHT["system_details"]="↑/↓ 导航  Enter 选择  q 返回"

# Systemd Timers
_TUI_MENU_TITLE["systemd_timer"]="Systemd Timers"
_TUI_MENU_ITEMS["systemd_timer"]="列出 timers|安装 timer profile|查看 timer 日志|删除 timer|返回上级"
_TUI_MENU_WIDTH["systemd_timer"]=50
_TUI_MENU_STATUS_LEFT["systemd_timer"]="Systemd Timers"
_TUI_MENU_STATUS_RIGHT["systemd_timer"]="↑/↓ 导航  Enter 选择  q 返回"

# 虚拟机与显卡管理
_TUI_MENU_TITLE["compute"]="虚拟机与显卡管理"
_TUI_MENU_ITEMS["compute"]="列出虚拟机|查看虚拟机状态|显卡状态|列出显卡设备|GPU 进程|返回上级"
_TUI_MENU_WIDTH["compute"]=52
_TUI_MENU_STATUS_LEFT["compute"]="虚拟机与显卡管理"
_TUI_MENU_STATUS_RIGHT["compute"]="↑/↓ 导航  Enter 选择  q 返回"

# 审计与日志
_TUI_MENU_TITLE["audit"]="审计与日志"
_TUI_MENU_ITEMS["audit"]="查看审计日志|审计统计分析|查看 Journald 审计|更多审计选项|返回主菜单"
_TUI_MENU_WIDTH["audit"]=50
_TUI_MENU_STATUS_LEFT["audit"]="审计与日志"
_TUI_MENU_STATUS_RIGHT["audit"]="↑/↓ 导航  Enter 选择  q 返回"

# 详细审计选项
_TUI_MENU_TITLE["audit_advanced"]="详细审计选项"
_TUI_MENU_ITEMS["audit_advanced"]="查询审计日志|审计统计分析|手动日志轮转|查看 Journald 审计|返回上级"
_TUI_MENU_WIDTH["audit_advanced"]=50
_TUI_MENU_STATUS_LEFT["audit_advanced"]="详细审计选项"
_TUI_MENU_STATUS_RIGHT["audit_advanced"]="↑/↓ 导航  Enter 选择  q 返回"

# ============================================================
# 通用菜单渲染引擎（现代暗色主题）
# ============================================================

_tui_menu_number_for_index() {
    local index="$1" item_count="$2"
    if ((index == item_count - 1)); then
        printf '0'
    else
        printf '%d' "$((index + 1))"
    fi
}

# 菜单图标映射
_tui_menu_icon() {
    local menu_id="${1:-main}"
    case "$menu_id" in
    main) echo "⚙" ;;
    user) echo "👤" ;;
    user_group) echo "👥" ;;
    permission) echo "🔐" ;;
    disk) echo "💾" ;;
    network) echo "🌐" ;;
    smb) echo "🖧" ;;
    firewall) echo "🛡" ;;
    dns) echo "🌍" ;;
    symlink) echo "🔗" ;;
    ssh_fail2ban) echo "🔐" ;;
    backup) echo "📦" ;;
    backup_advanced) echo "📦" ;;
    report_stats) echo "📊" ;;
    report) echo "📋" ;;
    job_stats) echo "📈" ;;
    password_rotation) echo "🔑" ;;
    system) echo "🖥" ;;
    system_details) echo "🔧" ;;
    systemd_timer) echo "⏰" ;;
    compute) echo "🧮" ;;
    audit) echo "📝" ;;
    audit_advanced) echo "🔍" ;;
    *) echo "▸" ;;
    esac
}

# 输出固定数量的边框字符；调用方已保证数量非负。
_tui_menu_rule() {
    local rl_count="$1" rl_char="$2" rl_i
    for ((rl_i = 0; rl_i < rl_count; rl_i++)); do
        printf '%s' "$rl_char"
    done
}

# 绘制现代标题栏。此函数只由正常布局调用（至少 3 列、7 行）。
_tui_draw_modern_header() {
    local rl_title="$1" rl_menu_id="${2:-main}"
    local rl_cols="${TUI_COLS:-0}" rl_inner rl_icon rl_text
    ((rl_cols >= 3)) || return 0

    rl_inner=$((rl_cols - 2))
    rl_icon=$(_tui_menu_icon "$rl_menu_id")
    rl_text=" ${rl_icon}  ${rl_title}"

    tui_move 0 0
    tui_fg "$TUI_COLOR_BORDER"
    printf '╔'
    _tui_menu_rule "$rl_inner" '═'
    printf '╗'
    tui_reset

    tui_move 1 0
    tui_fg "$TUI_COLOR_BG"
    tui_bg "$TUI_COLOR_ACCENT"
    tui_pad_display "$(tui_truncate_display "$rl_text" "$rl_cols")" "$rl_cols"
    tui_reset

    tui_move 2 0
    tui_fg "$TUI_COLOR_BORDER"
    printf '╚'
    _tui_menu_rule "$rl_inner" '═'
    printf '╝'
    tui_reset
}

# 绘制现代风格状态栏，并在窄列数中按显示宽度裁剪两端内容。
_tui_draw_modern_statusbar() {
    local rl_left="$1" rl_right="$2" rl_right_suffix="${3:-}"
    local rl_cols="${TUI_COLS:-0}" rl_row="${TUI_LINES:-0}"
    local rl_left_width rl_right_width rl_suffix_width rl_left_room rl_right_room
    local rl_separator_col rl_right_prefix rl_right_render
    ((rl_cols > 0 && rl_row > 0)) || return 0
    rl_row=$((rl_row - 1))

    tui_move "$rl_row" 0
    tui_bg "$TUI_COLOR_SURFACE"
    tui_fg "$TUI_COLOR_MUTED"
    printf '%*s' "$rl_cols" ''

    rl_left_width=$(tui_display_width "$rl_left")
    rl_right_width=$(tui_display_width "$rl_right")
    rl_suffix_width=$(tui_display_width "$rl_right_suffix")

    # 有足够空间时绝不截断：宽终端保留状态和分页范围的完整文本。
    if ((rl_left_width + rl_right_width + 3 < rl_cols)); then
        tui_move "$rl_row" 1
        printf '%s' "$rl_left"
        rl_separator_col=$((rl_left_width + 2))
        tui_move "$rl_row" "$rl_separator_col"
        tui_fg "$TUI_COLOR_BORDER"
        printf '│'
        tui_fg "$TUI_COLOR_MUTED"
        tui_move "$rl_row" $((rl_cols - rl_right_width - 1))
        printf '%s' "$rl_right"
        tui_reset
        return 0
    fi

    # 窄终端时右端优先。分页后缀从不因左端导航文本而被丢弃。
    rl_right_room=$((rl_cols - 1))
    ((rl_right_room < 0)) && rl_right_room=0
    if ((rl_right_width > rl_right_room)); then
        if ((rl_suffix_width <= rl_right_room)); then
            rl_right_prefix="${rl_right%"$rl_right_suffix"}"
            rl_right_prefix=$(tui_truncate_display "$rl_right_prefix" "$((rl_right_room - rl_suffix_width))")
            rl_right_render="${rl_right_prefix}${rl_right_suffix}"
        else
            rl_right_render=$(tui_truncate_display "$rl_right_suffix" "$rl_right_room")
        fi
    else
        rl_right_render="$rl_right"
    fi
    rl_right_width=$(tui_display_width "$rl_right_render")
    rl_left_room=$((rl_cols - rl_right_width - 2))

    if ((rl_left_room > 0)); then
        rl_left=$(tui_truncate_display "$rl_left" "$rl_left_room")
        rl_left_width=$(tui_display_width "$rl_left")
        tui_move "$rl_row" 1
        printf '%s' "$rl_left"
        rl_separator_col=$((rl_left_width + 1))
        if ((rl_separator_col < rl_cols - rl_right_width)); then
            tui_move "$rl_row" "$rl_separator_col"
            tui_fg "$TUI_COLOR_BORDER"
            printf '│'
        fi
    fi
    tui_fg "$TUI_COLOR_MUTED"
    tui_move "$rl_row" $((rl_cols - rl_right_width))
    printf '%s' "$rl_right_render"
    tui_reset
}

# 根据菜单 ID 绘制标准菜单；状态和 viewport 由 tui_core.sh 维护。
# 用法: _tui_draw_menu "main"
_tui_draw_menu() {
    local rl_menu_id="${1:-main}"
    local rl_title="${_TUI_MENU_TITLE[$rl_menu_id]:-未定义菜单}"
    local rl_items_str="${_TUI_MENU_ITEMS[$rl_menu_id]:-}"
    local rl_width="${_TUI_MENU_WIDTH[$rl_menu_id]:-50}"
    local rl_requested_row="${_TUI_MENU_ROW[$rl_menu_id]:-4}"
    local rl_status_left="${_TUI_MENU_STATUS_LEFT[$rl_menu_id]:-}"
    local rl_status_right="${_TUI_MENU_STATUS_RIGHT[$rl_menu_id]:-}"
    local rl_cols="${TUI_COLS:-0}" rl_lines="${TUI_LINES:-0}"
    local -a rl_items=()
    local IFS='|'

    # 同一 ID 的 redraw 不得重建 core 菜单状态；invalidate 会清空 active ID。
    if [[ "${TUI_ACTIVE_MENU_ID:-}" != "$rl_menu_id" ]] || ((${#TUI_MENU_ITEMS[@]} == 0)); then
        read -ra rl_items <<<"$rl_items_str"
        tui_menu_create "$rl_title" "${rl_items[@]}"
        TUI_ACTIVE_MENU_ID="$rl_menu_id"
    fi

    local rl_total=${#TUI_MENU_ITEMS[@]}
    ((rl_total > 0 && rl_cols > 0 && rl_lines > 0)) || return 0

    local rl_first_row rl_reserved_bottom
    # 历史菜单可要求 row=2；正常布局中的首项从第 4 行起。
    rl_first_row="$rl_requested_row"
    ((rl_first_row < 4)) && rl_first_row=4

    # 正常布局需要标题、两条容器边框和状态栏均有独立空间。
    local rl_normal=false
    if ((rl_lines >= 7 && rl_cols >= 8 && rl_first_row + 2 < rl_lines)); then
        rl_normal=true
    fi

    if [[ "$rl_normal" == true ]]; then
        rl_reserved_bottom=2 # 容器底边 + 最后一行状态栏
    else
        rl_first_row=0
        rl_reserved_bottom=0
    fi
    tui_menu_update_viewport "$rl_first_row" "$rl_reserved_bottom"

    local rl_start="${TUI_MENU_SCROLL_OFFSET:-0}"
    local rl_end="${TUI_MENU_VIEWPORT_END:-$rl_total}"
    ((rl_start < 0)) && rl_start=0
    ((rl_end < rl_start)) && rl_end=rl_start
    ((rl_end > rl_total)) && rl_end=rl_total

    local rl_index rl_item rl_item_num rl_label_width rl_label rl_content_width rl_line
    if [[ "$rl_normal" == true ]]; then
        ((rl_width < 3)) && rl_width=3
        ((rl_width > rl_cols)) && rl_width=$rl_cols
        local rl_left=$(((rl_cols - rl_width) / 2))
        ((rl_left < 0)) && rl_left=0
        local rl_inner=$((rl_width - 2))
        rl_content_width=$rl_inner
        rl_label_width=$((rl_inner - 6))
        ((rl_label_width < 0)) && rl_label_width=0

        _tui_draw_modern_header "$rl_title" "$rl_menu_id"
        tui_move 3 "$rl_left"
        tui_fg "$TUI_COLOR_BORDER"
        printf '┌'
        _tui_menu_rule "$rl_inner" '─'
        printf '┐'
        tui_reset

        for ((rl_index = rl_start; rl_index < rl_end; rl_index++)); do
            rl_item="${TUI_MENU_ITEMS[$rl_index]}"
            rl_item_num=$(_tui_menu_number_for_index "$rl_index" "$rl_total")
            rl_label=$(tui_pad_display "$(tui_truncate_display "$rl_item" "$rl_label_width")" "$rl_label_width")
            rl_line=$(tui_pad_display "  $(printf '%2s' "$rl_item_num"). ${rl_label}" "$rl_content_width")
            tui_move $((rl_first_row + rl_index - rl_start)) "$rl_left"
            tui_fg "$TUI_COLOR_BORDER"
            printf '│'
            if ((rl_index == TUI_MENU_INDEX)); then
                tui_reverse
                tui_fg "$TUI_COLOR_HIGHLIGHT"
            elif ((rl_index == rl_total - 1)); then
                tui_fg "$TUI_COLOR_MUTED"
            else
                tui_fg "$TUI_COLOR_FG"
            fi
            printf '%s' "$rl_line"
            tui_reset
            tui_move $((rl_first_row + rl_index - rl_start)) $((rl_left + rl_width - 1))
            tui_fg "$TUI_COLOR_BORDER"
            printf '│'
            tui_reset
        done

        tui_move $((rl_first_row + rl_end - rl_start)) "$rl_left"
        tui_fg "$TUI_COLOR_BORDER"
        printf '└'
        _tui_menu_rule "$rl_inner" '─'
        printf '┘'
        tui_reset
    else
        # Compact fallback: no title, borders or status bar; every move is in bounds.
        rl_content_width="$rl_cols"
        rl_label_width=$((rl_content_width - 6))
        ((rl_label_width < 0)) && rl_label_width=0
        for ((rl_index = rl_start; rl_index < rl_end; rl_index++)); do
            rl_item="${TUI_MENU_ITEMS[$rl_index]}"
            rl_item_num=$(_tui_menu_number_for_index "$rl_index" "$rl_total")
            if ((rl_content_width < 6)); then
                # 极窄时编号仍可让选中行保持可见，而不只是反色空格。
                rl_line=$(tui_pad_display "$(tui_truncate_display "$rl_item_num" "$rl_content_width")" "$rl_content_width")
            else
                rl_label=$(tui_pad_display "$(tui_truncate_display "$rl_item" "$rl_label_width")" "$rl_label_width")
                rl_line=$(tui_pad_display "  $(printf '%2s' "$rl_item_num"). ${rl_label}" "$rl_content_width")
            fi
            tui_move $((rl_first_row + rl_index - rl_start)) 0
            if ((rl_index == TUI_MENU_INDEX)); then
                tui_reverse
                tui_fg "$TUI_COLOR_HIGHLIGHT"
            elif ((rl_index == rl_total - 1)); then
                tui_fg "$TUI_COLOR_MUTED"
            else
                tui_fg "$TUI_COLOR_FG"
            fi
            printf '%s' "$rl_line"
            tui_reset
        done
        return 0
    fi

    local rl_actual_left="$rl_status_left" rl_actual_right="$rl_status_right"
    if [[ "$rl_menu_id" == "main" ]]; then
        local rl_user_count rl_uptime_info
        rl_user_count=$(get_tui_managed_user_count)
        rl_uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' || printf 'unknown')
        rl_actual_left="👥 托管用户: $rl_user_count"
        rl_actual_right="⏱ $rl_uptime_info"
    elif [[ "$rl_actual_right" == *"↑/↓"* ]]; then
        rl_actual_right="数字直选  $rl_actual_right"
    fi
    local rl_viewport_suffix="[$((rl_start + 1))-${rl_end}/${rl_total}]"
    rl_actual_right+="  ${rl_viewport_suffix}"
    _tui_draw_modern_statusbar "$rl_actual_left" "$rl_actual_right" "$rl_viewport_suffix"
}
