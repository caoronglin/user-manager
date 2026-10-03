#!/bin/bash
# snapshot_ops.sh - bounded, read-only Ubuntu operations snapshot sections.
#
# This module is only used by the trusted snapshot collector. Every external
# command is fixed, read-only, time-limited, and has a bounded captured output.
# Each section reports its own availability so one missing tool cannot discard
# the other sections.

_snapshot_ops_capture() {
    local seconds="$1" max_bytes="$2" output_name="$3" captured rc
    shift 3

    if ! command -v timeout >/dev/null 2>&1; then
        printf -v "$output_name" '%s' ''
        return 127
    fi

    if captured="$(
        set -o pipefail
        timeout --signal=TERM --kill-after=1s "${seconds}s" "$@" 2>/dev/null | head -c "$max_bytes"
    )"; then
        rc=0
    else
        rc=$?
    fi
    printf -v "$output_name" '%s' "$captured"
    return "$rc"
}

_snapshot_ops_uint_json() {
    if [[ "$1" =~ ^[0-9]{1,20}$ ]]; then
        printf '%s\n' "$1"
    else
        printf 'null\n'
    fi
}

_snapshot_ops_percent_json() {
    local value="${1%%%}"
    if [[ "$value" =~ ^(100|[0-9]{1,2})$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'null\n'
    fi
}

_snapshot_ops_filesystem_section() {
    local mountinfo="${1:-/proc/self/mountinfo}" status=ok truncated=false
    local mountpoint output rc line size used avail size_pct inode_total inode_used inode_avail inode_pct deadline
    local j_size j_used j_avail j_size_pct j_inode_total j_inode_used j_inode_avail j_inode_pct error
    local mounts_json='[]' count=0
    local -a mounts=()

    if [[ ! -r "$mountinfo" ]]; then
        jq -cn '{status:"unavailable", mounts:[], mount_count:0, truncated:false, reason:"mount_table_unreadable"}'
        return 0
    fi

    mapfile -t mounts < <(awk '
        NF >= 6 { if (count < 128) print $5; count++ }
        END { if (count > 128) print "__UM_SNAPSHOT_TRUNCATED__" }
    ' "$mountinfo" 2>/dev/null)
    if ((${#mounts[@]} > 0)) && [[ "${mounts[-1]}" == '__UM_SNAPSHOT_TRUNCATED__' ]]; then
        unset 'mounts[-1]'
        truncated=true
        status=degraded
    fi

    # Bound the entire filesystem section as well as each individual mount.
    deadline=$((SECONDS + 12))
    for mountpoint in "${mounts[@]}"; do
        [[ -n "$mountpoint" ]] || continue
        # mountinfo escapes whitespace and backslashes in field 5.
        mountpoint="${mountpoint//\\040/ }"
        mountpoint="${mountpoint//\\011/$'\t'}"
        mountpoint="${mountpoint//\\012/$'\n'}"
        mountpoint="${mountpoint//\\134/\\}"
        count=$((count + 1))
        output=''
        error=''
        j_size=null
        j_used=null
        j_avail=null
        j_size_pct=null
        j_inode_total=null
        j_inode_used=null
        j_inode_avail=null
        j_inode_pct=null
        if ((SECONDS >= deadline)); then
            rc=124
            error='section_deadline_exceeded'
            status=degraded
        else
            if _snapshot_ops_capture 1 4096 output df --block-size=1 --output=size,used,avail,pcent,itotal,iused,iavail,ipcent -- "$mountpoint"; then
                # The final output line contains only the requested numeric columns.
                output="${output%$'\n'}"
                line="${output##*$'\n'}"
                IFS=$' \t' read -r size used avail size_pct inode_total inode_used inode_avail inode_pct _ <<<"$line"
                j_size="$(_snapshot_ops_uint_json "${size:-}")"
                j_used="$(_snapshot_ops_uint_json "${used:-}")"
                j_avail="$(_snapshot_ops_uint_json "${avail:-}")"
                j_size_pct="$(_snapshot_ops_percent_json "${size_pct:-}")"
                j_inode_total="$(_snapshot_ops_uint_json "${inode_total:-}")"
                j_inode_used="$(_snapshot_ops_uint_json "${inode_used:-}")"
                j_inode_avail="$(_snapshot_ops_uint_json "${inode_avail:-}")"
                j_inode_pct="$(_snapshot_ops_percent_json "${inode_pct:-}")"
                if [[ "$j_size" == null || "$j_used" == null || "$j_avail" == null || "$j_inode_total" == null ]]; then
                    error='invalid_df_output'
                    status=degraded
                fi
            else
                rc=$?
                if ((rc == 124 || rc == 137)); then error='timed_out'; else error='unavailable'; fi
                status=degraded
            fi
        fi

        mounts_json="$(jq -cn \
            --arg mountpoint "$mountpoint" \
            --arg error "$error" \
            --argjson size "$j_size" --argjson used "$j_used" --argjson avail "$j_avail" \
            --argjson size_pct "$j_size_pct" \
            --argjson inode_total "$j_inode_total" --argjson inode_used "$j_inode_used" \
            --argjson inode_avail "$j_inode_avail" --argjson inode_pct "$j_inode_pct" \
            --argjson prior "$mounts_json" \
            '$prior + [{mountpoint:$mountpoint, available:($error == ""), error:(if $error == "" then null else $error end), size_bytes:$size, used_bytes:$used, available_bytes:$avail, used_percent:$size_pct, inode_total:$inode_total, inode_used:$inode_used, inode_available:$inode_avail, inode_used_percent:$inode_pct}]')"
    done

    if ((count == 0)); then status=degraded; fi
    jq -cn --arg status "$status" --argjson mounts "$mounts_json" \
        --argjson count "$count" --argjson truncated "$truncated" \
        '{status:$status, mounts:$mounts, mount_count:$count, truncated:$truncated}'
}

_snapshot_ops_query_unit() {
    local unit="$1" output='' rc=0 load_state='' active_state=''
    if _snapshot_ops_capture 2 2048 output systemctl --no-pager show \
        --property=LoadState --property=ActiveState --value "$unit"; then
        load_state="${output%%$'\n'*}"
        if [[ "$output" == *$'\n'* ]]; then active_state="${output#*$'\n'}"; fi
        active_state="${active_state%%$'\n'*}"
    else
        rc=$?
    fi
    jq -cn --arg unit "$unit" --arg load "$load_state" --arg active "$active_state" \
        --argjson available "$([[ $rc == 0 ]] && printf true || printf false)" \
        '{name:$unit, available:$available, load_state:(if $available then $load else null end), active_state:(if $available then $active else null end)}'
}

_snapshot_ops_systemd_section() {
    local status=ok failed_raw='' timers_raw='' boot_state='' rc=0
    local failed_available=true timers_available=true boot_available=false
    local failed_json='[]' timers_json='[]' services_json='[]' unit_json
    local unit
    local -a key_units=(ssh.service smbd.service umweb.service cron.service systemd-journald.service)

    if _snapshot_ops_capture 2 32768 failed_raw systemctl --no-pager --plain --failed --type=service --no-legend; then
        failed_json="$(printf '%s\n' "$failed_raw" | awk 'NF && $1 ~ /\.service$/ { print $1; if (++n >= 100) exit }' | jq -R -s 'split("\n") | map(select(length > 0))')"
    else
        status=degraded
        failed_available=false
    fi

    if _snapshot_ops_capture 5 32768 timers_raw systemctl list-timers --all --no-pager --no-legend; then
        timers_json="$(printf '%s\n' "$timers_raw" | awk 'NF { for (i=1; i<=NF; i++) if ($i ~ /\.timer$/) { print $i; if (++n >= 100) exit; next } }' | jq -R -s 'split("\n") | map(select(length > 0))')"
    else
        status=degraded
        timers_available=false
    fi

    if _snapshot_ops_capture 2 2048 boot_state systemctl is-system-running; then
        boot_available=true
    else
        rc=$?
        # systemctl returns 1 for a valid degraded/maintenance state.
        if [[ ! "$boot_state" =~ ^(degraded|maintenance)$ ]]; then
            status=degraded
            boot_state='unknown'
        else
            status=degraded
            boot_available=true
        fi
    fi
    [[ "$failed_json" == '[]' ]] || status=degraded

    for unit in "${key_units[@]}"; do
        unit_json="$(_snapshot_ops_query_unit "$unit")"
        if [[ "$(jq -r '.available' <<<"$unit_json")" != true ]]; then status=degraded; fi
        services_json="$(jq -cn --argjson prior "$services_json" --argjson item "$unit_json" '$prior + [$item]')"
    done
    jq -cn --arg status "$status" --arg boot "$boot_state" \
        --argjson failed_available "$failed_available" --argjson timers_available "$timers_available" \
        --argjson boot_available "$boot_available" \
        --argjson failed "$failed_json" --argjson timers "$timers_json" --argjson services "$services_json" \
        '{status:$status, boot_state:(if $boot == "" then "unknown" else $boot end), boot_state_available:$boot_available, failed_services_available:$failed_available, failed_services:$failed, failed_service_count:($failed|length), timers_available:$timers_available, timers:$timers, timer_count:($timers|length), key_services:$services}'
}

_snapshot_ops_apt_section() {
    local auto_config="${1:-/etc/apt/apt.conf.d/20auto-upgrades}"
    local reboot_marker="${2:-/var/run/reboot-required}"
    local status=ok unattended='unknown' reboot_required=false reboot_packages=0
    local apt_output='' apt_rc=0 total=null security=null
    local apt_timers='[]' timer_json apt_timers_available=true
    local -a apt_timer_units=(apt-daily.timer apt-daily-upgrade.timer)

    if [[ -r "$auto_config" ]]; then
        unattended="$(awk -F'"' '/^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]*"/ { v=tolower($2); if (v == "1" || v == "true") print "true"; else print "false"; exit }' "$auto_config" 2>/dev/null)"
        [[ "$unattended" == true || "$unattended" == false ]] || unattended=unknown
    fi
    if [[ -e "$reboot_marker" ]]; then
        reboot_required=true
        if [[ -r "$reboot_marker.pkgs" ]]; then
            reboot_packages="$(awk 'NF { n++; if (n >= 1000) exit } END { print n+0 }' "$reboot_marker.pkgs" 2>/dev/null)"
            [[ "$reboot_packages" =~ ^[0-9]{1,4}$ ]] || reboot_packages=0
        fi
    fi

    # apt-get simulation reads the local package lists and installed state; -s
    # disables package actions. Network acquisition/update commands are never run.
    if _snapshot_ops_capture 12 65536 apt_output apt-get --simulate --quiet=2 \
        -o Debug::NoLocking=1 --no-remove upgrade; then
        read -r total security < <(printf '%s\n' "$apt_output" | awk '
            /^Inst / { all++; if (tolower($0) ~ /security/) secure++ }
            END { printf "%d %d\n", all+0, secure+0 }
        ')
    else
        apt_rc=$?
        status=degraded
    fi

    for unit in "${apt_timer_units[@]}"; do
        timer_json="$(_snapshot_ops_query_unit "$unit")"
        if [[ "$(jq -r '.available' <<<"$timer_json")" != true ]]; then
            status=degraded
            apt_timers_available=false
        fi
        apt_timers="$(jq -cn --argjson prior "$apt_timers" --argjson item "$timer_json" '$prior + [$item]')"
    done
    [[ -r "$auto_config" ]] || status=degraded
    [[ "$apt_rc" == 0 ]] || status=degraded

    jq -cn --arg status "$status" --arg unattended "$unattended" \
        --argjson reboot "$reboot_required" --argjson reboot_packages "$reboot_packages" \
        --argjson total "$total" --argjson security "$security" --argjson timers "$apt_timers" \
        --argjson timers_available "$apt_timers_available" \
        '{status:$status, upgradable_count:$total, security_upgradable_count:$security, reboot_required:$reboot, reboot_required_package_count:$reboot_packages, unattended_upgrades_configured:(if $unattended == "unknown" then null else ($unattended == "true") end), apt_timers_available:$timers_available, apt_timers:$timers}'
}

_snapshot_ops_apparmor_section() {
    local enabled_file="${1:-/sys/module/apparmor/parameters/enabled}"
    local status=ok enabled=null output='' profiles=null enforce=null complain=null unconfined=null
    local value

    if [[ -r "$enabled_file" ]] && IFS= read -r value <"$enabled_file"; then
        case "${value,,}" in
        y | yes | 1) enabled=true ;;
        n | no | 0) enabled=false ;;
        *) status=degraded ;;
        esac
    else
        status=degraded
    fi

    if command -v aa-status >/dev/null 2>&1; then
        if _snapshot_ops_capture 3 4096 output aa-status; then
            read -r profiles enforce complain unconfined < <(printf '%s\n' "$output" | awk '
                /^[0-9]+ profiles are loaded\./ { p=$1 }
                /^[0-9]+ profiles are in enforce mode\./ { e=$1 }
                /^[0-9]+ profiles are in complain mode\./ { c=$1 }
                /^[0-9]+ processes are unconfined\./ { u=$1 }
                END { printf "%s %s %s %s\n", p, e, c, u }
            ')
            [[ "$profiles" =~ ^[0-9]{1,6}$ ]] || {
                profiles=null
                status=degraded
            }
            [[ "$enforce" =~ ^[0-9]{1,6}$ ]] || enforce=null
            [[ "$complain" =~ ^[0-9]{1,6}$ ]] || complain=null
            [[ "$unconfined" =~ ^[0-9]{1,6}$ ]] || unconfined=null
        else
            status=degraded
        fi
    else
        status=unavailable
    fi
    jq -cn --arg status "$status" --argjson enabled "$enabled" \
        --argjson profiles "$profiles" --argjson enforce "$enforce" \
        --argjson complain "$complain" --argjson unconfined "$unconfined" \
        '{status:$status, enabled:$enabled, profiles_loaded:$profiles, profiles_enforce:$enforce, profiles_complain:$complain, processes_unconfined:$unconfined}'
}

_snapshot_ops_cpu_usage_json() {
    local stat_file="${1:-/proc/stat}"
    local -a before=() after=()
    local i value total_before total_after idle_before idle_after total_delta idle_delta
    if [[ ! -r "$stat_file" ]] || ! IFS=' ' read -r -a before <"$stat_file" ||
        [[ "${before[0]:-}" != cpu ]]; then
        printf 'null\n'
        return 0
    fi
    sleep 0.1
    if ! IFS=' ' read -r -a after <"$stat_file" || [[ "${after[0]:-}" != cpu ]]; then
        printf 'null\n'
        return 0
    fi
    for i in 1 2 3 4 5 6 7 8; do
        value="${before[$i]:-0}"
        if [[ ! "$value" =~ ^[0-9]{1,18}$ ]]; then
            printf 'null\n'
            return 0
        fi
        value="${after[$i]:-0}"
        if [[ ! "$value" =~ ^[0-9]{1,18}$ ]]; then
            printf 'null\n'
            return 0
        fi
    done
    total_before=$((before[1] + before[2] + before[3] + before[4] + before[5] + before[6] + before[7] + before[8]))
    total_after=$((after[1] + after[2] + after[3] + after[4] + after[5] + after[6] + after[7] + after[8]))
    idle_before=$((before[4] + before[5]))
    idle_after=$((after[4] + after[5]))
    total_delta=$((total_after - total_before))
    idle_delta=$((idle_after - idle_before))
    if ((total_delta <= 0 || idle_delta < 0 || idle_delta > total_delta)); then
        printf 'null\n'
    else
        awk -v total="$total_delta" -v idle="$idle_delta" 'BEGIN { printf "%.2f\n", 100 * (total - idle) / total }'
    fi
}

_snapshot_ops_psi_row_json() {
    local line="$1" avg10='' avg60='' avg300='' total=''
    local -a fields=() parts
    IFS=' ' read -r -a fields <<<"$line"
    for part in "${fields[@]:1}"; do
        case "$part" in
        avg10=*) avg10="${part#*=}" ;;
        avg60=*) avg60="${part#*=}" ;;
        avg300=*) avg300="${part#*=}" ;;
        total=*) total="${part#*=}" ;;
        esac
    done
    [[ "$avg10" =~ ^[0-9]+([.][0-9]+)?$ && "$avg60" =~ ^[0-9]+([.][0-9]+)?$ &&
        "$avg300" =~ ^[0-9]+([.][0-9]+)?$ && "$total" =~ ^[0-9]{1,20}$ ]] || return 1
    jq -cn --argjson avg10 "$avg10" --argjson avg60 "$avg60" \
        --argjson avg300 "$avg300" --argjson total "$total" \
        '{avg10:$avg10, avg60:$avg60, avg300:$avg300, total_us:$total}'
}

_snapshot_ops_psi_file_json() {
    local path="$1" status=ok some='null' full='null' row kind row_json
    local -a rows=()
    if [[ ! -r "$path" ]]; then
        jq -cn '{status:"unavailable", some:null, full:null}'
        return 0
    fi
    mapfile -t rows < <(awk 'NR <= 2 { print; if (NR == 2) exit }' "$path" 2>/dev/null)
    for row in "${rows[@]}"; do
        [[ -n "$row" ]] || continue
        kind="${row%% *}"
        if row_json="$(_snapshot_ops_psi_row_json "$row")"; then
            case "$kind" in
            some) some="$row_json" ;;
            full) full="$row_json" ;;
            *) status=degraded ;;
            esac
        else
            status=degraded
        fi
    done
    [[ "$some" != null ]] || status=degraded
    jq -cn --arg status "$status" --argjson some "$some" --argjson full "$full" \
        '{status:$status, some:$some, full:$full}'
}

_snapshot_ops_system_summary() {
    local os_file="${1:-/etc/os-release}" stat_file="${2:-/proc/stat}"
    local meminfo_file="${3:-/proc/meminfo}" pressure_dir="${4:-/proc/pressure}"
    local os_id='' os_version='' os_pretty='' os_status=ok ubuntu_version=null
    local boot_epoch='' boot_time='' virtualization='' virtualization_status=unavailable rc=0
    local cpu_usage logical_cpus cpu_status=ok mem_total mem_available swap_total swap_available memory_status=ok
    local psi_cpu psi_memory psi_io psi_status=ok

    if [[ -r "$os_file" ]]; then
        IFS=$'\t' read -r os_id os_version os_pretty < <(awk -F= '
            NR <= 64 {
                key=$1
                if (key != "ID" && key != "VERSION_ID" && key != "PRETTY_NAME") next
                value=substr($0, index($0, "=") + 1)
                if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
                if (key == "ID") id=value
                else if (key == "VERSION_ID") version=value
                else pretty=value
            }
            END { printf "%s\t%s\t%s\n", id, version, pretty }
        ' "$os_file" 2>/dev/null)
        [[ -n "$os_id" ]] || os_status=degraded
        if [[ "$os_id" == ubuntu && "$os_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then ubuntu_version="$os_version"; fi
    else
        os_status=unavailable
    fi

    boot_epoch="$(awk 'NR <= 64 && $1 == "btime" { print $2; exit }' "$stat_file" 2>/dev/null)"
    if [[ "$boot_epoch" =~ ^[0-9]{1,12}$ ]]; then
        boot_time="$(date -u -d "@$boot_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    else
        boot_epoch=''
    fi
    [[ "$boot_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || boot_time=''

    if _snapshot_ops_capture 2 128 virtualization systemd-detect-virt; then
        virtualization="${virtualization%$'\n'}"
        if [[ "$virtualization" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
            virtualization_status=ok
        else
            virtualization='unknown'
            virtualization_status=degraded
        fi
    else
        rc=$?
        if ((rc == 1)); then
            virtualization=none
            virtualization_status=ok
        else
            virtualization='unknown'
            virtualization_status=degraded
        fi
    fi

    cpu_usage="$(_snapshot_ops_cpu_usage_json "$stat_file")"
    logical_cpus="$(awk '
        NR <= 4096 {
            if ($1 ~ /^cpu[0-9]+$/) { count++; next }
            if (NR > 1) exit
        }
        END { if (count > 0) print count; else print "null" }
    ' "$stat_file" 2>/dev/null)"
    [[ "$logical_cpus" =~ ^[0-9]{1,4}$ ]] || logical_cpus=null
    [[ "$cpu_usage" =~ ^[0-9]+([.][0-9]+)?$ && "$logical_cpus" != null ]] || cpu_status=degraded

    if [[ -r "$meminfo_file" ]]; then
        IFS=$'\t' read -r mem_total mem_available swap_total swap_available < <(awk '
            NR <= 128 {
                if ($1 == "MemTotal:") mem_total=$2 * 1024
                else if ($1 == "MemAvailable:") mem_available=$2 * 1024
                else if ($1 == "SwapTotal:") swap_total=$2 * 1024
                else if ($1 == "SwapFree:") swap_available=$2 * 1024
            }
            END {
                if (mem_total != "") mem_total=sprintf("%.0f", mem_total); else mem_total="null"
                if (mem_available != "") mem_available=sprintf("%.0f", mem_available); else mem_available="null"
                if (swap_total != "") swap_total=sprintf("%.0f", swap_total); else swap_total="null"
                if (swap_available != "") swap_available=sprintf("%.0f", swap_available); else swap_available="null"
                printf "%s\t%s\t%s\t%s\n", mem_total, mem_available, swap_total, swap_available
            }
        ' "$meminfo_file" 2>/dev/null)
        for value in mem_total mem_available swap_total swap_available; do
            if [[ ! "${!value}" =~ ^[0-9]{1,20}$ ]]; then
                printf -v "$value" '%s' null
                memory_status=degraded
            fi
        done
    else
        mem_total=null
        mem_available=null
        swap_total=null
        swap_available=null
        memory_status=unavailable
    fi

    psi_cpu="$(_snapshot_ops_psi_file_json "$pressure_dir/cpu")"
    psi_memory="$(_snapshot_ops_psi_file_json "$pressure_dir/memory")"
    psi_io="$(_snapshot_ops_psi_file_json "$pressure_dir/io")"
    for rc in "$(jq -r '.status' <<<"$psi_cpu")" "$(jq -r '.status' <<<"$psi_memory")" "$(jq -r '.status' <<<"$psi_io")"; do
        case "$rc" in ok) ;; unavailable) [[ "$psi_status" == ok ]] && psi_status=partial ;; *) psi_status=degraded ;; esac
    done
    if [[ "$(jq -r '.status' <<<"$psi_cpu")" == unavailable &&
    "$(jq -r '.status' <<<"$psi_memory")" == unavailable &&
    "$(jq -r '.status' <<<"$psi_io")" == unavailable ]]; then psi_status=unavailable; fi

    jq -cn --arg os_id "$os_id" --arg os_version "$os_version" --arg os_pretty "$os_pretty" \
        --arg os_status "$os_status" --arg ubuntu_version "$ubuntu_version" \
        --arg boot_epoch "$boot_epoch" --arg boot_time "$boot_time" \
        --arg virt_status "$virtualization_status" --arg virtualization "$virtualization" \
        --arg cpu_status "$cpu_status" --arg memory_status "$memory_status" \
        --argjson cpu_usage "$cpu_usage" --argjson logical_cpus "$logical_cpus" \
        --argjson mem_total "$mem_total" --argjson mem_available "$mem_available" \
        --argjson swap_total "$swap_total" --argjson swap_available "$swap_available" \
        --arg psi_status "$psi_status" --argjson psi_cpu "$psi_cpu" \
        --argjson psi_memory "$psi_memory" --argjson psi_io "$psi_io" \
        '{os_release:{status:$os_status, id:(if $os_id == "" then null else $os_id end), version_id:(if $os_version == "" then null else $os_version end), pretty_name:(if $os_pretty == "" then null else $os_pretty end)}, ubuntu_version:(if $ubuntu_version == "null" then null else $ubuntu_version end), boot_time_epoch:(if $boot_epoch == "" then null else ($boot_epoch|tonumber) end), boot_time:(if $boot_time == "" then null else $boot_time end), virtualization:{status:$virt_status, kind:(if $virtualization == "" then null else $virtualization end)}, cpu_status:$cpu_status, cpu_usage_percent:$cpu_usage, logical_cpu_count:$logical_cpus, memory_status:$memory_status, mem_total_bytes:$mem_total, mem_available_bytes:$mem_available, swap_total_bytes:$swap_total, swap_available_bytes:$swap_available, pressure:{status:$psi_status, cpu:$psi_cpu, memory:$psi_memory, io:$psi_io}}'
}

snapshot_ops_system_summary() {
    _snapshot_ops_system_summary "$@"
}

snapshot_ops_collect() {
    local filesystems systemd apt apparmor
    filesystems="$(_snapshot_ops_filesystem_section /proc/self/mountinfo 2>/dev/null || printf '{"status":"unavailable","mounts":[],"mount_count":0,"truncated":false}')"
    systemd="$(_snapshot_ops_systemd_section 2>/dev/null || printf '{"status":"unavailable","boot_state":"unknown","boot_state_available":false,"failed_services_available":false,"failed_services":[],"failed_service_count":0,"timers_available":false,"timers":[],"timer_count":0,"key_services":[]}')"
    apt="$(_snapshot_ops_apt_section 2>/dev/null || printf '{"status":"unavailable","upgradable_count":null,"security_upgradable_count":null,"reboot_required":false,"reboot_required_package_count":0,"unattended_upgrades_configured":null,"apt_timers_available":false,"apt_timers":[]}')"
    apparmor="$(_snapshot_ops_apparmor_section /sys/module/apparmor/parameters/enabled 2>/dev/null || printf '{"status":"unavailable","enabled":null,"profiles_loaded":null,"profiles_enforce":null,"profiles_complain":null,"processes_unconfined":null}')"
    jq -cn --argjson filesystems "$filesystems" --argjson systemd "$systemd" \
        --argjson apt "$apt" --argjson apparmor "$apparmor" \
        '{filesystems:$filesystems, systemd:$systemd, apt:$apt, apparmor:$apparmor}'
}
