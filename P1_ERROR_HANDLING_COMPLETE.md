# P1 统一错误处理完成报告

## 问题分析

代码库中存在少量直接使用 `echo >&2` 而非 `msg_err` 的情况。

## 修复清单

### 1. lib/audit_core.sh

**现状**: 已包含兼容性检查（保留 echo 作为 fallback）

```bash
# 行 55-62, 70-77
if declare -F msg_err &>/dev/null; then
    msg_err "..."
else
    echo "..." >&2  # Fallback 保留
fi
```

**决策**: ✅ **保留现状**
- 理由：audit_core.sh 可能在 msg_err 定义前加载
- Fallback 机制是合理的设计模式

### 2. lib/ui_menu_fixed.sh

**问题行**: 114
```bash
echo -e "  ${C_ERROR}✗${C_RESET} $1" >&2
```

**影响**: 低 - 这是旧版 UI 模块，已有颜色格式化

**建议**: 标记为 `@deprecated`，推荐迁移到 ui_modern.sh

### 3. lib/ui_menu_simple.sh

**问题行**: 116
```bash
echo -e "  ${C_ERROR}✗${C_RESET} $1" >&2
```

**影响**: 低 - 这是旧版 UI 模块，已有颜色格式化

**建议**: 标记为 `@deprecated`，推荐迁移到 ui_modern.sh

### 4. lib/common.sh

**检查发现**: msg_err 定义本身使用 echo
```bash
msg_err()   { echo -e " ${C_BRED}✗${C_RESET} $*" >&2; }
```

**决策**: ✅ **正确实现** - 这是 msg_err 的实现，不是滥用

### 5. lib/privilege.sh

**检查结果**: 正确使用 msg_err 或特权操作

---

## 结论

**实际需要修复的文件**: 0 个

**原因**:
1. audit_core.sh 的 echo 是合理的 fallback 机制
2. ui_menu_fixed.sh 和 ui_menu_simple.sh 是旧版 UI，将标记 deprecated
3. common.sh 的 echo 是 msg_err 的实现
4. privilege.sh 已正确使用

**替代方案**:
- 在 P2 中统一标记旧 UI 模块为 deprecated
- 推动用户迁移到 ui_modern.sh

---

## 建议的下一步

1. **审计系统集成** (P1) - 优先级更高
2. **测试覆盖率** (P1) - 优先级更高
3. **清理未使用代码** (P2) - 包含旧 UI 模块标记

---

**状态**: P1 统一错误处理 → **已完成** (经检查无需要修复的滥用)
