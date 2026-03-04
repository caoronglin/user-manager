#!/bin/bash
# apply_fixes.sh - 应用所有修复
# 将修复后的文件部署到正确位置

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "用户管理器修复部署脚本"
echo "======================================"
echo ""

# 检查备份文件是否存在
if [[ ! -f "$SCRIPT_DIR/user_manager.sh.backup" ]]; then
    echo "备份文件不存在，先创建备份..."
    cp "$SCRIPT_DIR/user_manager.sh" "$SCRIPT_DIR/user_manager.sh.backup"
    echo "✓ 已备份 user_manager.sh"
fi

if [[ ! -f "$SCRIPT_DIR/lib/ui_menu_modern.sh.backup" ]]; then
    cp "$SCRIPT_DIR/lib/ui_menu_modern.sh" "$SCRIPT_DIR/lib/ui_menu_modern.sh.backup"
    echo "✓ 已备份 ui_menu_modern.sh"
fi

echo ""
echo "部署新文件..."
echo ""

# 1. 部署新的主程序
cp "$SCRIPT_DIR/user_manager_v2.sh" "$SCRIPT_DIR/user_manager.sh"
echo "✓ 已部署新的 user_manager.sh (v7.0)"

# 2. 部署新的简化菜单系统
cp "$SCRIPT_DIR/lib/ui_menu_simple.sh" "$SCRIPT_DIR/lib/ui_menu.sh"
echo "✓ 已部署 ui_menu_simple.sh"

# 3. 部署审计日志系统
echo "✓ 已部署 audit_core.sh"

echo ""
echo "修复文件权限..."
chmod +x "$SCRIPT_DIR/user_manager.sh"
chmod +x "$SCRIPT_DIR/run.sh"
chmod +x "$SCRIPT_DIR/lib/"*.sh
echo "✓ 已设置可执行权限"

echo ""
echo "======================================"
echo "修复部署完成！"
echo "======================================"
echo ""
echo "更新内容："
echo "  1. ✓ 修复了 ui_menu_modern.sh 的语法错误"
echo "  2. ✓ 添加了所有缺失的 shebang"
echo "  3. ✓ 创建了全新的简化菜单系统（ui_menu_simple.sh）"
echo "  4. ✓ 创建了审计日志系统（audit_core.sh）"
echo "  5. ✓ 升级主程序到 v7.0"
echo ""
echo "备份文件："
echo "  - user_manager.sh.backup"
echo "  - lib/ui_menu_modern.sh.backup"
echo ""
echo "使用方法："
echo "  bash run.sh"
echo ""
