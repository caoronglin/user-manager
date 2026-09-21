#!/bin/bash
# rl-snapshot.sh - 可信本地采集器：把只读 Core 查询收敛为脱敏、版本化、原子的 JSON 快照
#
# 这是 Web 控制台的数据来源采集端，不是 Web 服务本身。
# 安全边界（详见 docs/WEB_SECURITY_BOUNDARY.md）：
#   - 由 root 通过 systemd timer / 受信 CLI 运行；Web 服务 (umweb) 不运行本脚本；
#   - 仅调用只读 Core 查询；绝不执行 useradd/setquota/smbpasswd/pdbedit<写>/systemctl<写> 等系统写操作；
#   - 不调用 action_run / priv_exec / user_manager.sh / tui_manager.sh；
#   - 生成的快照文件 root:umweb 0640、目录 0750；umweb 仅只读这些文件。
#
# 数据流：只读 Core -> 脱敏信封 -> 原子写入 snapshot store -> (P1+) Rust API 只读 -> 前端。
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
unset CDPATH ENV BASH_ENV GLOBIGNORE

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_out=''
rl_source='local'
rl_dry=0
rl_manifest_only=0
declare -a rl_kinds=()

rl_usage() {
    cat <<'EOF'
用法: rl-snapshot.sh [选项] [快照类型...]

选项:
  --out DIR       覆盖快照输出目录（默认 $USER_MANAGER_SNAPSHOT_DIR 或 /var/lib/user-manager-web/snapshots）
  --source NAME   覆盖 source 标签（默认 local；多主机采集时填 host_id）
  --manifest-only 仅依据已存在快照刷新 manifest.json
  --dry-run       仅在 stdout 打印信封，不落盘（用于调试/测试）
  -h, --help      显示帮助

快照类型（可多选；缺省为全部）:
  users  quota  resources  smb  hosts  gpu  system  audit-summary

说明: 本脚本是只读可信采集器，不执行任何系统写操作。
EOF
}

while (($# > 0)); do
    case "$1" in
    --out)
        (($# >= 2)) || { rl_usage >&2; exit 2; }
        rl_out="$2"; shift 2
        ;;
    --source)
        (($# >= 2)) || { rl_usage >&2; exit 2; }
        rl_source="$2"; shift 2
        ;;
    --manifest-only)
        rl_manifest_only=1; shift
        ;;
    --dry-run)
        rl_dry=1; shift
        ;;
    -h | --help)
        rl_usage; exit 0
        ;;
    --) shift; break ;;
    -*) rl_usage >&2; exit 2 ;;
    *) rl_kinds+=("$1"); shift ;;
    esac
done

cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root"; LIB_DIR="$rl_project_root/lib"
# shellcheck source=lib/bootstrap.sh
source "$LIB_DIR/bootstrap.sh"
um_load_profile snapshot

[[ -n "$rl_out" ]] && SNAPSHOT_DIR="$rl_out"

# source 标签做保守清洗，避免异常字符进入快照/日志。
rl_source="$(snapshot_safe_token "$rl_source")"
[[ -n "$rl_source" ]] || rl_source="local"

# 缺省采集全部业务快照类型。
if ((${#rl_kinds[@]} == 0)) && ((rl_manifest_only == 0)); then
    mapfile -t rl_kinds < <(snapshot_all_kinds)
fi

# 校验目标类型（manifest-only 不校验）。
if ((rl_manifest_only == 0)); then
    for _kind in "${rl_kinds[@]}"; do
        snapshot_is_known_kind "$_kind" || {
            printf 'rl-snapshot: 未知快照类型: %s\n' "$_kind" >&2
            exit 2
        }
    done
fi

# ------------------------------------------------------------
# 采集函数：每个函数只读取只读 Core，输出该快照的 data JSON 对象。
# 失败/无数据时降级为空结构，绝不因为单源不可用而让整个采集崩溃。
# ------------------------------------------------------------

collect_users() {
    local user home mp
    {
        while IFS= read -r user; do
            [[ -n "$user" ]] || continue
            home="$(get_user_home "$user" 2>/dev/null || true)"
            mp="$(get_user_mountpoint "$home" 2>/dev/null || true)"
            printf '%s\t%s\t%s\n' "$user" "$home" "$mp"
        done < <(get_managed_usernames 2>/dev/null)
    } | jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t")) as $rows
        | {users: ($rows | map({username: .[0], home: (.[1] // ""), mountpoint: (.[2] // "")})),
           count: ($rows | length)}
    '
}

collect_quota() {
    local user home mp qi used limit
    {
        while IFS= read -r user; do
            [[ -n "$user" ]] || continue
            home="$(get_user_home "$user" 2>/dev/null || true)"
            mp="$(get_user_mountpoint "$home" 2>/dev/null || true)"
            qi="$(get_user_quota_info "$user" "$mp" 2>/dev/null || printf '0:0')"
            used="${qi%%:*}"; limit="${qi##*:}"
            [[ "$used" =~ ^[0-9]+$ ]] || used=0
            [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
            printf '%s\t%s\t%s\t%s\n' "$user" "$mp" "$used" "$limit"
        done < <(get_managed_usernames 2>/dev/null)
    } | jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t")) as $rows
        | {users: ($rows | map({
              username: .[0],
              mountpoint: .[1],
              used_bytes: (.[2] | tonumber),
              limit_bytes: (.[3] | tonumber),
              has_quota: ((.[3] | tonumber) > 0),
              used_gb: (((.[2] | tonumber) / 1073741824 * 100 | round) / 100),
              limit_gb: (((.[3] | tonumber) / 1073741824 * 100 | round) / 100)
            })),
           count: ($rows | length)}
    '
}

collect_resources() {
    local user uid limits cpu mem
    {
        while IFS= read -r user; do
            [[ -n "$user" ]] || continue
            uid="$(id -u "$user" 2>/dev/null || true)"
            limits="$(get_current_resource_limits "$user" 2>/dev/null || printf ':')"
            cpu="${limits%%:*}"; mem="${limits##*:}"
            [[ "$uid" =~ ^[0-9]+$ ]] || uid=''
            printf '%s\t%s\t%s\t%s\n' "$user" "$uid" "$cpu" "$mem"
        done < <(get_managed_usernames 2>/dev/null)
    } | jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t")) as $rows
        | {users: ($rows | map({
              username: .[0],
              uid: (if (.[1] | length) > 0 then (.[1] | tonumber) else null end),
              cpu_quota: (if (.[2] | length) > 0 then .[2] else null end),
              memory_limit: (if (.[3] | length) > 0 then .[3] else null end),
              has_limits: (((.[2] | length) > 0) or ((.[3] | length) > 0))
            })),
           count: ($rows | length)}
    '
}

collect_smb() {
    local available="false" include="false" svc="unknown" line state users shares
    if smb_is_available 2>/dev/null; then available="true"; fi
    if smb_include_status 2>/dev/null; then include="true"; fi
    line="$(smb_show_status 2>/dev/null | grep -E '^smbd 服务:' | head -n1 || true)"
    if [[ -n "$line" ]]; then
        state="${line#smbd 服务: }"
        state="${state//[[:space:]]/}"
        [[ -n "$state" ]] && svc="$state"
    fi
    users="$(smb_list_users 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
    shares="$(smb_share_list 2>/dev/null | jq -R -s '
        split("\n") | map(select(length > 0))
        | map(split("|") | {name: .[0], path: (.[1] // "")})' 2>/dev/null || printf '[]')"
    jq -cn \
        --arg available "$available" \
        --arg service_active "$svc" \
        --arg include_configured "$include" \
        --argjson users "$users" \
        --argjson shares "$shares" \
        '{available: ($available == "true"),
          service_active: $service_active,
          include_configured: ($include_configured == "true"),
          users: $users,
          shares: $shares}'
}

collect_hosts() {
    host_probe_snapshot_kv 2>/dev/null | snapshot_kv_to_json
}

collect_gpu() {
    gpu_snapshot_kv 2>/dev/null | snapshot_kv_to_json
}

collect_system() {
    local hostname kernel arch uptime load1 load5 load15 memtotal memavail ncpu
    hostname="$(hostname 2>/dev/null || printf 'unknown')"
    kernel="$(uname -r 2>/dev/null || printf 'unknown')"
    arch="$(uname -m 2>/dev/null || printf 'unknown')"
    uptime="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || printf '0')"
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf '0')"
    load5="$(awk '{print $2}' /proc/loadavg 2>/dev/null || printf '0')"
    load15="$(awk '{print $3}' /proc/loadavg 2>/dev/null || printf '0')"
    memtotal="$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo 2>/dev/null || printf '0')"
    memavail="$(awk '/^MemAvailable:/ {print $2 * 1024; exit}' /proc/meminfo 2>/dev/null || printf '0')"
    ncpu="$(nproc 2>/dev/null || printf '0')"
    [[ "$uptime" =~ ^[0-9]+$ ]] || uptime=0
    for _lv in load1 load5 load15; do
        [[ "${!_lv}" =~ ^[0-9]+([.][0-9]+)?$ ]] || printf -v "$_lv" '%s' 0
    done
    [[ "$memtotal" =~ ^[0-9]+$ ]] || memtotal=0
    [[ "$memavail" =~ ^[0-9]+$ ]] || memavail=0
    [[ "$ncpu" =~ ^[0-9]+$ ]] || ncpu=0
    jq -cn \
        --arg hostname "$hostname" \
        --arg kernel "$kernel" \
        --arg arch "$arch" \
        --argjson uptime "$uptime" \
        --arg load1 "$load1" --arg load5 "$load5" --arg load15 "$load15" \
        --argjson mem_total "$memtotal" \
        --argjson mem_available "$memavail" \
        --argjson cpu_count "$ncpu" \
        --arg project_version "${USER_MANAGER_VERSION:-dev}" \
        '{hostname: $hostname, kernel_release: $kernel, arch: $arch,
          uptime_seconds: $uptime,
          loadavg: {load1: ($load1 | tonumber), load5: ($load5 | tonumber), load15: ($load15 | tonumber)},
          mem_total_bytes: $mem_total, mem_available_bytes: $mem_available,
          cpu_count: $cpu_count, project_version: $project_version}'
}

collect_audit_summary() {
    local file total today today_str recent
    file="$AUDIT_LOG_FILE"
    total=0
    today=0
    today_str="$(date +%Y-%m-%d)"
    recent='[]'
    if [[ -r "$file" ]]; then
        total="$(wc -l <"$file" 2>/dev/null || printf '0')"
        total="${total//[[:space:]]/}"
        today="$(grep -c "^$today_str" "$file" 2>/dev/null || true)"
        [[ "$today" =~ ^[0-9]+$ ]] || today=0
        # 仅抽取结构化列：timestamp|user|action|target|result；不包含 details（潜在敏感）。
        recent="$(tail -n 200 "$file" 2>/dev/null | awk -F'|' '{
            ts = $1
            gsub(/^[ \t]+|[ \t]+$/, "", ts)
            if (ts == "") next
            printf "%s\t%s\t%s\t%s\t%s\n", ts, $6, $7, $8, $9
        }' | tail -n 50 | jq -R -s '
            split("\n") | map(select(length > 0))
            | map(split("\t") | {timestamp: .[0], user: .[1], action: .[2], target: .[3], result: .[4]})
        ' 2>/dev/null || printf '[]')"
    fi
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    jq -cn \
        --argjson total "$total" \
        --argjson today "$today" \
        --argjson recent "$recent" \
        --arg source_file "$file" \
        '{total_records: $total, today_records: $today, recent: $recent, source_file: $source_file}'
}

# ------------------------------------------------------------
# 调度
# ------------------------------------------------------------
declare -a rl_failed=()
emit_kind() {
    local kind="$1" func data_json
    func="collect_${kind//-/_}"
    if ! declare -F "$func" >/dev/null 2>&1; then
        printf 'rl-snapshot: 缺少采集函数: %s\n' "$func" >&2
        rl_failed+=("$kind")
        return 1
    fi
    if ! data_json="$("$func" 2>/dev/null)"; then
        printf 'rl-snapshot: %s 采集失败\n' "$kind" >&2
        rl_failed+=("$kind")
        return 1
    fi
    # 采集函数必须输出合法的 JSON 对象；否则视为失败。
    if ! printf '%s' "$data_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf 'rl-snapshot: %s 采集输出非 JSON 对象\n' "$kind" >&2
        rl_failed+=("$kind")
        return 1
    fi
    if ((rl_dry == 1)); then
        snapshot_build_envelope "$kind" "$rl_source" "$(snapshot_kind_threshold "$kind")" "$data_json"
        return 0
    fi
    snapshot_emit "$kind" "$rl_source" "$data_json"
}

rc=0
if ((rl_manifest_only == 1)); then
    snapshot_manifest_write || rc=1
else
    for kind in "${rl_kinds[@]}"; do
        emit_kind "$kind" || rc=1
    done
    if ((rl_dry == 0)); then
        snapshot_manifest_write || rc=1
    fi
fi

if ((${#rl_failed[@]} > 0)); then
    printf 'rl-snapshot: 失败类型: %s\n' "${rl_failed[*]}" >&2
fi
exit "$rc"
