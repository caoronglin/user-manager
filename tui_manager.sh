#!/bin/bash
# tui_manager.sh - TUI版用户管理器 v1.0.0
# 基于原生Bash的终端用户界面

set -uo pipefail

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# 加载核心库
source "$LIB_DIR/config.sh"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/privilege.sh"
source "$LIB_DIR/tui_core.sh"

# ============================================================
# 主界面
# ============================================================

# 绘制主菜单
draw_main_menu() {
    # 绘制标题栏
    tui_draw_fill 0 0 "$TUI_COLS" 3 "$TUI_COLOR_ACCENT"
    tui_fg 0
    tui_move 1 $(( (TUI_COLS - 30) / 2 ))
    tui_bold
    echo "用户与系统管理器 v0.3.0"
    tui_reset
    
    # 绘制菜单
    tui_menu_create "主菜单" \
        "用户管理" \
        "磁盘与配额管理" \
        "网络与安全管理" \
        "备份与恢复" \
        "报告与统计" \
        "系统维护" \
        "实时监控" \
        "查看日志" \
        "退出"
    
    tui_menu_draw 4 $(( (TUI_COLS - 50) / 2 )) 50
    
    # 绘制状态栏
    local user_count
    user_count=$(get_managed_user_count 2>/dev/null || echo "0")
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")
    
    tui_statusbar_draw $((TUI_LINES - 1)) \
        "用户数: $user_count" \
        "运行时间: $uptime_info "
}

# 主菜单键盘处理
handle_main_menu_key() {
    local key="$1"
    
    local result
    result=$(tui_menu_handle_key "$key")
    
    if [[ -n "$result" ]]; then
        case "$result" in
            0) run_submenu "用户管理" draw_user_menu handle_user_menu_key ;;
            1) run_submenu "磁盘与配额" draw_quota_menu handle_quota_menu_key ;;
            2) run_submenu "网络与安全" draw_network_menu handle_network_menu_key ;;
            3) run_submenu "备份与恢复" draw_backup_menu handle_backup_menu_key ;;
            4) run_submenu "报告与统计" draw_report_menu handle_report_menu_key ;;
            5) run_submenu "系统维护" draw_system_menu handle_system_menu_key ;;
            6) run_monitor_view ;;
            7) run_log_viewer ;;
            8|-1) TUI_RUNNING=false ;;
        esac
        TUI_REDRAW=true
    fi
}

# ============================================================
# 子菜单运行
# ============================================================

run_submenu() {
    local title="$1"
    local draw_func="$2"
    local key_handler="$3"
    
    tui_run "$draw_func" "$key_handler"
}

# ============================================================
# 用户管理菜单
# ============================================================

draw_user_menu() {
    tui_draw_fill 0 0 "$TUI_COLS" 3 235
    tui_fg 0
    tui_move 1 $(( (TUI_COLS - 20) / 2 ))
    tui_bold
    echo "用户管理"
    tui_reset
    
    tui_menu_create "用户管理" \
        "创建/更新用户" \
        "修改用户密码" \
        "删除用户账户" \
        "重命名用户账户" \
        "暂停/恢复用户" \
        "调整用户配额" \
        "配置资源限制" \
        "查看托管用户" \
        "返回主菜单"
    
    tui_menu_draw 4 $(( (TUI_COLS - 45) / 2 )) 45
}

handle_user_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    
    if [[ -n "$result" ]]; then
        case "$result" in
            0) tui_message "用户管理" "创建用户功能" ;;
            1) tui_message "用户管理" "修改密码功能" ;;
            2) tui_message "用户管理" "删除用户功能" ;;
            7) show_user_list ;;
            8|-1) return 0 ;;
        esac
        TUI_REDRAW=true
    fi
}

# ============================================================
# 系统监控视图
# ============================================================

run_monitor_view() {
    local running=true
    
    while $running; do
        tui_clear
        
        # 标题
        tui_draw_fill 0 0 "$TUI_COLS" 3 39
        tui_fg 0
        tui_move 1 $(( (TUI_COLS - 20) / 2 ))
        tui_bold
        echo "实时系统监控"
        tui_reset
        
        # CPU使用率
        local cpu_usage
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2)}' 2>/dev/null || echo "0")
        tui_progress_draw 5 5 $((TUI_COLS - 10)) "$cpu_usage" "CPU"
        
        # 内存使用率
        local mem_usage mem_total mem_used
        if command -v free &>/dev/null; then
            mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
            mem_total=$(free -h | grep Mem | awk '{print $2}')
            mem_used=$(free -h | grep Mem | awk '{print $3}')
        else
            mem_usage=0
            mem_total="?"
            mem_used="?"
        fi
        tui_progress_draw 7 5 $((TUI_COLS - 10)) "$mem_usage" "内存 ($mem_used/$mem_total)"
        
        # 磁盘使用率
        local disk_usage disk_total
        disk_usage=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
        disk_total=$(df -h / | tail -1 | awk '{print $2}' 2>/dev/null || echo "?")
        tui_progress_draw 9 5 $((TUI_COLS - 10)) "$disk_usage" "磁盘 ($disk_total)"
        
        # 进程信息
        tui_move 12 5
        tui_bold
        tui_fg "$TUI_COLOR_ACCENT"
        echo "进程状态:"
        tui_reset
        
        local procs
        procs=$(ps aux --sort=-%mem 2>/dev/null | head -6 | tail -5)
        tui_move 13 5
        printf "%-10s %-8s %-6s %-6s %s\n" "USER" "PID" "CPU%" "MEM%" "COMMAND"
        tui_move 14 5
        echo "$procs" | while read -r line; do
            printf "%-10s %-8s %-6s %-6s %s\n" $line
        done
        
        # 提示
        tui_move $((TUI_LINES - 2)) 5
        tui_fg "$TUI_COLOR_MUTED"
        echo "按 b 启动 btop | n 启动 ncdu | q 返回"
        tui_reset
        
        # 读取按键
        local key
        key=$(tui_read_key 2>/dev/null) || continue
        
        case "$key" in
            b|B)
                tui_cleanup
                if command -v btop &>/dev/null; then
                    btop
                elif command -v htop &>/dev/null; then
                    htop
                else
                    tui_message "错误" "未安装 btop 或 htop"
                fi
                tui_init
                ;;
            n|N)
                tui_cleanup
                if command -v ncdu &>/dev/null; then
                    ncdu /
                else
                    tui_message "错误" "未安装 ncdu"
                fi
                tui_init
                ;;
            q|ESC) running=false ;;
        esac
    done
}

# ============================================================
# 日志查看器
# ============================================================

run_log_viewer() {
    local log_file="${LOG_DIR:-./logs}/audit.log"
    local scroll_pos=0
    local running=true
    
    while $running; do
        tui_clear
        
        # 标题
        tui_draw_fill 0 0 "$TUI_COLS" 3 235
        tui_fg 0
        tui_move 1 $(( (TUI_COLS - 20) / 2 ))
        tui_bold
        echo "日志查看器"
        tui_reset
        
        # 日志内容
        if [[ -f "$log_file" ]]; then
            local lines
            lines=$(wc -l < "$log_file")
            local display_lines=$((TUI_LINES - 5))
            
            tail -n $((lines - scroll_pos)) "$log_file" 2>/dev/null | head -n "$display_lines" | \
                while IFS= read -r line; do
                    # 高亮不同级别
                    if [[ "$line" =~ ERROR|FAIL ]]; then
                        tui_fg "$TUI_COLOR_ERROR"
                    elif [[ "$line" =~ WARN ]]; then
                        tui_fg "$TUI_COLOR_WARNING"
                    elif [[ "$line" =~ SUCCESS|OK ]]; then
                        tui_fg "$TUI_COLOR_SUCCESS"
                    fi
                    echo "$line"
                    tui_reset
                done
        else
            tui_move 5 $(( (TUI_COLS - 20) / 2 ))
            tui_fg "$TUI_COLOR_MUTED"
            echo "日志文件不存在: $log_file"
            tui_reset
        fi
        
        # 提示
        tui_move $((TUI_LINES - 1)) 0
        tui_statusbar_draw $((TUI_LINES - 1)) \
            "日志: $log_file" \
            "↑/↓ 滚动  q 返回 "
        
        # 读取按键
        local key
        key=$(tui_read_key 2>/dev/null) || continue
        
        case "$key" in
            UP) ((scroll_pos > 0)) && ((scroll_pos--)) ;;
            DOWN) ((scroll_pos++)) ;;
            q|ESC) running=false ;;
        esac
    done
}

# ============================================================
# 用户列表视图
# ============================================================

show_user_list() {
    tui_clear
    
    tui_draw_fill 0 0 "$TUI_COLS" 3 39
    tui_fg 0
    tui_move 1 $(( (TUI_COLS - 20) / 2 ))
    tui_bold
    echo "托管用户列表"
    tui_reset
    
    if declare -F list_users &>/dev/null; then
        local users
        users=$(list_users 2>/dev/null)
        
        tui_move 4 5
        tui_bold
        printf "%-20s %-10s %-15s %s\n" "用户名" "配额" "状态" "创建时间"
        tui_reset
        
        tui_move 5 5
        echo "$users" | while read -r line; do
            echo "$line"
        done
    else
        tui_move 5 10
        echo "无法获取用户列表"
    fi
    
    tui_move $((TUI_LINES - 2)) 10
    tui_fg "$TUI_COLOR_MUTED"
    echo "按任意键返回..."
    tui_reset
    
    tui_read_key
}

# ============================================================
# 其他菜单占位
# ============================================================

draw_quota_menu() {
    tui_menu_create "磁盘与配额管理" \
        "查看配额使用情况" \
        "设置用户配额" \
        "配额报告" \
        "返回"
    tui_menu_draw 4 $(( (TUI_COLS - 40) / 2 )) 40
}

handle_quota_menu_key() {
    local result
    result=$(tui_menu_handle_key "$1")
    [[ "$result" == "3" || "$result" == "-1" ]] && return 0
    tui_message "配额管理" "功能开发中"
    TUI_REDRAW=true
}

draw_network_menu() {
    tui_menu_create "网络与安全管理" \
        "防火墙规则管理" \
        "DNS白名单管理" \
        "网络信息查看" \
        "返回"
    tui_menu_draw 4 $(( (TUI_COLS - 40) / 2 )) 40
}

handle_network_menu_key() {
    local result
    result=$(tui_menu_handle_key "$1")
    [[ "$result" == "3" || "$result" == "-1" ]] && return 0
    tui_message "网络管理" "功能开发中"
    TUI_REDRAW=true
}

draw_backup_menu() {
    tui_menu_create "备份与恢复" \
        "创建备份" \
        "恢复备份" \
        "备份设置" \
        "验证备份" \
        "返回"
    tui_menu_draw 4 $(( (TUI_COLS - 40) / 2 )) 40
}

handle_backup_menu_key() {
    local result
    result=$(tui_menu_handle_key "$1")
    [[ "$result" == "4" || "$result" == "-1" ]] && return 0
    tui_message "备份管理" "功能开发中"
    TUI_REDRAW=true
}

draw_report_menu() {
    tui_menu_create "报告与统计" \
        "用户活动报告" \
        "资源使用报告" \
        "生成HTML报告" \
        "返回"
    tui_menu_draw 4 $(( (TUI_COLS - 40) / 2 )) 40
}

handle_report_menu_key() {
    local result
    result=$(tui_menu_handle_key "$1")
    [[ "$result" == "3" || "$result" == "-1" ]] && return 0
    tui_message "报告管理" "功能开发中"
    TUI_REDRAW=true
}

draw_system_menu() {
    tui_menu_create "系统维护" \
        "系统信息" \
        "清理临时文件" \
        "检查更新" \
        "返回"
    tui_menu_draw 4 $(( (TUI_COLS - 40) / 2 )) 40
}

handle_system_menu_key() {
    local result
    result=$(tui_menu_handle_key "$1")
    [[ "$result" == "3" || "$result" == "-1" ]] && return 0
    tui_message "系统维护" "功能开发中"
    TUI_REDRAW=true
}

# ============================================================
# 主入口
# ============================================================

main() {
    # 初始化TUI
    tui_init
    
    # 运行主循环
    tui_run draw_main_menu handle_main_menu_key
    
    # 清理
    tui_cleanup
}

# 运行
main "$@"