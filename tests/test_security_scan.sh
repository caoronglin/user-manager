#!/bin/bash
# test_security_scan.sh - 敏感文件与密钥扫描测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

init_git_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.name "Test User"
    git -C "$repo_dir" config user.email "test@example.com"
}

stage_file() {
    local repo_dir="$1"
    local file_path="$2"
    local content="$3"

    mkdir -p "$(dirname "$repo_dir/$file_path")"
    printf '%s' "$content" > "$repo_dir/$file_path"
    git -C "$repo_dir" add "$file_path"
}

test_suite_start "Security Scan"

if ! command -v git >/dev/null 2>&1; then
    test_start "check_sensitive_files: 当前环境提供 git"
    test_skip "git 未安装，跳过依赖 git 的安全扫描测试"
    cleanup_test_env
    test_suite_end
    exit 0
fi

test_start "check_sensitive_files: 干净仓库通过"
clean_repo="$TEST_TMPDIR/clean_repo"
init_git_repo "$clean_repo"
stage_file "$clean_repo" "README.md" "safe content\n"
if bash "$PROJECT_ROOT/scripts/check_sensitive_files.sh" "$clean_repo" >/dev/null 2>&1; then
    test_pass
else
    test_fail "干净仓库不应被判定为敏感文件"
fi

test_start "check_sensitive_files: 跟踪 .env 时失败"
env_repo="$TEST_TMPDIR/env_repo"
init_git_repo "$env_repo"
stage_file "$env_repo" ".env" "TOKEN=secret\n"
if ! bash "$PROJECT_ROOT/scripts/check_sensitive_files.sh" "$env_repo" >/dev/null 2>&1; then
    test_pass
else
    test_fail "已跟踪的 .env 应触发失败"
fi

test_start "check_sensitive_files: 私钥内容触发失败"
key_repo="$TEST_TMPDIR/key_repo"
init_git_repo "$key_repo"
stage_file "$key_repo" "config/notes.txt" $'-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----\n'
if ! bash "$PROJECT_ROOT/scripts/check_sensitive_files.sh" "$key_repo" >/dev/null 2>&1; then
    test_pass
else
    test_fail "包含私钥内容的文件应触发失败"
fi

cleanup_test_env

test_suite_end
