#!/bin/bash
# normalize_echo_output.sh - 消息输出规范化脚本 v1.0
# 自动将 echo 替换为规范的消息函数

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 颜色定义
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_RESET='\033[0m'

# ============================================================
# 辅助函数
# ============================================================

msg_info() { echo -e "${C_CYAN}●${C_RESET} $*"; }
msg_ok() { echo -e "${C_GREEN}✓${C_RESET} $*"; }
msg_warn() { echo -e "${C_YELLOW}▲${C_RESET} $*"; }
msg_err() { echo -e "${C_RED}✗${C_RESET} $*" >&2; }

# ============================================================
# 分析函数
# ============================================================

analyze_file() {
    local file="$1"
    local echo_count=0
    local problematic_count=0
    local -a issues=()
    
    while IFS= read -r line; do
        local line_num
        line_num=$(echo "$line" | cut -d: -f1)
        local content
        content=$(echo "$line" | cut -d: -f2-)
        
        # 跳过注释
        if [[ "$content" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # 检查是否包含 echo
        if [[ "$content" =~ echo ]]; then
            ((echo_count++))
            
            # 检查是否已经使用消息函数
            if [[ ! "$content" =~ msg_info|msg_ok|msg_warn|msg_err|msg_step|msg_debug ]]; then
                ((problematic_count++))
                
                # 分类消息类型
                if [[ "$content" =~ 错误|失败|Error|error|fail|Failed|FAILED ]]; then
                    issues+=("$line_num:ERROR:$content")
                elif [[ "$content" =~ 成功|完成|Success|success|OK|ok ]]; then
                    issues+=("$line_num:SUCCESS:$content")
                elif [[ "$content" =~ 警告|注意|Warning|warning ]]; then
                    issues+=("$line_num:WARN:$content")
                else
                    issues+=("$line_num:INFO:$content")
                fi
            fi
        fi
    done < <(grep -n "echo" "$file" 2>/dev/null || true)
    
    echo "$file|$echo_count|$problematic_count"
    for issue in "${issues[@]}"; do
        echo "  $issue"
    done
}

# ============================================================
# 转换函数
# ============================================================

convert_file() {
    local file="$1"
    local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
    local converted=0
    
    # 创建备份
    cp "$file" "$backup"
    msg_info "备份已创建: $backup"
    
    # 临时文件
    local tmp_file
    tmp_file=$(mktemp)
    
    while IFS= read -r line; do
        local converted_line="$line"
        
        # 跳过注释和已使用消息函数的行
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ msg_info|msg_ok|msg_warn|msg_err ]]; then
            echo "$line" >> "$tmp_file"
            continue
        fi
        
        # 错误消息
        if [[ "$line" =~ echo.*错误|echo.*失败|echo.*Error|echo.*error ]]; then
            converted_line=$(echo "$line" | sed -E 's/echo (.*)错误/msg_err "\1错误"/g')
            ((converted++))
        # 成功消息
        elif [[ "$line" =~ echo.*成功|echo.*完成|echo.*Success ]]; then
            converted_line=$(echo "$line" | sed -E 's/echo (.*)成功/msg_ok "\1成功"/g')
            ((converted++))
        # 警告消息
        elif [[ "$line" =~ echo.*警告|echo.*注意|echo.*Warning ]]; then
            converted_line=$(echo "$line" | sed -E 's/echo (.*)警告/msg_warn "\1警告"/g')
            ((converted++))
        # 步骤消息
        elif [[ "$line" =~ echo.*正在|echo.*处理中|echo.*Processing ]]; then
            converted_line=$(echo "$line" | sed -E 's/echo (.*)/msg_step "\1"/g')
            ((converted++))
        fi
        
        echo "$converted_line" >> "$tmp_file"
    done < "$file"
    
    # 替换原文件
    mv "$tmp_file" "$file"
    
    msg_ok "转换完成: $converted 行"
}

# ============================================================
# 交互式转换
# ============================================================

interactive_convert() {
    local file="$1"
    
    msg_info "分析文件: $file"
    echo ""
    
    # 分析文件
    local analysis
    analysis=$(analyze_file "$file")
    local stats
    stats=$(echo "$analysis" | head -n 1)
    local issues
    issues=$(echo "$analysis" | tail -n +2)
    
    # 显示统计
    local filename echo_count problematic_count
    IFS='|' read -r filename echo_count problematic_count <<< "$stats"
    
    echo "文件: $filename"
    echo "总 echo 数: $echo_count"
    echo "待处理: $problematic_count"
    echo ""
    
    # 显示问题
    if [[ -n "$issues" ]]; then
        msg_info "发现以下需要转换的 echo 语句:"
        echo "$issues" | head -20
        local total_issues
        total_issues=$(echo "$issues" | wc -l)
        if (( total_issues > 20 )); then
            echo "... 还有 $((total_issues - 20)) 行未显示"
        fi
        echo ""
    fi
    
    # 询问是否转换
    if (( problematic_count > 0 )); then
        read -p "是否自动转换？(y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            convert_file "$file"
        else
            msg_info "跳过转换"
        fi
    else
        msg_ok "无需转换"
    fi
}

# ============================================================
# 批量处理
# ============================================================

batch_analyze() {
    local directory="$1"
    local pattern="${2:-*.sh}"
    
    msg_info "批量分析目录: $directory"
    echo ""
    
    local total_files=0
    local total_echos=0
    local total_problems=0
    
    while IFS= read -r file; do
        local analysis
        analysis=$(analyze_file "$file")
        local stats
        stats=$(echo "$analysis" | head -n 1)
        
        IFS='|' read -r filename echo_count problematic_count <<< "$stats"
        
        if (( problematic_count > 0 )); then
            printf "%-50s %3d echo, %3d issues\n" "$filename" "$echo_count" "$problematic_count"
            ((total_files++))
            total_echos=$((total_echos + echo_count))
            total_problems=$((total_problems + problematic_count))
        fi
    done < <(find "$directory" -name "$pattern" -type f 2>/dev/null)
    
    echo ""
    echo "========================================="
    echo "总计: $total_files 个文件, $total_echos 个 echo, $total_problems 个问题"
}

# ============================================================
# 主菜单
# ============================================================

show_help() {
    cat << EOF
消息输出规范化工具 v1.0

用法: $(basename "$0") [选项] [文件|目录]

选项:
  -a, --analyze     仅分析，不转换
  -c, --convert     自动转换（创建备份）
  -b, --batch       批量分析目录
  -h, --help        显示帮助

示例:
  # 分析单个文件
  $(basename "$0") -a lib/common.sh
  
  # 转换单个文件（交互式）
  $(basename "$0") lib/common.sh
  
  # 批量分析整个项目
  $(basename "$0") -b .
  
  # 批量转换（谨慎使用）
  $(basename "$0") -c -b lib/

注意:
  - 转换前会自动创建备份文件
  - 建议先用 -a 分析，再手动检查
  - 不是所有 echo 都需要转换（如 here-doc 中的）
EOF
}

# ============================================================
# 主函数
# ============================================================

main() {
    local mode="interactive"
    local target=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--analyze)
                mode="analyze"
                shift
                ;;
            -c|--convert)
                mode="convert"
                shift
                ;;
            -b|--batch)
                mode="batch"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done
    
    # 默认目标为项目根目录
    if [[ -z "$target" ]]; then
        target="$PROJECT_ROOT"
    fi
    
    # 执行操作
    case "$mode" in
        analyze)
            if [[ -f "$target" ]]; then
                analyze_file "$target"
            else
                batch_analyze "$target"
            fi
            ;;
        convert)
            if [[ -f "$target" ]]; then
                convert_file "$target"
            else
                msg_err "批量转换需要逐个文件确认，请使用交互模式"
                msg_info "示例: $(basename "$0") lib/common.sh"
                exit 1
            fi
            ;;
        batch)
            batch_analyze "$target"
            ;;
        interactive)
            if [[ -f "$target" ]]; then
                interactive_convert "$target"
            else
                msg_err "未指定文件"
                show_help
                exit 1
            fi
            ;;
    esac
}

main "$@"
