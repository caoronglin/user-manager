# User Manager Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first-stage optimization skeleton for user-manager: shared environment detection, shared action registry, unified log service/presenter, and TUI/CLI log entry migration while keeping `./run.sh` and `./run.sh --no-tui` usable.

**Architecture:** Keep Bash as the only runtime. Add focused modules under `lib/` and migrate only the logging/systemd timer path first, so later user/audit/backup/network/VM/GPU/email/report actions can reuse the same registry and capability checks. TUI and CLI call the same action IDs; presenters format the same raw log protocol for each mode.

**Tech Stack:** Bash, system commands (`journalctl`, `systemctl`, `tail`, `id`, `getent`), existing shell test framework in `tests/test_framework.sh`, existing regression runner `tests/run_regression.sh`.

---

## File structure

Create these files:

- `lib/env_core.sh` — local machine capability checks. It answers whether a command/capability exists and prints a compact summary. It does not install dependencies or perform business actions.
- `lib/action_registry.sh` — shared action metadata and dispatch. It registers action ID, label, group, handler, required capabilities, supported modes, and risk.
- `lib/logs_core.sh` — raw log data service. It returns a simple text protocol with `__LOGS_META__`, `__LOGS_BODY__`, and `__LOGS_ERROR__` markers.
- `lib/logs_presenter.sh` — CLI/TUI-safe presentation for log actions. It calls `logs_core.sh` and formats capability warnings, empty states, and raw bodies.
- `lib/tui_views_logs.sh` — native TUI log view wrapper. It keeps terminal lifecycle safe and exposes `run_log_viewer` compatibility.
- `tests/test_env_core.sh` — capability detection tests with mocked `PATH` and environment variables.
- `tests/test_action_registry.sh` — action registry metadata, dispatch, missing action, and capability guard tests.
- `tests/test_logs_core.sh` — log protocol tests with mocked `journalctl`, `systemctl`, and local log files.
- `tests/test_logs_presenter.sh` — CLI/TUI formatting and empty-state tests.
- `tests/test_tui_logs_view.sh` — TUI log view wrapper tests without needing an interactive terminal.

Modify these files:

- `lib/bootstrap.sh` — add new modules to the single profile source of truth; remove the need for TUI-specific duplicate loading for migrated modules.
- `tui_manager.sh` — source fewer private modules, load `tui_views_logs.sh`, route log/systemd timer actions through `action_run`, keep compatibility function names used by tests.
- `lib/controller_submenus.sh` — route CLI log/systemd timer entries through `action_run` and `logs_present_cli`.
- `lib/shell_config.sh` — make fish verification explicit.
- `lib/config.sh` — document `load_config` as initialization with side effects.
- `tests/run_regression.sh` — include new P1 tests.
- `tests/test_tui_mainline.sh` — update only the assertions affected by action-based log/systemd timer routing.
- `docs/DEEPWIKI.md` and `README.md` — document new action IDs and TUI/CLI log usage.

Commit after each task. Do not commit `data/password_pools/`, `.superpowers/`, generated logs, or local test artifacts.

---

### Task 1: environment capability core

**Files:**
- Create: `lib/env_core.sh`
- Create: `tests/test_env_core.sh`
- Modify: `tests/run_regression.sh:121-126`

- [ ] **Step 1: Write the failing env core test**

Create `tests/test_env_core.sh`:

```bash
#!/bin/bash
# test_env_core.sh - 本机能力探测测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"

test_suite_start "Environment Core"

test_start "env_has_command detects shell functions"
demo_env_command() { :; }
if env_has_command demo_env_command; then
    test_pass
else
    test_fail "env_has_command did not detect a declared function"
fi

test_start "env_has_command rejects missing commands"
if ! env_has_command definitely_missing_user_manager_command_999; then
    test_pass
else
    test_fail "env_has_command reported a missing command as present"
fi

test_start "env_has_systemd can be forced off for tests"
ENV_FORCE_SYSTEMD=0
if ! env_has_systemd; then
    test_pass
else
    test_fail "env_has_systemd ignored ENV_FORCE_SYSTEMD=0"
fi
unset ENV_FORCE_SYSTEMD

test_start "env_capability_status reports command capability"
output="$(env_capability_status command:demo_env_command)"
assert_contains "$output" "status=ok" "expected command capability to be ok"

test_start "env_capability_status reports missing capability"
output="$(env_capability_status command:definitely_missing_user_manager_command_999 || true)"
if [[ "$output" == *"status=missing"* ]] && [[ "$output" == *"capability=command:definitely_missing_user_manager_command_999"* ]]; then
    test_pass
else
    test_fail "missing capability output was: $output"
fi

test_start "env_capability_summary includes core commands"
summary="$(ENV_FORCE_SYSTEMD=0 env_capability_summary)"
if [[ "$summary" == *"journalctl="* ]] && [[ "$summary" == *"systemctl="* ]] && [[ "$summary" == *"systemd=missing"* ]]; then
    test_pass
else
    test_fail "unexpected capability summary: $summary"
fi

test_suite_end
```

- [ ] **Step 2: Run the env test and verify it fails**

Run:

```bash
bash tests/test_env_core.sh
```

Expected: FAIL or shell error because `lib/env_core.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/env_core.sh`**

Create `lib/env_core.sh`:

```bash
#!/bin/bash
# env_core.sh - 本机环境与依赖探测
# 只做能力判断，不安装依赖，不执行业务动作。

env_has_command() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || return 1
    command -v "$cmd" >/dev/null 2>&1 || declare -F "$cmd" >/dev/null 2>&1
}

env_has_systemd() {
    case "${ENV_FORCE_SYSTEMD:-}" in
        1|true|yes) return 0 ;;
        0|false|no) return 1 ;;
    esac

    env_has_command systemctl || return 1
    [[ -d /run/systemd/system || -d /sys/fs/cgroup/system.slice ]]
}

env_capability_status() {
    local capability="${1:-}"
    local name

    case "$capability" in
        systemd)
            if env_has_systemd; then
                printf '__ENV_CAPABILITY__ capability=systemd status=ok\n'
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=systemd status=missing reason=no-systemd-runtime\n'
            return 1
            ;;
        command:*)
            name="${capability#command:}"
            if env_has_command "$name"; then
                printf '__ENV_CAPABILITY__ capability=%s status=ok\n' "$capability"
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=%s status=missing reason=command-not-found\n' "$capability"
            return 1
            ;;
        journalctl|systemctl|jq|ufw|rsnapshot|nvidia-smi|virsh)
            env_capability_status "command:$capability"
            return $?
            ;;
        root)
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                printf '__ENV_CAPABILITY__ capability=root status=ok\n'
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=root status=missing reason=not-root\n'
            return 1
            ;;
        "")
            printf '__ENV_CAPABILITY__ capability=unknown status=missing reason=empty-capability\n'
            return 1
            ;;
        *)
            printf '__ENV_CAPABILITY__ capability=%s status=unknown reason=not-registered\n' "$capability"
            return 1
            ;;
    esac
}

env_require_capability() {
    local capability
    for capability in "$@"; do
        [[ -n "$capability" && "$capability" != "none" ]] || continue
        env_capability_status "$capability" >/dev/null || return 1
    done
    return 0
}

_env_summary_value() {
    local capability="$1"
    if env_capability_status "$capability" >/dev/null 2>&1; then
        printf 'ok'
    else
        printf 'missing'
    fi
}

env_capability_summary() {
    printf 'journalctl=%s\n' "$(_env_summary_value journalctl)"
    printf 'systemctl=%s\n' "$(_env_summary_value systemctl)"
    printf 'systemd=%s\n' "$(_env_summary_value systemd)"
    printf 'jq=%s\n' "$(_env_summary_value jq)"
    printf 'ufw=%s\n' "$(_env_summary_value ufw)"
    printf 'rsnapshot=%s\n' "$(_env_summary_value rsnapshot)"
    printf 'nvidia-smi=%s\n' "$(_env_summary_value nvidia-smi)"
    printf 'virsh=%s\n' "$(_env_summary_value virsh)"
}
```

- [ ] **Step 4: Run env core test and syntax check**

Run:

```bash
bash -n lib/env_core.sh tests/test_env_core.sh
bash tests/test_env_core.sh
```

Expected: syntax check succeeds and all Environment Core tests pass.

- [ ] **Step 5: Add env test to P1 regression**

Modify `tests/run_regression.sh` inside `run_p1()` after the journalctl test block:

```bash
    run_step "P1 environment core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_env_core.sh"
```

- [ ] **Step 6: Run P1 slice for env core**

Run:

```bash
bash tests/test_env_core.sh
```

Expected: PASS.

- [ ] **Step 7: Commit env core**

Run:

```bash
git add lib/env_core.sh tests/test_env_core.sh tests/run_regression.sh
git commit -m "feat: add environment capability core"
```

---

### Task 2: shared action registry

**Files:**
- Create: `lib/action_registry.sh`
- Create: `tests/test_action_registry.sh`
- Modify: `lib/bootstrap.sh:49-102`
- Modify: `tests/run_regression.sh`

- [ ] **Step 1: Write the failing action registry test**

Create `tests/test_action_registry.sh`:

```bash
#!/bin/bash
# test_action_registry.sh - 共享动作注册与分发测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/action_registry.sh"

test_suite_start "Action Registry"

demo_action_handler() { printf 'demo:%s\n' "${1:-}"; }
demo_other_handler() { printf 'other\n'; }

test_start "action_register stores metadata"
action_registry_reset
action_register "demo.run" "Demo Run" "demo" demo_action_handler "none" "both" "safe"
description="$(action_describe demo.run)"
if [[ "$description" == *"id=demo.run"* ]] && [[ "$description" == *"handler=demo_action_handler"* ]]; then
    test_pass
else
    test_fail "unexpected action description: $description"
fi

test_start "action_exists detects registered action"
if action_exists demo.run; then
    test_pass
else
    test_fail "registered action was not found"
fi

test_start "action_run dispatches handler with arguments"
output="$(action_run demo.run cli hello)"
assert_equals "demo:hello" "$output" "action_run should pass remaining args to handler"

test_start "action_run rejects missing action"
output="$(action_run missing.action cli 2>&1 || true)"
if [[ "$output" == *"未知 action: missing.action"* ]]; then
    test_pass
else
    test_fail "missing action output was: $output"
fi

test_start "action_run rejects unsupported mode"
action_register "demo.tui" "Demo TUI" "demo" demo_other_handler "none" "tui" "safe"
output="$(action_run demo.tui cli 2>&1 || true)"
if [[ "$output" == *"不支持当前模式"* ]]; then
    test_pass
else
    test_fail "unsupported mode output was: $output"
fi

test_start "action_list_by_group prints ids"
ids="$(action_list_by_group demo)"
if [[ "$ids" == *"demo.run"* ]] && [[ "$ids" == *"demo.tui"* ]]; then
    test_pass
else
    test_fail "group list was: $ids"
fi

test_start "action_run checks required capability"
action_register "demo.missing" "Demo Missing" "demo" demo_other_handler "command:definitely_missing_user_manager_command_999" "both" "safe"
output="$(action_run demo.missing cli 2>&1 || true)"
if [[ "$output" == *"缺少能力"* ]]; then
    test_pass
else
    test_fail "capability guard output was: $output"
fi

test_suite_end
```

- [ ] **Step 2: Run the action registry test and verify it fails**

Run:

```bash
bash tests/test_action_registry.sh
```

Expected: FAIL or shell error because `lib/action_registry.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/action_registry.sh`**

Create `lib/action_registry.sh`:

```bash
#!/bin/bash
# action_registry.sh - TUI/CLI 共用动作表与分发器

declare -Ag _ACTION_LABEL=()
declare -Ag _ACTION_GROUP=()
declare -Ag _ACTION_HANDLER=()
declare -Ag _ACTION_REQUIRES=()
declare -Ag _ACTION_MODES=()
declare -Ag _ACTION_RISK=()

action_registry_reset() {
    _ACTION_LABEL=()
    _ACTION_GROUP=()
    _ACTION_HANDLER=()
    _ACTION_REQUIRES=()
    _ACTION_MODES=()
    _ACTION_RISK=()
}

action_register() {
    local id="${1:-}" label="${2:-}" group="${3:-}" handler="${4:-}"
    local requires="${5:-none}" modes="${6:-both}" risk="${7:-safe}"

    if [[ -z "$id" || -z "$label" || -z "$group" || -z "$handler" ]]; then
        printf 'action_register: id/label/group/handler 不能为空\n' >&2
        return 1
    fi

    _ACTION_LABEL["$id"]="$label"
    _ACTION_GROUP["$id"]="$group"
    _ACTION_HANDLER["$id"]="$handler"
    _ACTION_REQUIRES["$id"]="$requires"
    _ACTION_MODES["$id"]="$modes"
    _ACTION_RISK["$id"]="$risk"
}

action_exists() {
    local id="${1:-}"
    [[ -n "$id" && -n "${_ACTION_HANDLER[$id]:-}" ]]
}

action_mode_supported() {
    local id="${1:-}" mode="${2:-cli}" modes
    modes="${_ACTION_MODES[$id]:-both}"
    [[ "$modes" == "both" || "$modes" == "$mode" || "$modes" == *",$mode,"* || "$modes" == "$mode,"* || "$modes" == *",$mode"* ]]
}

action_requirements_met() {
    local id="${1:-}" requires capability
    requires="${_ACTION_REQUIRES[$id]:-none}"
    [[ -n "$requires" && "$requires" != "none" ]] || return 0

    local IFS=','
    for capability in $requires; do
        [[ -n "$capability" && "$capability" != "none" ]] || continue
        if ! env_require_capability "$capability"; then
            printf '缺少能力: %s\n' "$capability" >&2
            return 1
        fi
    done
    return 0
}

action_run() {
    local id="${1:-}" mode="${2:-cli}" handler
    shift 2 || true

    if ! action_exists "$id"; then
        printf '未知 action: %s\n' "$id" >&2
        return 1
    fi

    if ! action_mode_supported "$id" "$mode"; then
        printf 'action 不支持当前模式: %s mode=%s\n' "$id" "$mode" >&2
        return 1
    fi

    action_requirements_met "$id" || return 1

    handler="${_ACTION_HANDLER[$id]}"
    if ! declare -F "$handler" >/dev/null 2>&1; then
        printf 'action handler 不存在: %s -> %s\n' "$id" "$handler" >&2
        return 1
    fi

    "$handler" "$@"
}

action_list_by_group() {
    local group="${1:-}" id
    for id in "${!_ACTION_GROUP[@]}"; do
        [[ "${_ACTION_GROUP[$id]}" == "$group" ]] && printf '%s\n' "$id"
    done | sort
}

action_describe() {
    local id="${1:-}"
    action_exists "$id" || return 1
    printf 'id=%s\n' "$id"
    printf 'label=%s\n' "${_ACTION_LABEL[$id]}"
    printf 'group=%s\n' "${_ACTION_GROUP[$id]}"
    printf 'handler=%s\n' "${_ACTION_HANDLER[$id]}"
    printf 'requires=%s\n' "${_ACTION_REQUIRES[$id]}"
    printf 'modes=%s\n' "${_ACTION_MODES[$id]}"
    printf 'risk=%s\n' "${_ACTION_RISK[$id]}"
}
```

- [ ] **Step 4: Add new modules to bootstrap profiles**

Modify `lib/bootstrap.sh` module arrays.

In the `full)` profile, insert after `config.sh`:

```bash
                "env_core.sh"
                "action_registry.sh"
```

In the `tui)` profile, insert after `config.sh`:

```bash
                "env_core.sh"
                "action_registry.sh"
```

- [ ] **Step 5: Add action registry test to P1 regression**

Modify `tests/run_regression.sh` inside `run_p1()` after the environment core block:

```bash
    run_step "P1 action registry" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_action_registry.sh"
```

- [ ] **Step 6: Run action registry checks**

Run:

```bash
bash -n lib/action_registry.sh tests/test_action_registry.sh lib/bootstrap.sh
bash tests/test_action_registry.sh
bash tests/test_bootstrap_integration.sh
```

Expected: all pass.

- [ ] **Step 7: Commit action registry**

Run:

```bash
git add lib/action_registry.sh lib/bootstrap.sh tests/test_action_registry.sh tests/run_regression.sh
git commit -m "feat: add shared action registry"
```

---

### Task 3: unified log core protocol

**Files:**
- Create: `lib/logs_core.sh`
- Create: `tests/test_logs_core.sh`
- Modify: `lib/bootstrap.sh`
- Modify: `tests/run_regression.sh`

- [ ] **Step 1: Write the failing log core test**

Create `tests/test_logs_core.sh`:

```bash
#!/bin/bash
# test_logs_core.sh - 统一日志读取协议测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/journalctl_core.sh"
source "$PROJECT_ROOT/lib/logs_core.sh"

test_suite_start "Logs Core"

mock_journalctl() {
    case "$*" in
        *"-b 0"*) printf 'current boot line\nssh.service failed at boot\n' ;;
        *"-b -1"*) printf 'previous boot line\n' ;;
        *"-u ssh.service"*) printf 'ssh recent line\n' ;;
        *) printf 'generic journal line\n' ;;
    esac
}

mock_systemctl() {
    if [[ "$*" == *"--failed"* ]]; then
        printf 'UNIT LOAD ACTIVE SUB DESCRIPTION\nssh.service loaded failed failed OpenSSH server\n'
    else
        printf 'systemctl mock\n'
    fi
}

JOURNALCTL_BIN=mock_journalctl
SYSTEMCTL_BIN=mock_systemctl

test_start "logs_get_boot_entries emits metadata and body"
output="$(logs_get_boot_entries --boot 0 --lines 20)"
if [[ "$output" == *"__LOGS_META__ status=ok source=journalctl title=Boot logs"* ]] && [[ "$output" == *"current boot line"* ]]; then
    test_pass
else
    test_fail "boot output was: $output"
fi

test_start "logs_get_failed_units emits failed service body"
output="$(logs_get_failed_units)"
if [[ "$output" == *"source=systemctl"* ]] && [[ "$output" == *"ssh.service"* ]]; then
    test_pass
else
    test_fail "failed units output was: $output"
fi

test_start "logs_get_service_recent normalizes service name"
output="$(logs_get_service_recent ssh --lines 5)"
if [[ "$output" == *"unit=ssh.service"* ]] && [[ "$output" == *"ssh recent line"* ]]; then
    test_pass
else
    test_fail "service recent output was: $output"
fi

test_start "logs_get_service_recent rejects empty unit"
output="$(logs_get_service_recent '' 2>&1 || true)"
if [[ "$output" == *"__LOGS_ERROR__"* ]] && [[ "$output" == *"service unit is required"* ]]; then
    test_pass
else
    test_fail "empty service output was: $output"
fi

test_start "logs_get_boot_error_diff emits summary"
output="$(logs_get_boot_error_diff --lines 20)"
if [[ "$output" == *"title=Boot error diff"* ]] && [[ "$output" == *"new:"* ]]; then
    test_pass
else
    test_fail "diff output was: $output"
fi

test_start "logs_get_system_file_tail reads explicit file"
printf 'one\ntwo\nthree\n' > "$TMP_DIR/system.log"
output="$(logs_get_system_file_tail --file "$TMP_DIR/system.log" --lines 2)"
if [[ "$output" == *"source=file"* ]] && [[ "$output" == *"two"* ]] && [[ "$output" == *"three"* ]]; then
    test_pass
else
    test_fail "file tail output was: $output"
fi

test_start "logs_get_auth_failures falls back to auth file"
printf 'Failed password for alice\nAccepted password for bob\n' > "$TMP_DIR/auth.log"
LOGS_AUTH_LOG="$TMP_DIR/auth.log"
output="$(JOURNALCTL_BIN=definitely_missing_user_manager_command_999 logs_get_auth_failures --lines 5)"
if [[ "$output" == *"Failed password for alice"* ]] && [[ "$output" != *"Accepted password"* ]]; then
    test_pass
else
    test_fail "auth failures output was: $output"
fi

test_suite_end
```

- [ ] **Step 2: Run the log core test and verify it fails**

Run:

```bash
bash tests/test_logs_core.sh
```

Expected: FAIL or shell error because `lib/logs_core.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/logs_core.sh`**

Create `lib/logs_core.sh`:

```bash
#!/bin/bash
# logs_core.sh - 统一日志读取服务
# 输出简单文本协议，presenter 负责格式化。

: "${LOGS_SYSTEM_LOG:=${SYSTEM_LOG:-./logs/system.log}}"
: "${LOGS_AUTH_LOG:=/var/log/auth.log}"

logs_meta() {
    printf '__LOGS_META__ status=%s source=%s title=%s' "$1" "$2" "$3"
    shift 3
    local pair
    for pair in "$@"; do
        printf ' %s' "$pair"
    done
    printf '\n'
}

logs_body_marker() { printf '__LOGS_BODY__\n'; }

logs_error() {
    local code="${1:-error}" message="${2:-unknown error}"
    printf '__LOGS_META__ status=error source=none title=Log error\n'
    printf '__LOGS_ERROR__ code=%s message=%s\n' "$code" "$message"
    return 1
}

_logs_arg_value() {
    local name="$1"
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "$name" ]]; then
            printf '%s\n' "${2:-}"
            return 0
        fi
        shift
    done
    return 1
}

_logs_tail_file() {
    local file="$1" lines="${2:-80}"
    [[ -f "$file" ]] || return 1
    tail -n "$lines" "$file" 2>/dev/null
}

logs_get_capability_status() {
    logs_meta ok env "Log capabilities"
    logs_body_marker
    env_capability_summary
}

logs_get_boot_entries() {
    local boot_ref lines
    boot_ref="$(_logs_arg_value --boot "$@" || printf '0')"
    lines="$(_logs_arg_value --lines "$@" || printf '100')"

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    logs_meta ok journalctl "Boot logs" "boot=$boot_ref" "lines=$lines"
    logs_body_marker
    "$JOURNALCTL_BIN" -b "$boot_ref" -n "$lines" --no-pager -o short-iso 2>&1
}

logs_get_failed_units() {
    if ! env_has_command "$SYSTEMCTL_BIN"; then
        logs_error missing-systemctl "systemctl is not available"
        return 1
    fi

    logs_meta ok systemctl "Failed systemd units"
    logs_body_marker
    "$SYSTEMCTL_BIN" --failed --type=service --no-pager --plain 2>&1
}

logs_get_service_recent() {
    local unit="${1:-}" lines normalized_unit
    shift || true
    lines="$(_logs_arg_value --lines "$@" || printf '80')"

    normalized_unit="$(journalctl_normalize_unit_name "$unit")" || {
        logs_error invalid-input "service unit is required"
        return 1
    }

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    logs_meta ok journalctl "Service recent logs" "unit=$normalized_unit" "lines=$lines"
    logs_body_marker
    "$JOURNALCTL_BIN" -u "$normalized_unit" -n "$lines" --no-pager -o short-iso 2>&1
}

logs_get_boot_error_diff() {
    local lines current_errors previous_errors summary
    lines="$(_logs_arg_value --lines "$@" || printf '100')"

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    current_errors="$(journalctl_collect_boot_errors 0 "$lines")" || current_errors=""
    previous_errors="$(journalctl_collect_boot_errors -1 "$lines")" || previous_errors=""
    summary="$(journalctl_summarize_error_diff "$current_errors" "$previous_errors")" || return 1

    logs_meta ok journalctl "Boot error diff" "lines=$lines"
    logs_body_marker
    printf '%s\n' "$summary"
}

logs_get_system_file_tail() {
    local file lines candidate
    file="$(_logs_arg_value --file "$@" || printf '%s' "$LOGS_SYSTEM_LOG")"
    lines="$(_logs_arg_value --lines "$@" || printf '120')"

    for candidate in "$file" /var/log/syslog /var/log/messages /var/log/kern.log "${SYSTEM_LOG:-}"; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            logs_meta ok file "System log file" "file=$candidate" "lines=$lines"
            logs_body_marker
            _logs_tail_file "$candidate" "$lines"
            return 0
        fi
    done

    logs_meta empty file "System log file" "reason=no-readable-log-file"
    logs_body_marker
    printf '没有找到可读取的系统日志文件。\n'
}

logs_get_auth_failures() {
    local lines candidate
    lines="$(_logs_arg_value --lines "$@" || printf '50')"

    if env_has_command "$JOURNALCTL_BIN"; then
        logs_meta ok journalctl "Authentication failures" "lines=$lines"
        logs_body_marker
        "$JOURNALCTL_BIN" -u ssh -u sshd -n "$lines" --no-pager -o short-iso 2>/dev/null | grep -Ei 'failed|failure|invalid|authentication' || true
        return 0
    fi

    for candidate in "$LOGS_AUTH_LOG" /var/log/auth.log /var/log/secure "${LOG_DIR:-./logs}/security.log"; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            logs_meta ok file "Authentication failures" "file=$candidate" "lines=$lines"
            logs_body_marker
            grep -Ei 'failed|failure|invalid|authentication' "$candidate" | tail -n "$lines" || true
            return 0
        fi
    done

    logs_meta empty file "Authentication failures" "reason=no-auth-log"
    logs_body_marker
    printf '没有找到可读取的认证失败日志。\n'
}
```

- [ ] **Step 4: Add `logs_core.sh` to bootstrap profiles**

Modify `lib/bootstrap.sh`.

In `full)` after `system_core.sh`, add:

```bash
                "logs_core.sh"
```

In `tui)` after `tui_core.sh`, add:

```bash
                "journalctl_core.sh"
                "systemd_timer_core.sh"
                "logs_core.sh"
```

- [ ] **Step 5: Add logs core test to P1 regression**

Modify `tests/run_regression.sh` after action registry block:

```bash
    run_step "P1 logs core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_logs_core.sh"
```

- [ ] **Step 6: Run log core checks**

Run:

```bash
bash -n lib/logs_core.sh tests/test_logs_core.sh lib/bootstrap.sh
bash tests/test_logs_core.sh
bash tests/test_bootstrap_integration.sh
```

Expected: all pass.

- [ ] **Step 7: Commit log core**

Run:

```bash
git add lib/logs_core.sh lib/bootstrap.sh tests/test_logs_core.sh tests/run_regression.sh
git commit -m "feat: add unified logs core"
```

---

### Task 4: log presenter and registered log actions

**Files:**
- Create: `lib/logs_presenter.sh`
- Create: `tests/test_logs_presenter.sh`
- Modify: `lib/action_registry.sh`
- Modify: `lib/bootstrap.sh`
- Modify: `tests/run_regression.sh`

- [ ] **Step 1: Write the failing presenter test**

Create `tests/test_logs_presenter.sh`:

```bash
#!/bin/bash
# test_logs_presenter.sh - 日志展示层测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/journalctl_core.sh"
source "$PROJECT_ROOT/lib/logs_core.sh"
source "$PROJECT_ROOT/lib/logs_presenter.sh"

test_suite_start "Logs Presenter"

mock_journalctl() { printf 'journal body\n'; }
mock_systemctl() { printf 'UNIT LOAD ACTIVE SUB DESCRIPTION\nssh.service loaded failed failed OpenSSH server\n'; }
JOURNALCTL_BIN=mock_journalctl
SYSTEMCTL_BIN=mock_systemctl

test_start "logs_present_cli prints title source and body"
output="$(logs_present_cli logs.boot --boot 0 --lines 5)"
if [[ "$output" == *"Boot logs"* ]] && [[ "$output" == *"source=journalctl"* ]] && [[ "$output" == *"journal body"* ]]; then
    test_pass
else
    test_fail "CLI presenter output was: $output"
fi

test_start "logs_present_cli handles service argument"
output="$(logs_present_cli logs.service_recent ssh --lines 5)"
if [[ "$output" == *"Service recent logs"* ]] && [[ "$output" == *"journal body"* ]]; then
    test_pass
else
    test_fail "service presenter output was: $output"
fi

test_start "logs_present_cli reports unknown log action"
output="$(logs_present_cli logs.unknown 2>&1 || true)"
if [[ "$output" == *"未知日志 action"* ]]; then
    test_pass
else
    test_fail "unknown action output was: $output"
fi

test_start "logs_present_tui returns text without terminal control"
output="$(logs_present_tui logs.failed_services)"
if [[ "$output" == *"Failed systemd units"* ]] && [[ "$output" == *"ssh.service"* ]]; then
    test_pass
else
    test_fail "TUI presenter output was: $output"
fi

test_start "logs_format_empty_state is readable"
output="$(logs_format_empty_state no-data)"
if [[ "$output" == *"没有可显示的日志"* ]] && [[ "$output" == *"no-data"* ]]; then
    test_pass
else
    test_fail "empty state output was: $output"
fi

test_suite_end
```

- [ ] **Step 2: Run the presenter test and verify it fails**

Run:

```bash
bash tests/test_logs_presenter.sh
```

Expected: FAIL or shell error because `lib/logs_presenter.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/logs_presenter.sh`**

Create `lib/logs_presenter.sh`:

```bash
#!/bin/bash
# logs_presenter.sh - CLI/TUI 日志展示适配

logs_format_empty_state() {
    local reason="${1:-empty}"
    printf '没有可显示的日志。reason=%s\n' "$reason"
}

logs_format_capability_warning() {
    local capability="${1:-unknown}"
    printf '当前环境缺少能力: %s。请安装依赖、切换到支持的系统，或使用可读取的日志文件。\n' "$capability"
}

_logs_presenter_call_core() {
    local action_id="${1:-}"
    shift || true
    case "$action_id" in
        logs.boot) logs_get_boot_entries "$@" ;;
        logs.failed_services) logs_get_failed_units "$@" ;;
        logs.service_recent) logs_get_service_recent "$@" ;;
        logs.boot_error_diff) logs_get_boot_error_diff "$@" ;;
        logs.system_file_tail) logs_get_system_file_tail "$@" ;;
        logs.auth_failures) logs_get_auth_failures "$@" ;;
        logs.capabilities) logs_get_capability_status "$@" ;;
        *)
            printf '未知日志 action: %s\n' "$action_id" >&2
            return 1
            ;;
    esac
}

_logs_presenter_print() {
    local raw="$1" mode="${2:-cli}" meta body error status source title
    meta="$(printf '%s\n' "$raw" | awk '/^__LOGS_META__/ { sub(/^__LOGS_META__ /, ""); print; exit }')"
    body="$(printf '%s\n' "$raw" | awk 'found { print } /^__LOGS_BODY__$/ { found=1; next }')"
    error="$(printf '%s\n' "$raw" | awk '/^__LOGS_ERROR__/ { sub(/^__LOGS_ERROR__ /, ""); print; exit }')"

    status="$(printf '%s\n' "$meta" | tr ' ' '\n' | awk -F= '$1=="status" { print $2; exit }')"
    source="$(printf '%s\n' "$meta" | tr ' ' '\n' | awk -F= '$1=="source" { print $2; exit }')"
    title="$(printf '%s\n' "$meta" | sed -n 's/.*title=//p' | sed 's/ [a-zA-Z0-9_.-]*=.*$//')"

    [[ -n "$title" ]] || title="Logs"
    [[ -n "$status" ]] || status="unknown"
    [[ -n "$source" ]] || source="unknown"

    if [[ "$mode" == "cli" ]]; then
        printf '\n== %s ==\n' "$title"
        printf 'status=%s source=%s\n' "$status" "$source"
        [[ -z "$error" ]] || printf '%s\n' "$error"
        if [[ -n "$body" ]]; then
            printf '%s\n' "$body"
        else
            logs_format_empty_state "$status"
        fi
        return 0
    fi

    printf '%s\n' "$title"
    printf 'status=%s source=%s\n' "$status" "$source"
    [[ -z "$error" ]] || printf '%s\n' "$error"
    if [[ -n "$body" ]]; then
        printf '%s\n' "$body"
    else
        logs_format_empty_state "$status"
    fi
}

logs_present_cli() {
    local action_id="${1:-}" raw rc
    shift || true
    raw="$(_logs_presenter_call_core "$action_id" "$@")"
    rc=$?
    _logs_presenter_print "$raw" cli
    return $rc
}

logs_present_tui() {
    local action_id="${1:-}" raw rc
    shift || true
    raw="$(_logs_presenter_call_core "$action_id" "$@")"
    rc=$?
    _logs_presenter_print "$raw" tui
    return $rc
}

logs_action_cli() {
    local action_id="${1:-}"
    shift || true
    logs_present_cli "$action_id" "$@"
}

logs_action_tui() {
    local action_id="${1:-}"
    shift || true
    logs_present_tui "$action_id" "$@"
}
```

- [ ] **Step 4: Register first-stage actions**

Append to `lib/action_registry.sh`:

```bash
action_register_defaults() {
    action_register "logs.boot" "查看 Boot 日志" "logs" logs_action_cli "journalctl" "both" "safe"
    action_register "logs.failed_services" "列出失败服务" "logs" logs_action_cli "systemctl" "both" "safe"
    action_register "logs.service_recent" "查看服务近期日志" "logs" logs_action_cli "journalctl" "both" "safe"
    action_register "logs.boot_error_diff" "启动错误对比" "logs" logs_action_cli "journalctl" "both" "safe"
    action_register "logs.system_file_tail" "查看系统日志文件" "logs" logs_action_cli "none" "both" "safe"
    action_register "logs.auth_failures" "查看认证失败" "logs" logs_action_cli "none" "both" "safe"
    action_register "system.timers.list" "列出 systemd timers" "system" systemd_timer_list_timers "systemctl" "both" "safe"
    action_register "system.timers.logs" "查看 timer 日志" "system" systemd_timer_show_logs "journalctl" "both" "safe"
    action_register "users.list" "查看托管用户" "users" list_managed_users "none" "both" "safe"
    action_register "audit.view" "查看审计日志" "audit" view_audit_log "none" "both" "safe"
}

action_register_defaults_once() {
    if [[ "${ACTION_DEFAULTS_REGISTERED:-0}" == "1" ]]; then
        return 0
    fi
    ACTION_DEFAULTS_REGISTERED=1
    action_register_defaults
}
```

Then call `action_register_defaults_once` from entry scripts after all handlers are loaded, not from the module body. This avoids registering handlers before functions exist.

- [ ] **Step 5: Add presenter to bootstrap profiles**

Modify `lib/bootstrap.sh`.

In `full)` after `logs_core.sh`, add:

```bash
                "logs_presenter.sh"
```

In `tui)` after `logs_core.sh`, add:

```bash
                "logs_presenter.sh"
```

- [ ] **Step 6: Add presenter test to P1 regression**

Modify `tests/run_regression.sh` after logs core block:

```bash
    run_step "P1 logs presenter" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_logs_presenter.sh"
```

- [ ] **Step 7: Run presenter checks**

Run:

```bash
bash -n lib/logs_presenter.sh lib/action_registry.sh tests/test_logs_presenter.sh
bash tests/test_logs_presenter.sh
bash tests/test_action_registry.sh
```

Expected: all pass. If `test_action_registry.sh` fails because default registrations reference missing handlers, move default registration calls out of module load and keep only function definitions in `action_registry.sh`.

- [ ] **Step 8: Commit presenter and action metadata**

Run:

```bash
git add lib/logs_presenter.sh lib/action_registry.sh lib/bootstrap.sh tests/test_logs_presenter.sh tests/run_regression.sh
git commit -m "feat: add log presenter actions"
```

---

### Task 5: CLI log and timer routing

**Files:**
- Modify: `lib/controller_submenus.sh:412-447,602-614`
- Modify: `user_manager.sh`
- Modify: `tests/test_action_registry.sh`

- [ ] **Step 1: Add a CLI route test to action registry tests**

Append before `test_suite_end` in `tests/test_action_registry.sh`:

```bash
test_start "default log action can be registered and called"
action_registry_reset
logs_action_cli() { printf 'logs-action:%s:%s\n' "$1" "${2:-}"; }
action_register_defaults
output="$(action_run logs.boot cli logs.boot --boot 0)"
if [[ "$output" == "logs-action:logs.boot:--boot" ]]; then
    test_pass
else
    test_fail "default action output was: $output"
fi
```

- [ ] **Step 2: Run the updated test and verify it fails if defaults are not wired**

Run:

```bash
bash tests/test_action_registry.sh
```

Expected: PASS if Task 4 registration is correct; otherwise FAIL showing the default action wiring issue.

- [ ] **Step 3: Ensure CLI entry registers default actions**

Modify `user_manager.sh` after all controller/core modules are loaded and before `controller_start`:

```bash
if declare -F action_register_defaults_once >/dev/null 2>&1; then
    action_register_defaults_once
fi
```

- [ ] **Step 4: Route system log CLI entries through actions**

Modify `_handle_system()` in `lib/controller_submenus.sh` cases 16-19:

```bash
        16)
            read_input "boot 引用 (0=当前, -1=上次)" "0"; local boot_ref="$REPLY_INPUT"
            read_input "最近日志行数" "100"; local lines="$REPLY_INPUT"
            action_run logs.boot cli logs.boot --boot "${boot_ref:-0}" --lines "${lines:-100}"
            ;;
        17) action_run logs.failed_services cli logs.failed_services ;;
        18)
            read_input "服务名 (如 ssh / docker.service)"; local unit="$REPLY_INPUT"
            read_input "最近日志行数" "80"; local lines="$REPLY_INPUT"
            [[ -n "$unit" ]] && action_run logs.service_recent cli logs.service_recent "$unit" --lines "${lines:-80}"
            ;;
        19)
            read_input "对比最近 err..alert 日志条数" "100"; local lines="$REPLY_INPUT"
            action_run logs.boot_error_diff cli logs.boot_error_diff --lines "${lines:-100}"
            ;;
```

- [ ] **Step 5: Route CLI timer list/log entries through actions**

Modify `_handle_systemd_timers()` in `lib/controller_submenus.sh` cases 1 and 3:

```bash
        1) action_run system.timers.list cli ;;
```

and:

```bash
        3)
            read_input "timer 名称" "weekly-report"; local timer_name="$REPLY_INPUT"
            read_input "最近日志行数" "50"; local lines="$REPLY_INPUT"
            action_run system.timers.logs cli "${timer_name:-weekly-report}" "${lines:-50}"
            ;;
```

Keep install/remove cases unchanged for now.

- [ ] **Step 6: Run CLI routing checks**

Run:

```bash
bash -n user_manager.sh lib/controller_submenus.sh
bash tests/test_action_registry.sh
bash tests/test_journalctl_core.sh
bash tests/test_systemd_timer_core.sh
```

Expected: all pass.

- [ ] **Step 7: Commit CLI routing**

Run:

```bash
git add user_manager.sh lib/controller_submenus.sh tests/test_action_registry.sh
git commit -m "feat: route cli log actions"
```

---

### Task 6: native TUI log view and routing

**Files:**
- Create: `lib/tui_views_logs.sh`
- Create: `tests/test_tui_logs_view.sh`
- Modify: `tui_manager.sh`
- Modify: `tests/run_regression.sh`
- Modify: `tests/test_tui_mainline.sh`

- [ ] **Step 1: Write the failing TUI log view test**

Create `tests/test_tui_logs_view.sh`:

```bash
#!/bin/bash
# test_tui_logs_view.sh - 原生日志 TUI 视图测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/tui_views_logs.sh"

test_suite_start "TUI Logs View"

test_start "tui_logs_render_text prints title body and controls"
output="$(tui_logs_render_text "Boot logs" $'line1\nline2' 0 20)"
if [[ "$output" == *"Boot logs"* ]] && [[ "$output" == *"line1"* ]] && [[ "$output" == *"q 返回"* ]]; then
    test_pass
else
    test_fail "render output was: $output"
fi

test_start "tui_logs_open_action uses logs_present_tui"
logs_present_tui() { printf 'Rendered Action\nstatus=ok source=test\nbody\n'; }
tui_logs_render_text() { printf 'rendered:%s:%s\n' "$1" "$2"; }
output="$(tui_logs_open_action logs.boot --boot 0)"
if [[ "$output" == *"rendered:logs.boot"* ]] && [[ "$output" == *"Rendered Action"* ]]; then
    test_pass
else
    test_fail "open action output was: $output"
fi

test_start "run_log_viewer remains as compatibility wrapper"
logs_present_tui() { printf 'System log file\nstatus=ok source=file\nbody\n'; }
tui_logs_render_text() { printf 'compat:%s\n' "$1"; }
output="$(run_log_viewer)"
assert_contains "$output" "compat:logs.system_file_tail" "run_log_viewer should call logs.system_file_tail"

test_suite_end
```

- [ ] **Step 2: Run the TUI log view test and verify it fails**

Run:

```bash
bash tests/test_tui_logs_view.sh
```

Expected: FAIL or shell error because `lib/tui_views_logs.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/tui_views_logs.sh`**

Create `lib/tui_views_logs.sh`:

```bash
#!/bin/bash
# tui_views_logs.sh - 原生日志视图

tui_logs_render_text() {
    local title="${1:-Logs}" body="${2:-}" scroll_offset="${3:-0}" max_rows="${4:-20}"

    if declare -F tui_clear >/dev/null 2>&1; then
        tui_clear
        tui_draw_center 1 "$title" "${TUI_COLOR_ACCENT:-2}"
        printf '%s\n' "$body" | sed -n "$((scroll_offset + 1)),$((scroll_offset + max_rows))p"
        if declare -F tui_statusbar_draw >/dev/null 2>&1; then
            tui_statusbar_draw "${TUI_LINES:-24}" "$title" "↑/↓ 滚动  r 刷新  q 返回"
        fi
        return 0
    fi

    printf '== %s ==\n' "$title"
    printf '%s\n' "$body" | sed -n "$((scroll_offset + 1)),$((scroll_offset + max_rows))p"
    printf 'q 返回 / r 刷新\n'
}

tui_logs_open_action() {
    local action_id="${1:-logs.system_file_tail}" output
    shift || true
    output="$(logs_present_tui "$action_id" "$@")" || true
    tui_logs_render_text "$action_id" "$output" 0 "$(( ${TUI_LINES:-24} - 6 ))"
}

run_log_viewer() {
    tui_logs_open_action logs.system_file_tail --lines 120
}
```

- [ ] **Step 4: Load TUI log view and register actions in TUI entry**

Modify `tui_manager.sh`:

1. Remove `journalctl_core.sh`, `systemd_timer_core.sh`, `logs_core.sh`, and `logs_presenter.sh` from `_tui_load_mainline_modules` if they are loaded by `um_load_profile tui` after Task 4.
2. Add after `source "$LIB_DIR/tui_menus.sh"`:

```bash
# shellcheck disable=SC1091
source "$LIB_DIR/tui_views_logs.sh"

if declare -F action_register_defaults_once >/dev/null 2>&1; then
    action_register_defaults_once
fi
```

- [ ] **Step 5: Route TUI system detail log entries through log view**

Modify `handle_tui_system_details_menu_key()` in `tui_manager.sh` for the log-related cases:

```bash
        5) tui_logs_open_action logs.boot --boot 0 --lines 100 ;;
        6) tui_logs_open_action logs.failed_services ;;
        7)
            if tui_prompt_input "服务日志" "服务名 (如 ssh / docker.service)" "ssh"; then
                tui_logs_open_action logs.service_recent "$REPLY_INPUT" --lines 80
            fi
            ;;
        8) tui_logs_open_action logs.boot_error_diff --lines 100 ;;
```

Keep non-log cases unchanged.

- [ ] **Step 6: Route TUI timer list/log actions through action registry**

Add this helper near `tui_run_workflow_action()` in `tui_manager.sh`:

```bash
tui_run_action() {
    local action_id="$1"
    shift || true
    tui_cleanup
    action_run "$action_id" tui "$@"
    local rc=$?
    tui_init
    return $rc
}
```

Then modify `handle_tui_systemd_timer_menu_key()` in `tui_manager.sh` so the list case uses the shared action dispatcher:

```bash
        0) tui_run_action system.timers.list ;;
```

For timer logs case, prompt for timer and lines, then:

```bash
                tui_run_action system.timers.logs "${timer_name:-weekly-report}" "${lines:-50}"
```

- [ ] **Step 7: Add TUI log test to P1 regression**

Modify `tests/run_regression.sh` after logs presenter block:

```bash
    run_step "P1 TUI logs view" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_tui_logs_view.sh"
```

- [ ] **Step 8: Update mainline test only where behavior changed**

In `tests/test_tui_mainline.sh`, keep existing function-existence checks. For the timer action test at lines 323-329, update expected output if it now goes through `action_run`:

```bash
timer_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { echo 0; }; tui_cleanup() { printf "cleanup\n"; }; tui_init() { printf "init\n"; }; action_run() { printf "action:%s:%s\n" "$1" "$2"; }; handle_tui_systemd_timer_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$timer_action_output" == $'cleanup\naction:system.timers.list:tui\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI Timers 菜单未通过 action 执行，输出为: $timer_action_output"
fi
```

- [ ] **Step 9: Run TUI checks**

Run:

```bash
bash -n lib/tui_views_logs.sh tui_manager.sh tests/test_tui_logs_view.sh tests/test_tui_mainline.sh
bash tests/test_tui_logs_view.sh
bash tests/test_tui_mainline.sh
```

Expected: all pass.

- [ ] **Step 10: Commit TUI log view**

Run:

```bash
git add lib/tui_views_logs.sh tui_manager.sh tests/test_tui_logs_view.sh tests/test_tui_mainline.sh tests/run_regression.sh
git commit -m "feat: add native tui log view"
```

---

### Task 7: shell/config cleanup and fish verification

**Files:**
- Modify: `lib/config.sh:87-107`
- Modify: `lib/shell_config.sh:210-223`
- Create: `tests/test_shell_config_core.sh`
- Modify: `tests/run_regression.sh`

- [ ] **Step 1: Write the failing shell config test**

Create `tests/test_shell_config_core.sh`:

```bash
#!/bin/bash
# test_shell_config_core.sh - shell 配置验证测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$SCRIPT_DIR/test_framework.sh"
SCRIPT_DIR="$PROJECT_ROOT"
source "$PROJECT_ROOT/lib/shell_config.sh"

test_suite_start "Shell Config Core"

id() { [[ "${1:-}" == "fishuser" || "${1:-}" == "bashuser" ]]; }
getent() {
    if [[ "${1:-}" == "passwd" && "${2:-}" == "fishuser" ]]; then
        printf 'fishuser:x:1001:1001::%s:/usr/bin/fish\n' "$TMP_DIR/fishuser"
        return 0
    fi
    if [[ "${1:-}" == "passwd" && "${2:-}" == "bashuser" ]]; then
        printf 'bashuser:x:1002:1002::%s:/bin/bash\n' "$TMP_DIR/bashuser"
        return 0
    fi
    return 1
}

mkdir -p "$TMP_DIR/fishuser/.config/fish" "$TMP_DIR/bashuser"
touch "$TMP_DIR/fishuser/.config/fish/config.fish"
touch "$TMP_DIR/bashuser/.bashrc"

test_start "verify_shell_config accepts fish config"
if verify_shell_config fishuser; then
    test_pass
else
    test_fail "fish config was not accepted"
fi

test_start "verify_shell_config accepts bash config"
if verify_shell_config bashuser; then
    test_pass
else
    test_fail "bash config was not accepted"
fi

test_suite_end
```

- [ ] **Step 2: Run the shell config test and verify fish fails**

Run:

```bash
bash tests/test_shell_config_core.sh
```

Expected: FAIL for fish until `verify_shell_config` is fixed.

- [ ] **Step 3: Fix fish verification**

Replace `verify_shell_config()` in `lib/shell_config.sh` with:

```bash
verify_shell_config() {
    local username="$1"

    if ! id "$username" &>/dev/null; then
        return 1
    fi

    local user_home
    user_home=$(getent passwd "$username" | cut -d: -f6)
    [[ -n "$user_home" ]] || return 1

    [[ -f "$user_home/.bashrc" ]] \
        || [[ -f "$user_home/.zshrc" ]] \
        || [[ -f "$user_home/.config/fish/config.fish" ]]
}
```

- [ ] **Step 4: Document config initialization side effects**

In `lib/config.sh`, add this comment immediately above `load_config()`:

```bash
# load_config 是入口初始化步骤，不是纯读取函数。
# 它会创建项目本地目录、初始化日志头、检查敏感文件权限，
# 并按配置清理旧密码池。调用方应在程序启动早期执行一次。
```

- [ ] **Step 5: Add shell config test to P1 regression**

Modify `tests/run_regression.sh` after environment core block or near bootstrap tests:

```bash
    run_step "P1 shell config core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_shell_config_core.sh"
```

- [ ] **Step 6: Run shell/config checks**

Run:

```bash
bash -n lib/config.sh lib/shell_config.sh tests/test_shell_config_core.sh
bash tests/test_shell_config_core.sh
```

Expected: all pass.

- [ ] **Step 7: Commit shell/config cleanup**

Run:

```bash
git add lib/config.sh lib/shell_config.sh tests/test_shell_config_core.sh tests/run_regression.sh
git commit -m "fix: verify fish shell config"
```

---

### Task 8: documentation and migration notes

**Files:**
- Modify: `README.md`
- Modify: `docs/DEEPWIKI.md`

- [ ] **Step 1: Update README usage section**

Add or update a short section in `README.md` after the entrypoint description:

```markdown
## TUI 与无 TUI 模式

- `./run.sh`：进入原生 Bash TUI。
- `./run.sh --no-tui` 或 `./run.sh --cli`：进入无 TUI 菜单。

第一阶段优化后，日志相关能力通过共享 action ID 运行。TUI 和 CLI 使用同一套读取逻辑，只是展示方式不同。

| 能力 | action ID |
|---|---|
| 查看启动日志 | `logs.boot` |
| 列出失败服务 | `logs.failed_services` |
| 查看服务近期日志 | `logs.service_recent` |
| 对比启动错误 | `logs.boot_error_diff` |
| 查看系统日志文件 | `logs.system_file_tail` |
| 查看认证失败 | `logs.auth_failures` |
| 列出 systemd timers | `system.timers.list` |
| 查看 timer 日志 | `system.timers.logs` |

如果当前机器没有 `journalctl` 或 `systemctl`，日志模块会回落到传统日志文件或显示空状态说明，不会自动安装依赖。
```

- [ ] **Step 2: Update DeepWiki architecture note**

Add this section to `docs/DEEPWIKI.md` near the architecture overview:

```markdown
### 第一阶段优化骨架

新增共享层：

- `lib/env_core.sh`：探测本机命令和 systemd 能力。
- `lib/action_registry.sh`：登记 TUI/CLI 共用 action。
- `lib/logs_core.sh`：统一日志读取协议。
- `lib/logs_presenter.sh`：统一 CLI/TUI 日志展示文本。
- `lib/tui_views_logs.sh`：原生日志 TUI 视图。

日志和 systemd timer 是第一批迁移对象。其他业务模块先保留现有实现，后续逐步注册到 action registry，减少 TUI 与 CLI 双写。
```

- [ ] **Step 3: Run docs-sensitive checks**

Run:

```bash
bash scripts/check_sensitive_files.sh .
```

Expected: PASS and no `data/password_pools/` leak.

- [ ] **Step 4: Commit docs**

Run:

```bash
git add README.md docs/DEEPWIKI.md
git commit -m "docs: document action based log flow"
```

---

### Task 9: final verification

**Files:**
- No code changes expected unless verification finds failures.

- [ ] **Step 1: Run syntax checks for touched shell files**

Run:

```bash
bash -n run.sh user_manager.sh tui_manager.sh \
  lib/bootstrap.sh lib/env_core.sh lib/action_registry.sh lib/logs_core.sh \
  lib/logs_presenter.sh lib/tui_views_logs.sh lib/controller_submenus.sh \
  lib/config.sh lib/shell_config.sh \
  tests/test_env_core.sh tests/test_action_registry.sh tests/test_logs_core.sh \
  tests/test_logs_presenter.sh tests/test_tui_logs_view.sh tests/test_shell_config_core.sh
```

Expected: no output and exit code 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
bash tests/test_env_core.sh
bash tests/test_action_registry.sh
bash tests/test_logs_core.sh
bash tests/test_logs_presenter.sh
bash tests/test_tui_logs_view.sh
bash tests/test_shell_config_core.sh
bash tests/test_tui_mainline.sh
bash tests/test_journalctl_core.sh
bash tests/test_systemd_timer_core.sh
```

Expected: all suites pass.

- [ ] **Step 3: Run P1 regression**

Run:

```bash
bash tests/run_regression.sh --level p1
```

Expected: regression summary shows `Failed: 0`.

- [ ] **Step 4: Run sensitive file scan**

Run:

```bash
bash scripts/check_sensitive_files.sh .
```

Expected: no sensitive password pool or local state files are reported.

- [ ] **Step 5: Inspect git status**

Run:

```bash
git status --short --branch
```

Expected: clean working tree after all task commits.

- [ ] **Step 6: Final commit only if verification required fixes**

If Step 1-4 forced small fixes after the docs commit, commit them:

```bash
git add <fixed-files>
git commit -m "fix: stabilize action log integration"
```

If no files changed, do not create an empty commit.

---

## Self-review

Spec coverage:

- Unified loading: Tasks 2-4 update `lib/bootstrap.sh`; Task 6 removes duplicated TUI loading for migrated modules.
- Environment adaptation: Task 1 adds `env_core`; Task 7 fixes fish shell verification and documents config side effects.
- Action layer: Task 2 builds registry; Task 4 registers first-stage log/timer/user/audit examples; Tasks 5-6 route CLI/TUI through actions.
- Logs service and presenter: Tasks 3-4 add `logs_core` and `logs_presenter`; Task 6 adds native TUI log view.
- TUI and no-TUI versions: Tasks 5-6 keep both entry paths and migrate log/timer actions in both.
- Testing and acceptance: Tasks 1-7 add focused P1 tests; Task 9 runs syntax, focused tests, P1 regression, and sensitive scan.
- Documentation: Task 8 documents action IDs, fallback behavior, and new architecture.

Placeholder scan: no forbidden placeholder phrases or open-ended “add tests” steps remain in this plan. Each implementation task includes exact files, code snippets, commands, expected results, and commit commands.

Consistency check:

- Action IDs are consistent across spec and plan: `logs.boot`, `logs.failed_services`, `logs.service_recent`, `logs.boot_error_diff`, `logs.system_file_tail`, `logs.auth_failures`, `system.timers.list`, `system.timers.logs`.
- Core function names are consistent: `env_has_command`, `env_has_systemd`, `env_capability_summary`, `action_register`, `action_run`, `logs_get_*`, `logs_present_cli`, `logs_present_tui`, `tui_logs_open_action`.
- Existing entrypoints remain `./run.sh`, `./run.sh --no-tui`, and `./run.sh --cli`.
