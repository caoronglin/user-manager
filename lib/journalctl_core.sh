#!/bin/bash
# journalctl_core.sh - Ubuntu/systemd/journalctl 排障中心

: "${JOURNALCTL_BIN:=journalctl}"
: "${SYSTEMCTL_BIN:=systemctl}"

_journalctl_msg_info() {
    if declare -F msg_info >/dev/null; then
        msg_info "$@"
    else
        printf '%s\n' "$*"
    fi
}

_journalctl_msg_warn() {
    if declare -F msg_warn >/dev/null; then
        msg_warn "$@"
    else
        printf 'WARN: %s\n' "$*"
    fi
}

_journalctl_msg_err() {
    if declare -F msg_err >/dev/null; then
        msg_err "$@"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

_journalctl_draw_header() {
    if declare -F draw_header >/dev/null; then
        draw_header "$1"
    else
        printf '\n== %s ==\n' "$1"
    fi
}

journalctl_require_command() {
    local cmd="$1"

    if command -v "$cmd" >/dev/null 2>&1 || declare -F "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    _journalctl_msg_err "未找到命令: $cmd"
    return 1
}

journalctl_normalize_unit_name() {
    local unit="${1:-}"

    if [[ -z "$unit" ]]; then
        return 1
    fi

    if [[ "$unit" == *.* ]]; then
        printf '%s\n' "$unit"
    else
        printf '%s.service\n' "$unit"
    fi
}

journalctl_extract_failed_units() {
    awk '
        NF >= 4 && $1 != "UNIT" && $2 != "loaded" { next }
        NF >= 4 && $1 != "UNIT" {
            if ($3 == "failed" || $4 == "failed") {
                print $1
            }
        }
    '
}

journalctl_unique_lines() {
    awk 'NF && !seen[$0]++ { print }'
}

journalctl_summarize_error_diff() {
    local current_raw="${1:-}"
    local previous_raw="${2:-}"
    local current_file previous_file

    current_file="$(mktemp)" || return 1
    previous_file="$(mktemp)" || {
        rm -f "$current_file"
        return 1
    }

    printf '%s\n' "$current_raw" | journalctl_unique_lines > "$current_file"
    printf '%s\n' "$previous_raw" | journalctl_unique_lines > "$previous_file"

    awk '
        FNR == NR {
            previous[$0] = 1
            previous_order[++previous_count] = $0
            next
        }

        {
            current[$0] = 1
            current_order[++current_count] = $0
        }

        END {
            for (i = 1; i <= current_count; i++) {
                line = current_order[i]
                if (line in previous) {
                    persistent[++persistent_count] = line
                } else {
                    new_items[++new_count] = line
                }
            }

            for (i = 1; i <= previous_count; i++) {
                line = previous_order[i]
                if (!(line in current)) {
                    resolved[++resolved_count] = line
                }
            }

            printf "new:%d\n", new_count
            printf "persistent:%d\n", persistent_count
            printf "resolved:%d\n", resolved_count

            printf "new_items:"
            for (i = 1; i <= new_count; i++) {
                printf "%s%s", (i == 1 ? "" : "\n"), new_items[i]
            }
            printf "\n"

            printf "persistent_items:"
            for (i = 1; i <= persistent_count; i++) {
                printf "%s%s", (i == 1 ? "" : "\n"), persistent[i]
            }
            printf "\n"

            printf "resolved_items:"
            for (i = 1; i <= resolved_count; i++) {
                printf "%s%s", (i == 1 ? "" : "\n"), resolved[i]
            }
            printf "\n"
        }
    ' "$previous_file" "$current_file"

    rm -f "$current_file" "$previous_file"
}

journalctl_collect_boot_errors() {
    local boot_ref="${1:-0}"
    local lines="${2:-100}"

    journalctl_require_command "$JOURNALCTL_BIN" || return 1
    "$JOURNALCTL_BIN" -b "$boot_ref" -p err..alert -n "$lines" --no-pager -o cat 2>/dev/null | journalctl_unique_lines
}

journalctl_show_boot_logs() {
    local boot_ref="${1:-0}"
    local lines="${2:-100}"

    journalctl_require_command "$JOURNALCTL_BIN" || return 1

    _journalctl_draw_header "Boot 日志查看"
    _journalctl_msg_info "boot=$boot_ref, recent_lines=$lines"
    "$JOURNALCTL_BIN" -b "$boot_ref" -n "$lines" --no-pager -o short-iso
}

journalctl_show_unit_recent_logs() {
    local unit lines normalized_unit

    unit="${1:-}"
    lines="${2:-80}"
    normalized_unit="$(journalctl_normalize_unit_name "$unit")" || {
        _journalctl_msg_err "未指定 service/unit 名称"
        return 1
    }

    journalctl_require_command "$JOURNALCTL_BIN" || return 1

    _journalctl_draw_header "Unit 最近日志"
    _journalctl_msg_info "unit=$normalized_unit, recent_lines=$lines"
    "$JOURNALCTL_BIN" -u "$normalized_unit" -n "$lines" --no-pager -o short-iso
}

journalctl_list_failed_services() {
    journalctl_require_command "$SYSTEMCTL_BIN" || return 1

    _journalctl_draw_header "Failed Services"
    "$SYSTEMCTL_BIN" --failed --type=service --no-pager --plain
}

journalctl_diagnose_service() {
    local unit lines normalized_unit

    unit="${1:-}"
    lines="${2:-80}"
    normalized_unit="$(journalctl_normalize_unit_name "$unit")" || {
        _journalctl_msg_err "未指定 service/unit 名称"
        return 1
    }

    journalctl_require_command "$SYSTEMCTL_BIN" || return 1
    journalctl_require_command "$JOURNALCTL_BIN" || return 1

    _journalctl_draw_header "Service 状态诊断"
    _journalctl_msg_info "unit=$normalized_unit"
    "$SYSTEMCTL_BIN" status "$normalized_unit" --no-pager --full 2>&1 || true

    echo ""
    _journalctl_draw_header "Service 最近日志"
    "$JOURNALCTL_BIN" -u "$normalized_unit" -n "$lines" --no-pager -o short-iso 2>&1 || true
}

journalctl_compare_boot_errors() {
    local lines current_errors previous_errors summary new_count persistent_count resolved_count

    lines="${1:-100}"

    current_errors="$(journalctl_collect_boot_errors 0 "$lines")" || return 1
    previous_errors="$(journalctl_collect_boot_errors -1 "$lines")" || previous_errors=""
    summary="$(journalctl_summarize_error_diff "$current_errors" "$previous_errors")" || return 1

    new_count="$(printf '%s\n' "$summary" | awk -F: '/^new:/{print $2}')"
    persistent_count="$(printf '%s\n' "$summary" | awk -F: '/^persistent:/{print $2}')"
    resolved_count="$(printf '%s\n' "$summary" | awk -F: '/^resolved:/{print $2}')"

    _journalctl_draw_header "最近启动与上次启动错误对比"
    _journalctl_msg_info "最近 $lines 条 err..alert 级别日志"
    printf '  新增错误: %s\n' "${new_count:-0}"
    printf '  持续存在: %s\n' "${persistent_count:-0}"
    printf '  已恢复:   %s\n' "${resolved_count:-0}"

    echo ""
    printf '%s\n' "$summary"
}
