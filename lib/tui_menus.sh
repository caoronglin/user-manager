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
_TUI_MENU_ITEMS["user"]="创建/更新用户|修改用户密码|删除用户账户|重命名用户账户|暂停/恢复用户|调整用户配额|配置资源限制|查看托管用户|返回主菜单"
_TUI_MENU_WIDTH["user"]=50
_TUI_MENU_STATUS_LEFT["user"]="用户管理"
_TUI_MENU_STATUS_RIGHT["user"]="↑/↓ 导航  Enter 选择  q 返回"

# 磁盘与配额管理
_TUI_MENU_TITLE["disk"]="磁盘与配额管理"
_TUI_MENU_ITEMS["disk"]="数据盘概览|调整用户配额|查看用户配额|配置资源限制|查看资源使用|返回主菜单"
_TUI_MENU_WIDTH["disk"]=50
_TUI_MENU_STATUS_LEFT["disk"]="磁盘与配额管理"
_TUI_MENU_STATUS_RIGHT["disk"]="↑/↓ 导航  Enter 选择  q 返回"

# 网络与安全管理
_TUI_MENU_TITLE["network"]="网络与安全管理"
_TUI_MENU_ITEMS["network"]="防火墙规则|DNS 访问控制|符号链接与共享|SSH 与 Fail2ban|网络栈诊断|返回主菜单"
_TUI_MENU_WIDTH["network"]=50
_TUI_MENU_STATUS_LEFT["network"]="网络与安全管理"
_TUI_MENU_STATUS_RIGHT["network"]="↑/↓ 导航  Enter 选择  q 返回"

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
_TUI_MENU_ITEMS["ssh_fail2ban"]="SSH 安全基线摘要|最近认证失败|Fail2ban 状态|配置 sshd jail|列出全部 jails|查看 nginx jail 状态|配置 nginx jail|返回上级"
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
_TUI_MENU_ITEMS["system"]="系统信息概览|内存信息|硬件健康检查|系统日志分析|Ubuntu APT/重启维护|网络栈诊断|Systemd Timers|更多系统选项|返回主菜单"
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
# 通用菜单渲染引擎
# ============================================================

# 根据菜单 ID 绘制标准菜单
# 用法: _tui_draw_menu "main"
_tui_draw_menu() {
    local menu_id="${1:-main}"
    local title="${_TUI_MENU_TITLE[$menu_id]:-未定义菜单}"
    local items_str="${_TUI_MENU_ITEMS[$menu_id]}"
    local width="${_TUI_MENU_WIDTH[$menu_id]:-50}"
    local row="${_TUI_MENU_ROW[$menu_id]:-4}"
    local status_left="${_TUI_MENU_STATUS_LEFT[$menu_id]}"
    local status_right="${_TUI_MENU_STATUS_RIGHT[$menu_id]}"

    tui_draw_fill 0 0 "$TUI_COLS" 3 "$TUI_COLOR_ACCENT"
    tui_fg 0
    tui_move 1 $(( (TUI_COLS - ${#title}) / 2 ))
    tui_bold
    echo "$title"
    tui_reset

    # 将 | 分隔的菜单项转为数组传递给 tui_menu_create
    local -a items=()
    local IFS='|'
    read -ra items <<< "$items_str"

    tui_menu_create "$title" "${items[@]}"
    tui_menu_draw "$row" $(( (TUI_COLS - width) / 2 )) "$width"

    # 动态生成状态栏内容
    local actual_left="$status_left"
    local actual_right="$status_right"
    if [[ "$menu_id" == "main" ]]; then
        local user_count uptime_info
        user_count=$(get_tui_managed_user_count)
        uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")
        actual_left="托管用户: $user_count"
        actual_right="运行时间: $uptime_info"
    fi
    tui_statusbar_draw $((TUI_LINES - 1)) "$actual_left" "$actual_right"
}
