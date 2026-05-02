#!/bin/bash
# ubuntu_maintenance_core.sh - Ubuntu APT/重启维护摘要模块

if [[ -z "${USER_MANAGER_UBUNTU_MAINTENANCE_LOADED:-}" ]]; then
USER_MANAGER_UBUNTU_MAINTENANCE_LOADED=1

UBUNTU_MAINTENANCE_REBOOT_FLAG="${UBUNTU_MAINTENANCE_REBOOT_FLAG:-/var/run/reboot-required}"
UBUNTU_MAINTENANCE_APT_HISTORY_LOG="${UBUNTU_MAINTENANCE_APT_HISTORY_LOG:-/var/log/apt/history.log}"
UBUNTU_MAINTENANCE_SOURCES_LIST="${UBUNTU_MAINTENANCE_SOURCES_LIST:-/etc/apt/sources.list}"
UBUNTU_MAINTENANCE_SOURCES_DIR="${UBUNTU_MAINTENANCE_SOURCES_DIR:-/etc/apt/sources.list.d}"

ubuntu_maintenance_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

ubuntu_maintenance_join_preview_from_text() {
    local text="$1"
    local limit="${2:-5}"
    local -a items=()
    local line trimmed

    while IFS= read -r line; do
        trimmed="$(ubuntu_maintenance_trim "$line")"
        [[ -z "$trimmed" ]] && continue
        items+=("$trimmed")
        if (( ${#items[@]} >= limit )); then
            break
        fi
    done <<< "$text"

    if (( ${#items[@]} == 0 )); then
        printf '%s' "none"
        return 0
    fi

    local joined="${items[*]}"
    printf '%s' "${joined// /, }"
}

ubuntu_maintenance_count_csv_items() {
    local value="$1"
    [[ -z "$value" ]] && {
        printf '0'
        return 0
    }

    local count
    count="$(printf '%s\n' "$value" | grep -oE '(^|, )[[:alnum:].+_-]+(:[[:alnum:]_-]+)? \(' | wc -l | tr -d ' ')"
    printf '%s' "${count:-0}"
}

ubuntu_maintenance_count_upgradable_from_text() {
    local text="$1"
    local line count=0 trimmed

    while IFS= read -r line; do
        trimmed="$(ubuntu_maintenance_trim "$line")"
        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" == "Listing... Done" ]] && continue
        [[ "$trimmed" == "WARNING:"* ]] && continue
        ((count++))
    done <<< "$text"

    printf '%s' "$count"
}

ubuntu_maintenance_summarize_apt_history_from_text() {
    local text="$1"
    local line trimmed last_start="n/a"
    local transactions=0 upgrades=0 installs=0 removals=0

    while IFS= read -r line; do
        trimmed="$(ubuntu_maintenance_trim "$line")"
        [[ -z "$trimmed" ]] && continue

        case "$trimmed" in
            Start-Date:*)
                ((transactions++))
                if [[ "$last_start" == "n/a" ]]; then
                    last_start="${trimmed#Start-Date: }"
                    last_start="${last_start//  / }"
                fi
                ;;
            Upgrade:*)
                upgrades=$((upgrades + $(ubuntu_maintenance_count_csv_items "${trimmed#Upgrade: }")))
                ;;
            Install:*)
                installs=$((installs + $(ubuntu_maintenance_count_csv_items "${trimmed#Install: }")))
                ;;
            Remove:*)
                removals=$((removals + $(ubuntu_maintenance_count_csv_items "${trimmed#Remove: }")))
                ;;
        esac
    done <<< "$text"

    printf 'transactions=%s;upgrades=%s;installs=%s;removals=%s;last_start=%s' \
        "$transactions" "$upgrades" "$installs" "$removals" "$last_start"
}

ubuntu_maintenance_summarize_policy_from_text() {
    local text="$1"
    local line trimmed channel_list=""
    local -A channels=()

    while IFS= read -r line; do
        trimmed="$(ubuntu_maintenance_trim "$line")"
        [[ "$trimmed" != release* ]] && continue
        if [[ "$trimmed" =~ a=([^,[:space:]]+) ]]; then
            if [[ "${BASH_REMATCH[1]}" != "now" ]]; then
                channels["${BASH_REMATCH[1]}"]=1
            fi
        fi
    done <<< "$text"

    if (( ${#channels[@]} > 0 )); then
        channel_list="$({
            local key
            for key in "${!channels[@]}"; do
                printf '%s\n' "$key"
            done
        } | sort | paste -sd ',' -)"
    else
        channel_list="none"
    fi

    printf 'channels=%s;channel_list=%s' "${#channels[@]}" "$channel_list"
}

ubuntu_maintenance_get_upgradable_raw() {
    command -v apt >/dev/null 2>&1 || return 0
    apt list --upgradable 2>/dev/null || true
}

ubuntu_maintenance_get_held_raw() {
    command -v apt-mark >/dev/null 2>&1 || return 0
    apt-mark showhold 2>/dev/null || true
}

ubuntu_maintenance_get_needrestart_raw() {
    if command -v needrestart >/dev/null 2>&1; then
        needrestart -b 2>/dev/null || true
    fi
}

ubuntu_maintenance_get_policy_raw() {
    command -v apt-cache >/dev/null 2>&1 || return 0
    apt-cache policy 2>/dev/null || true
}

ubuntu_maintenance_parse_needrestart_status() {
    local text="$1"

    if [[ -z "$text" ]]; then
        printf '%s' "unavailable"
    elif [[ "$text" == *"NEEDRESTART-KSTA: 3"* ]] || [[ "$text" == *"NEEDRESTART-KCUR: 0"* ]]; then
        printf '%s' "kernel"
    elif [[ "$text" == *"NEEDRESTART-SVC:"* ]]; then
        printf '%s' "services"
    elif [[ "$text" == *"NEEDRESTART-KSTA: 0"* ]]; then
        printf '%s' "none"
    else
        printf '%s' "unknown"
    fi
}

ubuntu_maintenance_collect_source_entries() {
    local file="$1"
    local enabled=0 disabled=0
    local line trimmed

    [[ -f "$file" ]] || {
        printf '%s;%s' "$enabled" "$disabled"
        return 0
    }

    while IFS= read -r line; do
        trimmed="$(ubuntu_maintenance_trim "$line")"
        [[ -z "$trimmed" ]] && continue

        case "$trimmed" in
            deb\ *|deb-src\ *)
                ((enabled++))
                ;;
            \#deb\ *|\#\ deb\ *|\#deb-src\ *|\#\ deb-src\ *)
                ((disabled++))
                ;;
            Types:*)
                ((enabled++))
                ;;
            Enabled:\ no)
                ((disabled++))
                ;;
        esac
    done < "$file"

    printf '%s;%s' "$enabled" "$disabled"
}

ubuntu_maintenance_collect_sources_summary() {
    local enabled=0 disabled=0
    local result file

    result="$(ubuntu_maintenance_collect_source_entries "$UBUNTU_MAINTENANCE_SOURCES_LIST")"
    enabled=$((enabled + ${result%%;*}))
    disabled=$((disabled + ${result##*;}))

    if [[ -d "$UBUNTU_MAINTENANCE_SOURCES_DIR" ]]; then
        while IFS= read -r file; do
            result="$(ubuntu_maintenance_collect_source_entries "$file")"
            enabled=$((enabled + ${result%%;*}))
            disabled=$((disabled + ${result##*;}))
        done < <(find "$UBUNTU_MAINTENANCE_SOURCES_DIR" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) | sort)
    fi

    local policy_summary
    policy_summary="$(ubuntu_maintenance_summarize_policy_from_text "$(ubuntu_maintenance_get_policy_raw)")"
    printf 'entries=%s;disabled=%s;%s' "$enabled" "$disabled" "$policy_summary"
}

ubuntu_maintenance_collect_report() {
    local upgradable_raw held_raw needrestart_raw history_raw sources_summary policy_summary
    local upgradable_count held_count reboot_required needrestart_status
    local upgradable_preview held_preview history_summary

    upgradable_raw="$(ubuntu_maintenance_get_upgradable_raw)"
    held_raw="$(ubuntu_maintenance_get_held_raw)"
    needrestart_raw="$(ubuntu_maintenance_get_needrestart_raw)"

    if [[ -f "$UBUNTU_MAINTENANCE_APT_HISTORY_LOG" ]]; then
        history_raw="$(<"$UBUNTU_MAINTENANCE_APT_HISTORY_LOG")"
    else
        history_raw=""
    fi

    upgradable_count="$(ubuntu_maintenance_count_upgradable_from_text "$upgradable_raw")"
    held_count="$(printf '%s\n' "$held_raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    upgradable_preview="$(printf '%s\n' "$upgradable_raw" | sed -E '1d; /^[[:space:]]*$/d; s#/.*##' | head -5 | paste -sd ', ' -)"
    held_preview="$(ubuntu_maintenance_join_preview_from_text "$held_raw" 5)"
    reboot_required="no"
    [[ -f "$UBUNTU_MAINTENANCE_REBOOT_FLAG" ]] && reboot_required="yes"
    needrestart_status="$(ubuntu_maintenance_parse_needrestart_status "$needrestart_raw")"
    history_summary="$(ubuntu_maintenance_summarize_apt_history_from_text "$history_raw")"
    sources_summary="$(ubuntu_maintenance_collect_sources_summary)"

    [[ -z "$upgradable_preview" ]] && upgradable_preview="none"

    printf '%s\n' \
        "upgradable_count=$upgradable_count" \
        "upgradable_preview=$upgradable_preview" \
        "held_count=$held_count" \
        "held_preview=$held_preview" \
        "reboot_required=$reboot_required" \
        "needrestart_status=$needrestart_status" \
        "history_summary=$history_summary" \
        "sources_summary=$sources_summary"
}

show_ubuntu_maintenance_panel() {
    local report line key value
    local upgradable_count="0" upgradable_preview="none" held_count="0" held_preview="none"
    local reboot_required="no" needrestart_status="unavailable" history_summary="transactions=0"
    local sources_summary="entries=0;disabled=0;channels=0;channel_list=none"

    if declare -F draw_header >/dev/null 2>&1; then
        draw_header "Ubuntu APT/重启维护"
    else
        printf 'Ubuntu APT/重启维护\n'
    fi

    report="$(ubuntu_maintenance_collect_report)"
    while IFS='=' read -r key value; do
        case "$key" in
            upgradable_count) upgradable_count="$value" ;;
            upgradable_preview) upgradable_preview="$value" ;;
            held_count) held_count="$value" ;;
            held_preview) held_preview="$value" ;;
            reboot_required) reboot_required="$value" ;;
            needrestart_status) needrestart_status="$value" ;;
            history_summary) history_summary="$value" ;;
            sources_summary) sources_summary="$value" ;;
        esac
    done <<< "$report"

    if declare -F draw_info_card >/dev/null 2>&1; then
        draw_info_card "可升级包:" "$upgradable_count"
        draw_info_card "升级预览:" "$upgradable_preview"
        draw_info_card "Held packages:" "$held_count"
        draw_info_card "Held 预览:" "$held_preview"
        draw_info_card "需要重启:" "$reboot_required"
        draw_info_card "needrestart:" "$needrestart_status"
        draw_info_card "APT 历史:" "$history_summary"
        draw_info_card "源健康:" "$sources_summary"
    else
        printf '可升级包: %s\n' "$upgradable_count"
        printf '升级预览: %s\n' "$upgradable_preview"
        printf 'Held packages: %s\n' "$held_count"
        printf 'Held 预览: %s\n' "$held_preview"
        printf '需要重启: %s\n' "$reboot_required"
        printf 'needrestart: %s\n' "$needrestart_status"
        printf 'APT 历史: %s\n' "$history_summary"
        printf '源健康: %s\n' "$sources_summary"
    fi

    echo ""
}
fi
