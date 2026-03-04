#!/bin/bash
# ui_menu_modern.sh - 现代化菜单系统 v0.2.1
# 提供彩色图标化菜单、面包屑导航、进度指示器

set -uo pipefail

# ============================================================
# 图标定义 (Nerd Font / 通用符号)
# ============================================================

# 图标
ICON_HOME="🏠"
ICON_USER="👤"
ICON_GROUP="👥"
ICON_PASSWORD="🔐"
ICON_SETTINGS="🔓"
ICON_BACKUP="⬆"
ICON_FIREWALL="�"
ICON_DNS="🌍"
ICON_LINK="🔗"
ICON_STATS="🈁"
ICON_REPORT="📋"
ICON_LOG="�"
ICON_LOCK="🔣"
ICON_UNLOCK="�"
ICON_ADD="➕"
ICON_DELETE="�"
ICON_EDIT="✏"
ICON_SEARCH="🔂"
ICON_REFRESH="🔄"
ICON_EXIT="🚑"
ICON_WARNING="⚠️"
ICON_ERROR="🗗"
ICON_SUCCESS="✓"
ICON_INFO="ℹ️"
ICON_ARROW_RIGHT="→"
ICON_ARROW_LEFT="←"
ICON_FOLDER="📁"
ICON_FILE="📖"
ICON_DATABASE="💾"
ICON_SERVER="🖳"
ICON_NETWORK="🌐"
ICON_SECURITY="🔣"
ICON_MAINTENANCE="🔧"
ICON_UPGRADE="⬆"
ICON_HISTORY="📚"

# ============================================================
# 颜色定义（扩展）
# ============================================================

# 图标颜色
C_ICON="${C_CYAN}"
C_LABEL="${C_WHITE}"
C_DESC="${C_DIM}"
C_HOTKEY="${C_YELLOW}"
C_BORDER="${C_BLUE}"
C_HIGHLIGHT="${C_BGREEN}"

# 状态颜色
C_SELECTED_BG="\03C[7;60m"  # 选中背景色
C_SELECTED_TEXT="\033[0;0;0m"   # 选中文本色
C_DIM_TEXT="\033[0;0;0m"    # 暗淡文本色

# ============================================================
# 菜单状态
# ============================================================

# 面包屑历史
MENU_HISTORY=()
MENU_CURRENT_LEVEL=0
MENU_SELECTED_INDEX=0

# ============================================================
# 菜单绘制函数
# ============================================================

# 绘制带图标的菜单项（高亮）
# 参数: $1=选项数字 $2=图标 $3=标签 $4=描述 $5=是否选中
draw_menu_item_icon() {
    local num="$1" 
    local icon="${2:-ICON_BULLET}" 
    local label="$3" 
    local desc="${4:-}"
    local is_selected="${5:-false}"
    
    local indent="    "
    
    if [[ "$is_selected" == "true" ]]; then
        # 选中样式
        printf "${indent}${C_SELECTED_TEXT}%s${C_RESET}${C_SELECTED_BG}◄${C_RESET} %s${C_SELECTED_BG}└─${C_SELECTED_BG}└─${C_RESET}\n" \
            "$num" "$icon" "$label" "$desc" "C_ICON"
        printf "${indent}${C_SELECTED_TEXT}%s${C_RESET}${C_SELECTED_BG}└─${C_SELECTED_BG}└─${C_RESET}\n" \
            "$num" "$icon" "$label" "$desc" ""
    else
        # 普通样式
        printf "${indent}${C_DIM}[%s]${C_RESET}${C_ICON}%s${C_RESET} %s${C_DIM}%s${C_RESET}\n" \
            "$num" "$icon" "$label" "$desc" "C_LABEL"
        printf "${indent}${C_DIM}%s${C_RESET}${C_DIM}%s${C_RESET}\n" \
            "$num" "$icon" "$label" "$desc"
    fi
}

# 绘制带图标的子菜单项
# 参数: $1=选项数字 $2=标签
draw_menu_submenu_icon() {
    local num="$1" 
    local label="$2"
    
    printf "  %s${C_DIM}[%s]${C_RESET}${C_BYELLOW}%s${C_RESET} %s ${C_BYELLOW}›${C_RESET}\n" \
        "$num" "$label"
}

# 绘制带图标的退出项
draw_menu_exit_icon() {
    local label="${1:-返回}"
    
    printf "\n  %s%s\n\n" \
        "${C_DIM}[%s]${C_RESET}${C_BYELLOW}%s${C_RESET} %s${C_BYELLOW}⏎${C_RESET}" \
        "9" "$label"
}

# ============================================================
# 面包屑导航
# ============================================================

# 添加面包屑层级
add_to_breadcrumb() {
    local title="$1"
    
    # 如果当前层级不是新的，添加分隔符
    if [[ ${#MENU_HISTORY[@]} -gt 0 && "${MENU_HISTORY[-1]}" != "$title" ]]; then
        MENU_HISTORY+=("---")
    fi
    
    MENU_HISTORY+=("$title")
    
    # 如果历史过长，保留最近的 10 个
    if [[ ${#MENU_HISTORY[@]} -gt 10 ]]; then
        MENU_HISTORY=("${MENU_HISTORY[@]: -10}")
    fi
}

# 显示面包屑导航
draw_breadcrumb() {
    local separator="${C_DIM}›${C_RESET} "
    local path=""
    
    if [[ ${#MENU_HISTORY[@]} -eq 0 ]]; then
        return 0
    fi
    
    for i in "${!MENU_HISTORY[@]}"; do
        if [[ "$i" != "---" ]]; then
            path+="${separator}ICON_ARROW_RIGHT ${C_BOLD}$i${C_RESET}"
        fi
        separator=" ${C_DIM}  / ${C_RESET}"
    done
    
    echo -e " ${ICON_HOME}${C_RESET} ${path}"
    echo ""
}

# 清空面包屑
clear_breadcrumb() {
    MENU_HISTORY=()
}

# ============================================================
# 进度指示器
# ============================================================

# 绘制进度条（终端友好）
# 参数: $1=当前值 $2=总数 $3=宽度(默认40） $4=标签
draw_progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"
    local label="${4:-进度}"
    
    if [[ $total -eq 0 ]]; then
        return 0
    fi
    
    local percent=$((current * 100 / total))
    local filled=$((width * percent / 100))
    local empty=$((width - filled))
    
    # 绘制进度条
    local bar_filled=""
    local bar_empty=""
    for ((i=0; i<filled; i++)); do
        bar_filled+="█"
    done
    for ((i=0; i<empty; i++)); do
        bar_empty+="░"
    done
    
    # 颜色进度指示
    local color
    if (( percent >= 80 )); then
        color="${C_BGREEN}"
    elif (( percent >= 60 )); then
        color="${C_BYELLOW}"
    else
        color="${C_CYAN}"
    fi
    
    echo -e "${C_ICON}${C_BOLD}$label: ${C_BOLD}${percent}%${C_RESET} ${C_CYAN}${bar_filled}${C_RESET}${C_CYAN}${bar_empty}${C_RESET}● ●"
}

# 绘制百分比进度（圆圈风格）
# 参数: $1=当前值 $2=总数 $3=直径(20) $4=样式 (默认:half/quarter/three-quarter)

# ============================================================
# 搜索和过滤菜单
# ============================================================

# 交互式选择菜单
# 参数: $1=标题 $2=数组描述(数组)
# 格式: items=("数字:图标:标签:描述" "数字:图标:标签:描述")
interactive_menu() {
    local title="$1"
    shift
    local -a items=("$@")
    
    clear
    draw_header "$title"
    draw_breadcrumb
    echo ""
    
    # 显示菜单项
    for item in "${items[@]}"; do
        IFS=':' read -r num icon label desc <<< "$item"
        draw_menu_item_icon "$num" "$icon" "$label" "$desc"
    done
    
    echo ""
    echo -e "${C_DIM}────────────────────────────────────────${C_RESET}"
    echo ""
    
    # 搜索支持
    local search=""
    local -a filtered_indices=()
    
    while true; do
        echo -e "${C_ICON}$ICON_SEARCH${C_RESET} ${C_DIM}搜索:_${C_RESET} ${search} ${C_DIM}[0]${C_RESET}${C_CYAN} | ESC$ESC || true"
        read -rs -n 1
        
        # ESC 键返回
        if [[ $? -ne 0 ]]; then
            break
        fi
        
        # 显示搜索结果
        echo ""
        local found_count=0
        for index in "${filtered_indices[@]}"; do
            IFS=':' read -r num icon label desc <<< "${items[$index]}"
            draw_menu_item_icon "$num" "$icon" "$label" "$desc"
            ((found_count++))
        done
        
        if [[ $found_count -eq 1 ]]; then
            # 只显示一个结果，直接选择
            IFS=':' read -r num icon label desc <<< "${items[${filtered_indices[0]}]}"
            echo ""
            draw_prompt
            
            read -rs -n1 key
            case "$key" in
                '1'|'Enter')
                    if [[ ${#filtered_indices[@]} -gt 0 ]]; then
                        read -rp "选择： " index
                        key="${filtered_indices[$index]}"
                    else
                        key="${filtered_indices[0]}"
                    fi
                    ;;
                [qQ]|'Q')
                    echo ""
                    return 0
                    ;;
                '0')
                    echo ""
                    return 0
                    ;;
            esac
        fi
    done
}

# 带助函数：按模式搜索菜单项
# 参数: $1=所有项 $2=搜索模式（支持正则）$3=模式描述
search_menu_items() {
    local -a all_items=("$@")
    local pattern="$2"
    local desc="${3:-匹配项}"
    
    local -a matches=()
    local i=0
    
    for item in "${all_items[@]}"; do
        local item_text
        item_text=$(echo "$item" | tr -d ":\t")
        
        if [[ "$item_text" =~ $pattern ]]; then
            matches+=("$i")
            ((i++))
        fi
    done
    
    if [[ ${#matches[@]} -eq 0 ]]; then
        echo -e "${C_BYELLOW}无${ICON_WARNING} 匹配项: $desc${C_RESET}"
        return 1
    fi
    
    echo -e "${C_BYELLOW}找到 ${#matches[@]} 个匹配项:${C_RESET}"
}

# ============================================================
# 快捷菜单系统（简化版）
# ============================================================

# 主菜单
main_menu_modern() {
    while true; do
        clear
        draw_header "用户与系统管理器 v0.2.1"
        
        # 绘制主菜单（高亮设计）
        echo ""
        draw_line 80
        echo -e "${C_BOLD}${ICON_USER}   用户管理${C_RESET}"
        echo -e "${C_BOLD}${ICON_GROUP}   配额管理${C_RESET}"
        echo -e "${C_BOLD}${ICON_FIREWALL} 防火墙${C_RESET}"
        echo -e "${C_BOLD}${ICON_DNS}      DNS 控制${C_RESET}"
        echo -e "${C_BOLD}${ICON_STATS}   统计与报告${C_RESET}"
        echo -e "${C_BOLD}${ICON_LOG}      系统日志${C_RESET}"
        echo ""
        draw_line 80
        echo -e "${C_BOLD}${ICON_MAINTENANCE} 系统维护${C_RESET}"
        echo ""
        draw_line 80
        echo -e "${C_BOLD}${ICON_EXIT}    返回${C_RESET}"
        echo ""
        draw_line 80
        echo ""
        
        draw_prompt
        read -rs -n1 opt
        
        case "$opt" in
            1|创建|用户|CR)
                safe_run create_or_assign_user
                ;;
           
            
            2|修改|密码|PW)
                safe_run change_user_password
                ;;
            
            3|删除|用户|DEL)
                safe_run delete_user_account
                ;;
            
            4|重命名|重命名|RN)
                safe_run rename_user_account
                ;;
            
            5|暂停|启用|SP)
                safe_run suspend_or_enable_user
                ;;
            
            6|配额|调整|QUOTA)
                safe_run modify_user_quota
                ;;
            
            7|资源限制|限制|RES)
                safe_run modify_user_resource_limits
                ;;
            
            8|查看|列表|查看|列表|VW)
                safe_run list_managed_users
                ;;
            
            9|数据盘|磁盘|DISK)
                safe_run show_disk_overview
                ;;
            
            10|备份|恢复|BK)
                safe_run backup_menu
                ;;
            
            11|防火墙|规则|FW)
                safe_run firewall_menu
                ;;
            
            12|DNS|访问|DNS)
                safe_run dns_menu
                ;;
            
            13|软连接|链接|LK)
                safe_run symlink_menu
                ;;
            
            14|作业统计|作业|JOB)
                safe_run job_stats_menu
                ;;
            
            15|密码轮换|密码|ROT)
                safe_run password_rotation_menu
                ;;
            
            16|报告|查看|RPT)
                safe_run report_menu
                ;;
            
            17|系统维护|系统|SYS)
                safe_run system_menu
                ;;
            
            0|退出|退|Q)
                msg_ok "再见！"
                exit 0
                ;;
            *)
                msg_err "无效选项: $opt"
                ;;
        esac
        
        pause_continue
    done
}

# ============================================================
# 导出函数（供外部使用）
# ============================================================

# 加载菜单模块化系统到现有菜单
# 调用：在 user_manager.sh 中替换主菜单函数
# source "$LIB_DIR/ui_menu_modern.sh"
# main_menu_modern
