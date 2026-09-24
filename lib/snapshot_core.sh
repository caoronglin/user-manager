#!/bin/bash
# snapshot_core.sh - Web 只读快照契约：schema、secret scrub、原子写、校验、freshness
#
# 定位：本模块是 Web 控制台 P0「Snapshot Contract + Web Security Boundary」的核心。
# 它只被「可信采集器」(root 系统服务 / CLI) 调用，用于把只读 Core 的查询结果收敛为
# 版本化、脱敏、原子落盘的 JSON 快照。Web 服务 (umweb) 仅只读这些文件，绝不执行本模块。
#
# 安全边界（详见 docs/WEB_SECURITY_BOUNDARY.md）：
#   - 本模块不执行任何系统写操作；不调用 priv_exec / action_run / useradd / setquota ...；
#   - 所有进入快照的字符串在落盘前经过 snapshot_scrub 脱敏；
#   - 快照文件原子生成（write temp + fsync + rename），umweb 只读 (root:umweb 0640)。
#
# 本模块不主动设置 shell 选项，由调用方（采集器脚本 / 测试）决定。

# schema 版本：任何不兼容的字段或语义变更都必须递增。
readonly SNAPSHOT_SCHEMA_VERSION=1
readonly SNAPSHOT_PROTOCOL="user-manager-snapshot-v1"
readonly SNAPSHOT_GENERATOR="user-manager"

# 快照存储目录（部署默认 /var/lib/user-manager-web/snapshots；测试/开发可覆盖）。
SNAPSHOT_DIR="${USER_MANAGER_SNAPSHOT_DIR:-/var/lib/user-manager-web/snapshots}"
# 采集完成后文件属主/属组（仅 EUID=0 时生效；umweb 只读这些文件）。
SNAPSHOT_OWNER="${USER_MANAGER_SNAPSHOT_OWNER:-root}"
SNAPSHOT_GROUP="${USER_MANAGER_SNAPSHOT_GROUP:-umweb}"

# ============================================================
# 新鲜度阈值（秒）——与 plan.md 7.5 对齐
#   system 60 / users 300 / quota 300 / resources 60 / hosts+gpu 120 / audit 30
# ============================================================
snapshot_kind_threshold() {
    case "$1" in
    system) printf '60\n' ;;
    users | quota | smb) printf '300\n' ;;
    resources) printf '60\n' ;;
    logs) printf '60\n' ;;
    hosts | gpu) printf '120\n' ;;
    audit-summary) printf '30\n' ;;
    reports) printf '300\n' ;;
    manifest) printf '120\n' ;;
    *) return 1 ;;
    esac
}

# 全部业务快照类型（manifest 单独处理，不在此列）。
snapshot_all_kinds() {
    printf '%s\n' users quota resources smb hosts gpu system audit-summary logs reports
}

# 供 atomic_install 使用的文件名安全校验：只允许小写字母与连字符，阻断路径穿越。
snapshot_is_filename_safe() {
    [[ "$1" =~ ^[a-z][a-z-]*$ ]]
}

# 业务快照类型校验（用于采集器目标参数）。
snapshot_is_known_kind() {
    local kind="$1"
    snapshot_is_filename_safe "$kind" || return 1
    snapshot_kind_threshold "$kind" >/dev/null 2>&1
}

snapshot_now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# 把任意字符串清洗为保守的 ASCII token（供 source/host_id 等标签使用）。
# 仅保留 [A-Za-z0-9._-]，其余字符替换为 _，长度上限 64；空结果返回空串。
snapshot_safe_token() {
    local value="$1" output='' char i
    local LC_ALL=C
    for ((i = 0; i < ${#value} && i < 64; i++)); do
        char="${value:i:1}"
        case "$char" in
        [A-Za-z0-9._-]) output+="$char" ;;
        *) output+='_' ;;
        esac
    done
    printf '%s\n' "$output"
}

# ============================================================
# Secret scrub：按 key 名与 value 形态递归脱敏
# ============================================================
# 输出 jq 函数库（def ...），供 build_envelope 内联使用。
snapshot_scrub_jq_lib() {
    cat <<'JQ'
def is_secret_key($k):
  ($k | ascii_downcase) as $kk
  | ($kk | test("password|passwd|passphrase|secret|token|webhook|credential|authorization|totp"))
    or ($kk | test("api[_-]?key|private[_-]?key|secret[_-]?key"))
    or ($kk | test("(^|_)session[_-]?id($|_)"));
def scrub_str:
  if test("https://qyapi\\.weixin\\.qq\\.com/cgi-bin/webhook/send\\?key=") then "***REDACTED_WEBHOOK***"
  elif test("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----") then "***REDACTED_KEY***"
  elif test("AKIA[0-9A-Z]{16}") then "***REDACTED_KEY***"
  else . end;
def snapshot_scrub:
  if type == "object" then
    with_entries(
      if is_secret_key(.key) then .value = "***REDACTED***"
      else .value |= snapshot_scrub
      end
    )
  elif type == "array" then map(snapshot_scrub)
  elif type == "string" then scrub_str
  else . end;
JQ
}

# 构造快照信封：$1=kind $2=source $3=threshold $4=data_json
# 输出经过 scrub 的完整信封 JSON。
snapshot_build_envelope() {
    local kind="$1" source="$2" threshold="$3" data_json="$4" program
    program="$(snapshot_scrub_jq_lib)"'
{
  schema_version: $schema_version,
  protocol: $protocol,
  kind: $kind,
  generator: $generator,
  source: $source,
  generated_at: $generated_at,
  threshold_seconds: $threshold,
  data: ($data | snapshot_scrub)
}'
    jq -cn \
        --argjson schema_version "$SNAPSHOT_SCHEMA_VERSION" \
        --arg protocol "$SNAPSHOT_PROTOCOL" \
        --arg kind "$kind" \
        --arg generator "$SNAPSHOT_GENERATOR" \
        --arg source "$source" \
        --arg generated_at "$(snapshot_now_rfc3339)" \
        --argjson threshold "$threshold" \
        --argjson data "$data_json" \
        "$program"
}

# ============================================================
# Schema 校验：从 stdin 读信封 JSON，校验必需字段/类型与受支持的 schema_version
# 通过返回 0；否则返回非 0。
# ============================================================
snapshot_validate_json() {
    local program='
      (type == "object")
      and (.schema_version | type == "number")
      and (.schema_version == $ver)
      and (.protocol | type == "string")
      and (.kind | type == "string")
      and (.generated_at | type == "string")
      and ((.generated_at | length) > 0)
      and (.generator | type == "string")
      and (.source | type == "string")
      and ((.source | length) > 0)
      and (.threshold_seconds | type == "number")
      and (has("data"))
    '
    jq -e --argjson ver "$SNAPSHOT_SCHEMA_VERSION" "$program" >/dev/null 2>&1
}

# ============================================================
# 目录与属主
# ============================================================
snapshot_resolve_safe_path() {
    local path="$1" current='/' component physical_pwd
    local -a components

    [[ -n "$path" ]] || return 1
    if [[ "$path" != /* ]]; then
        physical_pwd="$(pwd -P)" || return 1
        path="${physical_pwd%/}/$path"
    fi

    IFS='/' read -r -a components <<<"$path"
    for component in "${components[@]}"; do
        case "$component" in
        '' | .) continue ;;
        ..)
            current="${current%/*}"
            [[ -n "$current" ]] || current='/'
            ;;
        *)
            current="${current%/}/$component"
            [[ -L "$current" ]] && return 1
            ;;
        esac
    done

    printf '%s\n' "$current"
}

snapshot_enter_safe_dir() {
    local expected="$1" actual
    cd -P -- "$expected" || return 1
    actual="$(pwd -P)" || return 1
    [[ "$actual" == "$expected" ]]
}

snapshot_apply_owner_for_uid() {
    local path="$1" uid="$2" grp="$SNAPSHOT_GROUP"
    # 非 root 的开发/测试调用不尝试改变 owner；root 必须确保契约的属主属组。
    [[ "$uid" == "0" ]] || return 0
    if ! getent group "$grp" >/dev/null 2>&1; then
        printf 'snapshot: 目标组不存在，无法设置快照属主: %s\n' "$grp" >&2
        return 1
    fi
    if ! chown "${SNAPSHOT_OWNER}:${grp}" -- "$path"; then
        printf 'snapshot: 无法设置快照属主 %s:%s: %s\n' "$SNAPSHOT_OWNER" "$grp" "$path" >&2
        return 1
    fi
}

snapshot_apply_owner() {
    local uid="${EUID:-}"
    [[ -n "$uid" ]] || uid="$(id -u)" || return 1
    snapshot_apply_owner_for_uid "$1" "$uid"
}

snapshot_ensure_dir() (
    local dir="$1" safe_dir
    if ! safe_dir="$(snapshot_resolve_safe_path "$dir")"; then
        printf 'snapshot: 快照目录包含符号链接或路径无效: %s\n' "$dir" >&2
        return 1
    fi
    if [[ "$safe_dir" == '/' ]]; then
        printf 'snapshot: 拒绝将根目录用作快照目录\n' >&2
        return 1
    fi

    if [[ ! -d "$safe_dir" ]] && ! mkdir -p -- "$safe_dir"; then
        printf 'snapshot: 无法创建快照目录: %s\n' "$safe_dir" >&2
        return 1
    fi
    # 进入目录后通过当前工作目录句柄操作，避免随后路径被替换为符号链接。
    if ! snapshot_enter_safe_dir "$safe_dir"; then
        printf 'snapshot: 快照目录不是安全目录: %s\n' "$safe_dir" >&2
        return 1
    fi
    snapshot_apply_owner . || return 1
    if ! chmod 0750 -- .; then
        printf 'snapshot: 无法设置快照目录权限 0750: %s\n' "$safe_dir" >&2
        return 1
    fi
)

# ============================================================
# 原子安装：$1=kind，信封 JSON 从 stdin 读入
#   write temp -> chown(root:umweb) -> chmod 0640 -> sync -> rename -> sync dir
# ============================================================
snapshot_atomic_install() (
    local kind="$1" dir file tmp='' writer_pid=''

    snapshot_cleanup_temp() {
        if [[ -n "$writer_pid" ]]; then
            kill "$writer_pid" 2>/dev/null || true
            wait "$writer_pid" 2>/dev/null || true
            writer_pid=''
        fi
        [[ -n "$tmp" ]] && rm -f -- "$tmp"
    }
    trap 'snapshot_cleanup_temp || true' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    snapshot_is_filename_safe "$kind" || {
        printf 'snapshot: 非法快照类型名: %s\n' "$kind" >&2
        exit 2
    }
    if ! dir="$(snapshot_resolve_safe_path "$SNAPSHOT_DIR")"; then
        printf 'snapshot: 快照目录包含符号链接或路径无效: %s\n' "$SNAPSHOT_DIR" >&2
        exit 1
    fi
    [[ "$dir" != '/' ]] || {
        printf 'snapshot: 拒绝将根目录用作快照目录\n' >&2
        exit 1
    }
    snapshot_ensure_dir "$dir" || {
        printf 'snapshot: 无法创建快照目录: %s\n' "$dir" >&2
        exit 1
    }
    # 保持工作目录 fd，后续目标/temp/sync 操作均使用相对路径，避免目录被替换后跟随链接。
    if ! snapshot_enter_safe_dir "$dir"; then
        printf 'snapshot: 快照目录在打开时已被替换: %s\n' "$dir" >&2
        exit 1
    fi
    snapshot_apply_owner . || exit 1
    if ! chmod 0750 -- .; then
        printf 'snapshot: 无法设置快照目录权限 0750: %s\n' "$dir" >&2
        exit 1
    fi
    file="${kind}.json"
    if [[ -L "$file" || (-e "$file" && ! -f "$file") ]]; then
        printf 'snapshot: 拒绝替换符号链接或非普通快照文件: %s\n' "$file" >&2
        exit 1
    fi
    if ! command -v sync >/dev/null 2>&1; then
        printf 'snapshot: 缺少 sync，无法保证快照持久化\n' >&2
        exit 1
    fi
    tmp="$(mktemp -- "./.${kind}.json.XXXXXX")" || {
        printf 'snapshot: 无法创建临时快照文件: %s\n' "$dir" >&2
        exit 1
    }
    cat <&0 >"$tmp" &
    writer_pid=$!
    if wait "$writer_pid"; then
        writer_pid=''
    else
        writer_pid=''
        printf 'snapshot: 写入临时快照文件失败: %s\n' "$tmp" >&2
        exit 1
    fi
    snapshot_apply_owner "$tmp" || exit 1
    if ! chmod 0640 -- "$tmp"; then
        printf 'snapshot: 无法设置快照文件权限 0640: %s\n' "$tmp" >&2
        exit 1
    fi
    if ! sync -- "$tmp"; then
        printf 'snapshot: 同步快照文件失败: %s\n' "$tmp" >&2
        exit 1
    fi
    # 目标可能在写入期间被替换；绝不覆盖指向其他路径的符号链接。
    if [[ -L "$file" || (-e "$file" && ! -f "$file") ]]; then
        printf 'snapshot: 拒绝替换符号链接或非普通快照文件: %s\n' "$file" >&2
        exit 1
    fi
    if ! mv -fT -- "$tmp" "$file"; then
        printf 'snapshot: 原子安装快照失败: %s\n' "$file" >&2
        exit 1
    fi
    tmp=''
    if ! sync -- .; then
        printf 'snapshot: 同步快照目录失败（文件已安装但持久化未确认）: %s\n' "$dir" >&2
        exit 1
    fi
    exit 0
)

# 高级封装：构造 -> 校验 -> 原子安装。$1=kind $2=source $3=data_json
snapshot_emit() {
    local kind="$1" source="$2" data_json="$3" threshold envelope
    threshold="$(snapshot_kind_threshold "$kind")" || {
        printf 'snapshot: 未知快照类型: %s\n' "$kind" >&2
        return 2
    }
    envelope="$(snapshot_build_envelope "$kind" "$source" "$threshold" "$data_json")" || return 1
    if ! printf '%s\n' "$envelope" | snapshot_validate_json; then
        printf 'snapshot: %s 信封未通过 schema 校验，拒绝落盘\n' "$kind" >&2
        return 1
    fi
    printf '%s\n' "$envelope" | snapshot_atomic_install "$kind"
}

# ============================================================
# Freshness：$1=kind [$2=now_epoch]
# 输出 {present, fresh, age_seconds, generated_at, threshold_seconds}。
# age 由读取时刻计算，不在生成时固化，避免旧数据被伪装成实时。
# ============================================================
snapshot_freshness_json() {
    local kind="$1" now="${2:-}" file="" gen="" dir=""
    local threshold='' ge='' age='' fresh='' present="false"
    now="${now:-$(date -u +%s)}"
    if snapshot_is_filename_safe "$kind" &&
        dir="$(snapshot_resolve_safe_path "$SNAPSHOT_DIR" 2>/dev/null)"; then
        file="$dir/${kind}.json"
    fi
    if [[ -f "$file" && ! -L "$file" && -r "$file" ]]; then
        gen="$(jq -r '.generated_at // empty' "$file" 2>/dev/null || true)"
        threshold="$(jq -r '.threshold_seconds // empty' "$file" 2>/dev/null || true)"
        [[ "$threshold" =~ ^[0-9]+$ ]] || threshold="$(snapshot_kind_threshold "$kind" 2>/dev/null || echo 0)"
    fi
    if [[ -n "$gen" ]]; then
        present="true"
        ge="$(date -u -d "$gen" +%s 2>/dev/null || echo 0)"
        age=$((now - ge))
        ((age < 0)) && age=0
        if ((age <= threshold)); then fresh="true"; else fresh="false"; fi
        jq -cn \
            --arg present "$present" --arg fresh "$fresh" \
            --argjson age "$age" --arg gen "$gen" --argjson threshold "$threshold" \
            '{present: ($present == "true"), fresh: ($fresh == "true"),
              age_seconds: $age, generated_at: $gen, threshold_seconds: $threshold}'
    else
        [[ "$threshold" =~ ^[0-9]+$ ]] || threshold="$(snapshot_kind_threshold "$kind" 2>/dev/null || echo 0)"
        jq -cn --argjson threshold "$threshold" \
            '{present: false, fresh: false, age_seconds: null, generated_at: null,
              threshold_seconds: $threshold}'
    fi
}

# ============================================================
# Manifest：聚合各快照的新鲜度元数据（不含 data、不含 secret），供前端全局数据状态使用。
# ============================================================
snapshot_manifest_write() {
    local dir entries overall envelope kind entry
    dir="$SNAPSHOT_DIR"
    snapshot_ensure_dir "$dir" || return 1
    local -a kinds
    mapfile -t kinds < <(snapshot_all_kinds)
    entries='[]'
    for kind in "${kinds[@]}"; do
        entry="$(snapshot_freshness_json "$kind")" || entry='{"present":false}'
        entry="$(jq -c --arg kind "$kind" '. + {kind: $kind}' <<<"$entry")"
        entries="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$entries")"
    done
    overall="$(jq -r '
        if length == 0 then "unavailable"
        elif all(.present and .fresh) then "fresh"
        elif any(.present and .fresh) then "partial"
        elif any(.present) then "stale"
        else "unavailable" end
    ' <<<"$entries")"
    envelope="$(jq -cn \
        --argjson schema_version "$SNAPSHOT_SCHEMA_VERSION" \
        --arg protocol "$SNAPSHOT_PROTOCOL" \
        --arg generator "$SNAPSHOT_GENERATOR" \
        --arg source "manifest" \
        --arg generated_at "$(snapshot_now_rfc3339)" \
        --arg overall "$overall" \
        --argjson snapshots "$entries" \
        '{schema_version: $schema_version, protocol: $protocol, generator: $generator,
          source: $source, generated_at: $generated_at, overall: $overall,
          snapshots: $snapshots}')"
    printf '%s\n' "$envelope" | snapshot_atomic_install manifest
}

# ============================================================
# key=value 只读协议输出 -> 结构化 JSON
#   - 普通 "k=v" 变为标量字段；
#   - "gpu.N=field=val;field=val" / "process.N=..." 收敛为 gpus[] / processes[]。
# 用于复用 host_probe_core.sh / gpu_core.sh 的既有只读协议，避免重复实现采集逻辑。
# ============================================================
snapshot_kv_to_json() {
    jq -R -s '
      def parse_sub:
        split(";") | map(select(length > 0))
        | map(split("=") as $p | {($p[0]): ($p[1:] | join("="))})
        | add // {};
      split("\n")
      | map(select(length > 0)) as $lines
      | reduce ($lines[]
                | . as $line
                | (index("=")) as $i
                | {k: ($line[:$i]), v: ($line[$i + 1:])}) as $e (
          {gpus: [], processes: []};
          if ($e.k | test("^gpu\\.[0-9]+$")) then .gpus += [($e.v | parse_sub)]
          elif ($e.k | test("^process\\.[0-9]+$")) then .processes += [($e.v | parse_sub)]
          else .[$e.k] = $e.v
          end
        )
      | (if (.gpus | length) == 0 then del(.gpus) else . end)
      | (if (.processes | length) == 0 then del(.processes) else . end)
    '
}
