#!/bin/bash
# tui_views_logs.sh - 原生 TUI 日志查看视图

_tui_logs_source_optional() {
    local module="$1"
    local module_dir="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local module_path="$module_dir/$module"

    if [[ -f "$module_path" ]]; then
        # shellcheck disable=SC1090
        source "$module_path"
    fi
}

if ! declare -F logs_present_tui >/dev/null 2>&1; then
    _tui_logs_source_optional "logs_presenter.sh"
fi

tui_logs_render_text() {
    local title="${1:-日志}"
    local body="${2:-}"
    local scroll_offset="${3:-0}"
    local max_rows="${4:-18}"

    [[ "$scroll_offset" =~ ^[0-9]+$ ]] || scroll_offset=0
    [[ "$max_rows" =~ ^[0-9]+$ ]] || max_rows=18
    (( max_rows < 1 )) && max_rows=1

    if declare -F tui_clear >/dev/null 2>&1 \
        && declare -F tui_draw_center >/dev/null 2>&1 \
        && declare -F tui_statusbar_draw >/dev/null 2>&1; then
        tui_clear
        tui_draw_center 1 "$title" "${TUI_COLOR_ACCENT:-6}"

        local row=4 index=0 printed=0 line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if (( index++ < scroll_offset )); then
                continue
            fi
            (( printed >= max_rows )) && break
            if declare -F tui_move >/dev/null 2>&1; then
                tui_move "$row" 2
            fi
            printf '%s\n' "$line"
            ((row++))
            ((printed++))
        done <<< "$body"

        if (( printed == 0 )); then
            tui_draw_center 5 "没有可显示的日志" "${TUI_COLOR_MUTED:-8}"
        fi

        tui_statusbar_draw "$((${TUI_LINES:-24} - 1))" "$title" "↑/↓ 滚动  r 刷新  q 返回"
        return 0
    fi

    printf '== %s ==\n' "$title"
    local index=0 printed=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( index++ < scroll_offset )); then
            continue
        fi
        (( printed >= max_rows )) && break
        printf '%s\n' "$line"
        ((printed++))
    done <<< "$body"
    (( printed > 0 )) || printf '没有可显示的日志\n'
    printf '\n%s\n' "↑/↓ 滚动  r 刷新  q 返回"
}

_tui_logs_read_key() {
    local key rest
    TUI_LOGS_KEY=""

    if [[ -n "${TUI_LOGS_TEST_KEYS:-}" ]]; then
        if [[ "$TUI_LOGS_TEST_KEYS" == *$'\n'* ]]; then
            key="${TUI_LOGS_TEST_KEYS%%$'\n'*}"
            rest="${TUI_LOGS_TEST_KEYS#*$'\n'}"
        else
            key="$TUI_LOGS_TEST_KEYS"
            rest=""
        fi
        TUI_LOGS_TEST_KEYS="$rest"
        TUI_LOGS_KEY="$key"
        return 0
    fi

    if declare -F tui_read_key >/dev/null 2>&1; then
        TUI_LOGS_KEY="$(tui_read_key 2>/dev/null)" || return 1
        return $?
    fi

    IFS= read -rsn1 key || return 1
    case "$key" in
        $'\e')
            TUI_LOGS_KEY="ESC"
            ;;
        *)
            TUI_LOGS_KEY="$key"
            ;;
    esac
}

tui_logs_open_action() {
    local action_id="${1:-}"
    local output rc=0 last_rc=0 max_rows scroll_offset=0 key
    local -a action_args=()

    shift || true
    action_args=("$@")
    if ! declare -F logs_present_tui >/dev/null 2>&1; then
        printf 'logs_present_tui 不可用\n' >&2
        return 1
    fi

    max_rows=$((${TUI_LINES:-24} - 6))
    (( max_rows < 1 )) && max_rows=1

    while true; do
        if output="$(logs_present_tui "$action_id" "${action_args[@]}" 2>&1)"; then
            rc=0
        else
            rc=$?
            [[ -n "$output" ]] || output="日志 action 执行失败 (rc=$rc)"
        fi
        last_rc=$rc

        tui_logs_render_text "$action_id" "$output" "$scroll_offset" "$max_rows"

        while true; do
            if _tui_logs_read_key; then
                key="$TUI_LOGS_KEY"
            else
                key="q"
            fi
            case "$key" in
                q|Q|ESC)
                    return "$last_rc"
                    ;;
                r|R)
                    break
                    ;;
                UP|k|K)
                    (( scroll_offset > 0 )) && ((scroll_offset--))
                    tui_logs_render_text "$action_id" "$output" "$scroll_offset" "$max_rows"
                    ;;
                DOWN|j|J)
                    ((scroll_offset++))
                    tui_logs_render_text "$action_id" "$output" "$scroll_offset" "$max_rows"
                    ;;
                *)
                    ;;
            esac
        done
    done
}

run_log_viewer() {
    tui_logs_open_action logs.system_file_tail --lines 120
}
