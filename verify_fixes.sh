#!/bin/bash
# verify_fixes.sh - 验证所有修复是否成功
# 运行全面的检查确保修复有效

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "修复验证工具"
echo "======================================"
echo ""

# 颜色定义
C_RESET='\033[0m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_BLUE='\033[1;34m'

# 计数器
TESTS_PASSED=0
TESTS_FAILED=0

# 测试函数
run_test() {
    local test_name="$1"
    shift
    
    echo -ne "  测试: ${test_name} ... "
    
    if "$@" &>/dev/null; then
        echo -e "${C_GREEN}✓ 通过${C_RESET}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${C_RED}✗ 失败${C_RESET}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# shellcheck disable=SC2317
can_source_two() {
    local file1="$1"
    local file2="$2"
    bash -c 'source "$1" 2>/dev/null; source "$2" 2>/dev/null' _ "$file1" "$file2"
}

# shellcheck disable=SC2317
can_load_bootstrap_profile() {
    local project_dir="$1"
    local profile="$2"
    bash -c 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; source "$1/lib/bootstrap.sh" 2>/dev/null; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; um_load_profile "$2"' _ "$project_dir" "$profile"
}

echo -e "${C_BLUE}[1/6] 检查文件存在性${C_RESET}"
echo ""

run_test "user_manager.sh 存在" test -f "$SCRIPT_DIR/user_manager.sh"
run_test "run.sh 存在" test -f "$SCRIPT_DIR/run.sh"
run_test "tui_manager.sh 存在" test -f "$SCRIPT_DIR/tui_manager.sh"
run_test "audit_core.sh 存在" test -f "$SCRIPT_DIR/lib/audit_core.sh"
run_test "privilege.sh 存在" test -f "$SCRIPT_DIR/lib/privilege.sh"
run_test "bootstrap.sh 存在" test -f "$SCRIPT_DIR/lib/bootstrap.sh"

echo ""
echo -e "${C_BLUE}[2/6] 检查文件可执行性${C_RESET}"
echo ""

run_test "user_manager.sh 可读" test -r "$SCRIPT_DIR/user_manager.sh"
run_test "run.sh 可读" test -r "$SCRIPT_DIR/run.sh"

echo ""
echo -e "${C_BLUE}[3/6] 检查 shebang${C_RESET}"
echo ""

run_test "user_manager.sh 有 shebang" grep -q '^#!/bin/bash' "$SCRIPT_DIR/user_manager.sh"
run_test "tui_manager.sh 有 shebang" grep -q '^#!/bin/bash' "$SCRIPT_DIR/tui_manager.sh"
run_test "audit_core.sh 有 shebang" grep -q '^#!/bin/bash' "$SCRIPT_DIR/lib/audit_core.sh"
run_test "privilege.sh 有 shebang" grep -q '^#!/bin/bash' "$SCRIPT_DIR/lib/privilege.sh"
run_test "bootstrap.sh 有 shebang" grep -q '^#!/bin/bash' "$SCRIPT_DIR/lib/bootstrap.sh"

echo ""
echo -e "${C_BLUE}[4/6] 检查语法错误 (shellcheck)${C_RESET}"
echo ""

run_test "tui_manager.sh 无语法错误" shellcheck -x -S error "$SCRIPT_DIR/tui_manager.sh"
run_test "audit_core.sh 无语法错误" shellcheck -x -S error "$SCRIPT_DIR/lib/audit_core.sh"
run_test "privilege.sh 无语法错误" shellcheck -x -S error "$SCRIPT_DIR/lib/privilege.sh"

echo ""
echo -e "${C_BLUE}[5/6] 检查关键功能${C_RESET}"
echo ""

run_test "tui_manager.sh 可加载" bash -c 'TUI_MANAGER_NO_MAIN=1 source "$1"' _ "$SCRIPT_DIR/tui_manager.sh"
run_test "audit_core.sh 可加载" can_source_two "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/lib/audit_core.sh"
run_test "bootstrap.sh 可加载 full profile" can_load_bootstrap_profile "$SCRIPT_DIR" "full"
run_test "bootstrap.sh 可加载 tui profile" can_load_bootstrap_profile "$SCRIPT_DIR" "tui"

echo ""
echo -e "${C_BLUE}[6/6] 检查备份文件${C_RESET}"
echo ""

if [[ -f "$SCRIPT_DIR/user_manager.sh.backup" ]]; then
    echo -e "  检查: user_manager.sh.backup ... ${C_GREEN}已存在${C_RESET}"
else
    echo -e "  检查: user_manager.sh.backup ... ${C_BLUE}未提供（可接受）${C_RESET}"
fi

if [[ -f "$SCRIPT_DIR/lib/ui_menu_modern.sh.backup" ]]; then
    echo -e "  检查: ui_menu_modern.sh.backup ... ${C_GREEN}已存在${C_RESET}"
else
    echo -e "  检查: ui_menu_modern.sh.backup ... ${C_BLUE}未提供（可接受）${C_RESET}"
fi

echo ""
echo "======================================"
echo "验证完成！"
echo "======================================"
echo ""
echo -e "通过测试: ${C_GREEN}${TESTS_PASSED}${C_RESET}"
echo -e "失败测试: ${C_RED}${TESTS_FAILED}${C_RESET}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${C_GREEN}✓ 所有验证通过！修复成功！${C_RESET}"
    echo ""
    echo "您现在可以使用以下命令运行程序："
    echo "  bash run.sh"
    echo "  或"
    echo "  bash user_manager.sh"
    exit 0
else
    echo -e "${C_RED}✗ 部分验证失败，请检查修复${C_RESET}"
    echo ""
    echo "建议："
    echo "  1. 查看上面的失败测试详情"
    echo "  2. 检查相关文件是否存在和可访问"
    echo "  3. 重新运行分级回归：bash tests/run_regression.sh --level p1"
    exit 1
fi
