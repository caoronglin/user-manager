#!/bin/bash
# shellcheck disable=SC1091
# test_lock_core.sh - 锁系统核心功能测试
# 测试简单锁、超时锁、用户级锁、读写锁、操作锁

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export SUDO_NONINTERACTIVE="${SUDO_NONINTERACTIVE:-1}"
export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"

setup_test_env

# ============================================================
# 简单实例锁测试
# ============================================================

test_suite_start "Lock Core - Simple Instance Lock"

test_start "acquire_lock: 获取简单锁成功"
if acquire_lock; then
    test_pass
    release_lock
else
    test_fail "无法获取简单实例锁"
fi

test_start "acquire_lock: 重复获取应失败"
if acquire_lock; then
    if acquire_lock 2>/dev/null; then
        test_fail "重复获取不应该成功"
        release_lock
    else
        test_pass
        release_lock
    fi
else
    test_fail "首次获取锁失败"
fi

test_start "release_lock: 释放后状态正确"
if acquire_lock; then
    release_lock
    if [[ "$LOCK_HELD" == "false" ]]; then
        test_pass
    else
        test_fail "释放后 LOCK_HELD 应为 false"
    fi
else
    test_fail "无法获取锁"
fi

# ============================================================
# 增强超时锁测试
# ============================================================

test_suite_start "Lock Core - Enhanced Timeout Lock"

test_start "acquire_lock_with_timeout: 短超时获取锁成功"
if acquire_lock_with_timeout 5; then
    test_pass
    release_lock_enhanced
else
    test_fail "无法获取增强锁 (5s超时)"
fi

test_start "release_lock_enhanced: 释放已获取的锁"
if acquire_lock_with_timeout 5; then
    if release_lock_enhanced; then
        test_pass
    else
        test_fail "释放增强锁失败"
    fi
else
    test_fail "无法获取增强锁"
fi

test_start "release_lock_enhanced: 双重释放安全"
if acquire_lock_with_timeout 5; then
    release_lock_enhanced
    release_lock_enhanced  # 第二次释放应安全
    test_pass
else
    test_fail "无法获取增强锁"
fi

test_start "check_lock_status: 未锁定时返回 unlocked"
status=$(check_lock_status)
if [[ "$status" == "unlocked" ]]; then
    test_pass
else
    test_fail "未锁定时应返回 unlocked，实际: $status"
fi

test_start "check_lock_status: 锁定后返回 locked"
if acquire_lock_with_timeout 5; then
    status=$(check_lock_status)
    if [[ "$status" == locked* ]]; then
        test_pass
        release_lock_enhanced
    else
        test_fail "锁定后应返回 locked*，实际: $status"
        release_lock_enhanced
    fi
else
    test_fail "无法获取增强锁"
fi

# ============================================================
# 用户级锁测试
# ============================================================

test_suite_start "Lock Core - User-Level Lock"

test_start "acquire_user_lock: 获取用户锁成功"
if acquire_user_lock "testuser_lock" 5; then
    test_pass
    release_user_lock "testuser_lock"
else
    test_fail "无法获取用户锁"
fi

test_start "release_user_lock: 释放用户锁成功"
if acquire_user_lock "testuser_lock2" 5; then
    release_user_lock "testuser_lock2"
    test_pass
else
    test_fail "无法获取用户锁"
fi

test_start "acquire_user_lock: 重复获取同一用户锁应失败"
if acquire_user_lock "testuser_dup" 5; then
    if acquire_user_lock "testuser_dup" 1 2>/dev/null; then
        test_fail "重复获取同一用户锁不应该成功"
        release_user_lock "testuser_dup"
    else
        test_pass
        release_user_lock "testuser_dup"
    fi
else
    test_fail "首次获取用户锁失败"
fi

# ============================================================
# 操作级锁测试
# ============================================================

test_suite_start "Lock Core - Operation Lock"

test_start "acquire_operation_lock: 获取操作锁成功"
if acquire_operation_lock "backup_test" 5; then
    test_pass
    release_operation_lock "backup_test"
else
    test_fail "无法获取操作锁"
fi

test_start "release_operation_lock: 释放操作锁成功"
if acquire_operation_lock "maintenance_test" 5; then
    release_operation_lock "maintenance_test"
    test_pass
else
    test_fail "无法获取操作锁"
fi

test_start "acquire_operation_lock: 不同操作锁互不干扰"
if acquire_operation_lock "op1" 5; then
    if acquire_operation_lock "op2" 5; then
        test_pass
        release_operation_lock "op1"
        release_operation_lock "op2"
    else
        test_fail "不同操作锁应该互不干扰"
        release_operation_lock "op1"
    fi
else
    test_fail "无法获取第一个操作锁"
fi

# ============================================================
# 读写锁测试
# ============================================================

test_suite_start "Lock Core - Read-Write Lock"

test_start "acquire_user_read_lock: 获取读锁成功"
if acquire_user_read_lock "rwuser" 5; then
    test_pass
    release_user_read_lock "rwuser"
else
    test_fail "无法获取用户读锁"
fi

test_start "release_user_read_lock: 释放读锁成功"
if acquire_user_read_lock "rwuser2" 5; then
    release_user_read_lock "rwuser2"
    test_pass
else
    test_fail "无法获取用户读锁"
fi

test_start "acquire_user_write_lock: 获取写锁成功"
if acquire_user_write_lock "wuser" 5; then
    test_pass
    release_user_write_lock "wuser"
else
    test_fail "无法获取用户写锁"
fi

test_start "release_user_write_lock: 释放写锁成功"
if acquire_user_write_lock "wuser2" 5; then
    release_user_write_lock "wuser2"
    test_pass
else
    test_fail "无法获取用户写锁"
fi

test_start "acquire_user_write_lock: 有读锁时写锁应阻塞"
if acquire_user_read_lock "rwtest" 5; then
    if acquire_user_write_lock "rwtest" 1 2>/dev/null; then
        test_fail "有读锁时不应能获取写锁"
        release_user_write_lock "rwtest"
        release_user_read_lock "rwtest"
    else
        test_pass
        release_user_read_lock "rwtest"
    fi
else
    test_fail "无法获取读锁"
fi

# ============================================================
# 锁暂停/恢复测试
# ============================================================

test_suite_start "Lock Core - Suspend/Resume"

test_start "suspend_lock_for_input: 暂停锁成功"
if acquire_user_lock "suspend_test" 5; then
    if suspend_lock_for_input "suspend_test"; then
        test_pass
        resume_lock_after_input "suspend_test"
    else
        test_fail "暂停锁失败"
    fi
    release_user_lock "suspend_test"
else
    test_fail "无法获取用户锁"
fi

test_start "is_lock_suspended: 暂停后检测正确"
if acquire_user_lock "suspend_test2" 5; then
    suspend_lock_for_input "suspend_test2" 2>/dev/null || true
    if is_lock_suspended "suspend_test2"; then
        test_pass
    else
        test_fail "应检测到锁处于暂停状态"
    fi
    resume_lock_after_input "suspend_test2"
    release_user_lock "suspend_test2"
else
    test_fail "无法获取用户锁"
fi

test_start "resume_lock_after_input: 恢复后不再暂停"
if acquire_user_lock "resume_test" 5; then
    suspend_lock_for_input "resume_test" 2>/dev/null || true
    resume_lock_after_input "resume_test"
    if ! is_lock_suspended "resume_test"; then
        test_pass
    else
        test_fail "恢复后不应处于暂停状态"
    fi
    release_user_lock "resume_test"
else
    test_fail "无法获取用户锁"
fi

# ============================================================
# 清理
# ============================================================

# 确保清理所有残留锁
rm -rf /tmp/user_manager_locks 2>/dev/null || true
rm -rf /tmp/user_manager_*.lock 2>/dev/null || true

test_suite_end
