#!/bin/bash
# shellcheck disable=SC1091
# test_backup_core.sh - 备份核心功能测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export SUDO_NONINTERACTIVE="${SUDO_NONINTERACTIVE:-1}"
export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/access_control.sh"
source "$PROJECT_ROOT/lib/privilege.sh"
source "$PROJECT_ROOT/lib/backup_excludes.sh"
source "$PROJECT_ROOT/lib/backup_core.sh"

setup_test_env

BACKUP_ROOT="$TEST_TMPDIR/backup_root"
CHECKSUM_DIR="$TEST_TMPDIR/checksums"
mkdir -p "$BACKUP_ROOT" "$CHECKSUM_DIR"

test_suite_start "Backup Core - Exclude File Generation"

test_start "generate_exclude_file: 生成包含系统缓存目录的排除文件"
test_exclude="$TEST_TMPDIR/test_excludes.txt"
if generate_exclude_file "$test_exclude" >/dev/null 2>&1 && [[ -f "$test_exclude" ]]; then
    if grep -Fxq '.cache' "$test_exclude" 2>/dev/null && grep -Fxq '*.bam' "$test_exclude" 2>/dev/null; then
        test_pass
    else
        test_fail "排除文件缺少基础或生信关键模式"
    fi
else
    test_fail "排除文件未生成"
fi

test_start "generate_exclude_file: 无路径参数时返回临时文件路径"
temp_exclude="$(generate_exclude_file 2>/dev/null || true)"
if [[ -n "$temp_exclude" && -f "$temp_exclude" ]]; then
    test_pass
    rm -f "$temp_exclude"
else
    test_fail "未返回有效临时排除文件路径"
fi

test_suite_start "Backup Core - Basic Function Contracts"

test_start "show_backup_status: 空用户名返回失败"
if ! show_backup_status "" >/dev/null 2>&1; then
    test_pass
else
    test_fail "空用户名不应通过"
fi

test_start "show_backup_status: 无备份用户返回成功提示"
if show_backup_status "nobackup_user" >/dev/null 2>&1; then
    test_pass
else
    test_fail "无备份记录时应成功返回"
fi

test_start "list_backup_users: 备份根目录存在时可列出"
mkdir -p "$BACKUP_ROOT/alice/full_20260502_120000"
if list_backup_users >/dev/null 2>&1; then
    test_pass
else
    test_fail "列出备份用户失败"
fi

test_suite_start "Backup Core - Safety and Metadata"

test_start "_safe_cleanup_backups: 拒绝清理 BACKUP_ROOT 外目录"
outside_dir="$TEST_TMPDIR/outside_backup"
mkdir -p "$outside_dir"
if ! _safe_cleanup_backups "$outside_dir" 0 0 >/dev/null 2>&1; then
    test_pass
else
    test_fail "不应允许清理 BACKUP_ROOT 外目录"
fi

test_start "_safe_cleanup_backups: 不存在目录返回失败"
if ! _safe_cleanup_backups "$BACKUP_ROOT/missing" 0 0 >/dev/null 2>&1; then
    test_pass
else
    test_fail "不存在目录不应清理成功"
fi

test_start "_safe_cleanup_backups: 拒绝非法及超范围的 retention_days"
numeric_cleanup_dir="$BACKUP_ROOT/numeric_validation"
mkdir -p "$numeric_cleanup_dir/full_old"
touch -d '10 days ago' "$numeric_cleanup_dir/full_old"
invalid_retention_values=("" "-1" "1x" "999999999999999999999999999999999999")
retention_rejected=true
for invalid_value in "${invalid_retention_values[@]}"; do
    if _safe_cleanup_backups "$numeric_cleanup_dir" "$invalid_value" 0 >/dev/null 2>&1; then
        retention_rejected=false
        break
    fi
done
if [[ "$retention_rejected" == true && -d "$numeric_cleanup_dir/full_old" ]]; then
    test_pass
else
    test_fail "非法 retention_days 未被拒绝或触发了清理"
fi

test_start "_safe_cleanup_backups: 拒绝 min_keep 注入且不执行命令"
cleanup_marker="$TEST_TMPDIR/backup_cleanup_injected"
injected_min_keep='1[$(touch '"$cleanup_marker"')]'
if ! _safe_cleanup_backups "$numeric_cleanup_dir" 0 "$injected_min_keep" >/dev/null 2>&1 &&
    [[ ! -e "$cleanup_marker" && -d "$numeric_cleanup_dir/full_old" ]]; then
    test_pass
else
    test_fail "非法 min_keep 未被拒绝、执行了命令或清理了备份"
fi

test_start "_safe_cleanup_backups: 拒绝空值、格式错误及超范围 min_keep"
invalid_min_keep_values=("" "-1" "1x" "1001" "999999999999999999999999999999999999")
min_keep_rejected=true
for invalid_value in "${invalid_min_keep_values[@]}"; do
    if _safe_cleanup_backups "$numeric_cleanup_dir" 0 "$invalid_value" >/dev/null 2>&1; then
        min_keep_rejected=false
        break
    fi
done
if [[ "$min_keep_rejected" == true && -d "$numeric_cleanup_dir/full_old" ]]; then
    test_pass
else
    test_fail "非法 min_keep 未被拒绝或触发了清理"
fi

test_start "_safe_cleanup_backups: 有效参数仍按保留数量清理"
mkdir -p "$numeric_cleanup_dir/inc_old_1" "$numeric_cleanup_dir/inc_old_2" "$numeric_cleanup_dir/auto_recent"
touch -d '10 days ago' "$numeric_cleanup_dir/inc_old_1" "$numeric_cleanup_dir/inc_old_2"
if _safe_cleanup_backups "$numeric_cleanup_dir" 0001 0001 >/dev/null 2>&1 &&
    [[ ! -d "$numeric_cleanup_dir/full_old" &&
        ! -d "$numeric_cleanup_dir/inc_old_1" &&
        ! -d "$numeric_cleanup_dir/inc_old_2" &&
        -d "$numeric_cleanup_dir/auto_recent" ]]; then
    test_pass
else
    test_fail "有效参数未按 retention_days 和 min_keep 清理"
fi

test_start "update_backup_index: 缺少参数返回失败"
if ! update_backup_index "" "full" "$BACKUP_ROOT/alice/full_20260502_120000" >/dev/null 2>&1; then
    test_pass
else
    test_fail "缺少用户名不应更新索引成功"
fi

test_start "update_backup_index: 创建有效 JSON 索引"
backup_dir="$BACKUP_ROOT/alice/full_20260502_120000"
mkdir -p "$backup_dir"
if command -v jq >/dev/null 2>&1; then
    if update_backup_index "alice" "full" "$backup_dir" >/dev/null 2>&1 && [[ -f "$BACKUP_ROOT/alice/.backup_index.json" ]] && [[ "$(jq -r '.username' "$BACKUP_ROOT/alice/.backup_index.json" 2>/dev/null)" == "alice" ]]; then
        test_pass
    else
        test_fail "备份索引未正确生成"
    fi
else
    test_skip "jq 不可用，跳过 JSON 索引验证"
fi

test_start "show_backup_chain: 无索引时返回成功"
mkdir -p "$BACKUP_ROOT/bob"
if show_backup_chain "bob" >/dev/null 2>&1; then
    test_pass
else
    test_fail "无索引时应成功返回"
fi

test_suite_start "Backup Core - Schedule Input Validation"

test_start "configure_backup_schedule: 空用户名返回失败"
if ! configure_backup_schedule "" "2" >/dev/null 2>&1; then
    test_pass
else
    test_fail "空用户名不应配置定时备份成功"
fi

test_start "configure_backup_schedule: 非法小时返回失败"
if ! configure_backup_schedule "alice" "25" >/dev/null 2>&1; then
    test_pass
else
    test_fail "非法小时不应配置定时备份成功"
fi

test_suite_end
