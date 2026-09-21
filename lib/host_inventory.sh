#!/bin/bash
# host_inventory.sh - 非执行式主机清单解析、校验与目标展开

HOST_INVENTORY_HEADER='host_id|display_name|provider|address|port|user|groups|tags|enabled'
HOST_INVENTORY_MAX_BYTES="${USER_MANAGER_HOSTS_MAX_BYTES:-65536}"
HOST_INVENTORY_MAX_ROWS="${USER_MANAGER_HOSTS_MAX_ROWS:-256}"
HOST_INVENTORY_TARGET_LIMIT="${USER_MANAGER_HOST_TARGET_LIMIT:-20}"

declare -p HOST_INVENTORY_IDS >/dev/null 2>&1 || declare -ag HOST_INVENTORY_IDS=()
declare -p HOST_DISPLAY_NAME >/dev/null 2>&1 || declare -Ag HOST_DISPLAY_NAME=()
declare -p HOST_PROVIDER >/dev/null 2>&1 || declare -Ag HOST_PROVIDER=()
declare -p HOST_ADDRESS >/dev/null 2>&1 || declare -Ag HOST_ADDRESS=()
declare -p HOST_PORT >/dev/null 2>&1 || declare -Ag HOST_PORT=()
declare -p HOST_USER >/dev/null 2>&1 || declare -Ag HOST_USER=()
declare -p HOST_GROUPS >/dev/null 2>&1 || declare -Ag HOST_GROUPS=()
declare -p HOST_TAGS >/dev/null 2>&1 || declare -Ag HOST_TAGS=()
declare -p HOST_ENABLED >/dev/null 2>&1 || declare -Ag HOST_ENABLED=()

_host_inventory_error() { printf '主机清单错误: %s\n' "$1" >&2; }

_host_inventory_reset() {
    HOST_INVENTORY_IDS=(); HOST_DISPLAY_NAME=(); HOST_PROVIDER=(); HOST_ADDRESS=(); HOST_PORT=()
    HOST_USER=(); HOST_GROUPS=(); HOST_TAGS=(); HOST_ENABLED=()
}

_host_inventory_add_builtin_local() {
    HOST_INVENTORY_IDS=(local)
    HOST_DISPLAY_NAME[local]='当前主机'; HOST_PROVIDER[local]='local'; HOST_ADDRESS[local]=''
    HOST_PORT[local]=''; HOST_USER[local]=''; HOST_GROUPS[local]='local'
    HOST_TAGS[local]='builtin'; HOST_ENABLED[local]='true'
}

_host_inventory_acl_is_safe() {
    local path="$1" acl line
    command -v getfacl >/dev/null 2>&1 || return 0
    acl="$(getfacl -cp -- "$path" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        case "$line" in user:?*:*w* | group:?*:*w*) return 1 ;; esac
    done <<<"$acl"
    return 0
}

_host_inventory_mode_is_safe() {
    local mode="$1"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (((8#$mode & 0022) == 0))
}

_host_inventory_parent_chain_is_safe() {
    local path="$1" parent owner mode mode_value
    parent="$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P)" || return 1
    while [[ -n "$parent" ]]; do
        read -r owner mode < <(stat -Lc '%u %a' -- "$parent" 2>/dev/null) || return 1
# 清单文件本身必须由当前用户或 root 拥有；父级可能跨越只读/受管挂载根。
        # 对此类祖先仍严格拒绝任何组/其他可写权限或不安全 ACL。
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        if ((mode_value & 0022)); then
            ((owner == 0 && (mode_value & 01000) != 0)) || return 1
        fi
        _host_inventory_acl_is_safe "$parent" || return 1
        [[ "$parent" == "/" ]] && break
        parent="$(dirname -- "$parent")"
    done
    return 0
}

_host_inventory_fd_real_path() {
    local fd="${1:-}" path
    [[ "$fd" =~ ^[0-9]+$ ]] || return 1
    path="$(readlink -f -- "/proc/$$/fd/$fd" 2>/dev/null)" || return 1
    [[ -n "$path" && "$path" != *' (deleted)' && -e "$path" && ! -L "$path" ]] || return 1
    printf '%s\n' "$path"
}

# 仅对已经打开的描述符做元数据校验，避免在校验和使用之间重新解析路径。
_host_inventory_validate_trusted_fd() {
    local fd="${1:-}" max_bytes="${2:-$HOST_INVENTORY_MAX_BYTES}"
    local path owner mode size file_type
    path="$(_host_inventory_fd_real_path "$fd")" || { _host_inventory_error "无法解析已打开文件"; return 1; }
    read -r owner mode size file_type < <(stat -Lc '%u %a %s %F' -- "/proc/$$/fd/$fd" 2>/dev/null) || {
        _host_inventory_error "无法读取文件元数据"; return 1;
    }
    [[ "$file_type" == "regular file" || "$file_type" == "普通文件" ]] || {
        _host_inventory_error "必须是普通文件"; return 1;
    }
    [[ "$owner" == "${EUID:-$(id -u)}" || "$owner" == "0" ]] || {
        _host_inventory_error "文件所有者不受信任"; return 1;
    }
    _host_inventory_mode_is_safe "$mode" || { _host_inventory_error "文件不得由组或其他用户写入"; return 1; }
    [[ "$size" =~ ^[0-9]+$ ]] && ((size <= max_bytes)) || {
        _host_inventory_error "文件超过允许大小"; return 1;
    }
    _host_inventory_acl_is_safe "$path" || { _host_inventory_error "扩展 ACL 不安全"; return 1; }
    _host_inventory_parent_chain_is_safe "$path" || { _host_inventory_error "父目录链不受信任"; return 1; }
}

# 打开后再校验，调用方必须在完成读取后关闭返回的 fd。
_host_inventory_open_trusted_fd() {
    local path="${1:-}" max_bytes="${2:-$HOST_INVENTORY_MAX_BYTES}" output_name="${3:-}"
    local opened_fd
    [[ -n "$path" && -n "$output_name" && -e "$path" && ! -L "$path" ]] || {
        _host_inventory_error "文件不存在或为符号链接"; return 1;
    }
    exec {opened_fd}<"$path" || { _host_inventory_error "无法打开文件"; return 1; }
    if ! _host_inventory_validate_trusted_fd "$opened_fd" "$max_bytes"; then
        exec {opened_fd}<&-
        return 1
    fi
    printf -v "$output_name" '%s' "$opened_fd"
}

# 将已验证的文件描述符复制到 /tmp 下私有目录中的有界快照。适用于会自行重开路径的消费者（OpenSSH）。
_host_inventory_snapshot_trusted_file() {
    local path="${1:-}" max_bytes="${2:-$HOST_INVENTORY_MAX_BYTES}"
    local output_file_name="${3:-}" output_dir_name="${4:-}" fd snapshot_dir snapshot size limit
    [[ -n "$output_file_name" && -n "$output_dir_name" ]] || return 1
    _host_inventory_open_trusted_fd "$path" "$max_bytes" fd || return 1
    umask 077
    snapshot_dir="$(mktemp -d /tmp/user-manager-trusted-file.XXXXXX)" || { exec {fd}<&-; return 1; }
    snapshot="$snapshot_dir/content"
    limit=$((max_bytes + 1))
    if ! LC_ALL=C command -p head -c "$limit" <&"$fd" >"$snapshot"; then
        exec {fd}<&-; rm -rf -- "$snapshot_dir"; return 1
    fi
    exec {fd}<&-
    chmod 600 -- "$snapshot" 2>/dev/null || { rm -rf -- "$snapshot_dir"; return 1; }
    size="$(stat -Lc '%s' -- "$snapshot" 2>/dev/null || printf '0')"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || ((size > max_bytes)); then
        rm -rf -- "$snapshot_dir"; return 1
    fi
    printf -v "$output_file_name" '%s' "$snapshot"
    printf -v "$output_dir_name" '%s' "$snapshot_dir"
}

host_inventory_validate_trusted_file() {
    local fd
    _host_inventory_open_trusted_fd "${1:-}" "${2:-$HOST_INVENTORY_MAX_BYTES}" fd || return 1
    exec {fd}<&-
}

_host_inventory_valid_list() {
    local value="$1"
    [[ -z "$value" || "$value" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]
}

_host_inventory_valid_address() {
    local address="$1"
    local LC_ALL=C
    [[ -n "$address" && ${#address} -le 255 ]] || return 1
    [[ "$address" != -* && "$address" != *'@'* && "$address" != *'..'* ]] || return 1
    [[ "$address" != *$' '* && "$address" != *$'\t'* && "$address" != *$'\r'* ]] || return 1
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ ^[0-9A-Fa-f:.]+(%[A-Za-z0-9._-]+)?$ ]]
    elif ((${#address} == 1)); then
        [[ "$address" =~ ^[A-Za-z0-9]$ ]]
    else
        [[ "$address" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
    fi
}

_host_inventory_valid_user() {
    local LC_ALL=C
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]]
}

_host_inventory_normalize_enabled() {
    case "$1" in 1 | true | yes) printf 'true\n' ;; 0 | false | no) printf 'false\n' ;; *) return 1 ;; esac
}

_host_inventory_commit() {
    local -n src_ids="$1" src_display="$2" src_provider="$3" src_address="$4" src_port="$5"
    local -n src_user="$6" src_groups="$7" src_tags="$8" src_enabled="$9"
    local id
    _host_inventory_reset
    HOST_INVENTORY_IDS=("${src_ids[@]}")
    for id in "${src_ids[@]}"; do
        HOST_DISPLAY_NAME["$id"]="${src_display[$id]}"; HOST_PROVIDER["$id"]="${src_provider[$id]}"
        HOST_ADDRESS["$id"]="${src_address[$id]}"; HOST_PORT["$id"]="${src_port[$id]}"
        HOST_USER["$id"]="${src_user[$id]}"; HOST_GROUPS["$id"]="${src_groups[$id]}"
        HOST_TAGS["$id"]="${src_tags[$id]}"; HOST_ENABLED["$id"]="${src_enabled[$id]}"
    done
}

host_inventory_load() {
    local explicit=0 file line marker fd
    local line_number=0 data_rows=0 header_seen=0 local_count=0
    local id display provider address port user groups tags enabled
    local -a ids=()
    local -A displays=() providers=() addresses=() ports=() users=() groups_map=() tags_map=() enabled_map=()

    _host_inventory_reset
    if (($# > 0)); then explicit=1; file="$1"; else file="${USER_MANAGER_HOSTS_FILE:-${DATA_DIR:-./data}/hosts.conf}"; fi
    if [[ ! -e "$file" ]]; then
        if ((explicit)); then _host_inventory_error "显式指定的文件不存在"; return 1; fi
        _host_inventory_add_builtin_local
        return 0
    fi
    _host_inventory_open_trusted_fd "$file" "$HOST_INVENTORY_MAX_BYTES" fd || return 1

    while IFS= read -r line <&$fd || [[ -n "$line" ]]; do
        ((line_number += 1))
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ ${#line} -le 1024 ]] || { _host_inventory_error "第 $line_number 行过长"; exec {fd}<&-; return 1; }
        [[ "$line" != *$'\r'* && "$line" != *$'\t'* ]] || {
            _host_inventory_error "第 $line_number 行包含控制字符"; exec {fd}<&-; return 1;
        }
        if ((header_seen == 0)); then
            [[ "$line" == "$HOST_INVENTORY_HEADER" ]] || {
                _host_inventory_error "表头不受支持"; exec {fd}<&-; return 1;
            }
            header_seen=1
            continue
        fi
        ((data_rows += 1))
        ((data_rows <= HOST_INVENTORY_MAX_ROWS)) || {
            _host_inventory_error "主机条目超过上限"; exec {fd}<&-; return 1;
        }
        IFS='|' read -r id display provider address port user groups tags enabled marker <<<"$line|__UM_END__"
        [[ "$marker" == "__UM_END__" ]] || {
            _host_inventory_error "第 $line_number 行字段数量错误"; exec {fd}<&-; return 1;
        }
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
            _host_inventory_error "第 $line_number 行 host_id 非法"; exec {fd}<&-; return 1;
        }
        [[ -z "${providers[$id]:-}" ]] || { _host_inventory_error "host_id 重复"; exec {fd}<&-; return 1; }
        [[ ${#display} -le 128 && ${#groups} -le 256 && ${#tags} -le 256 ]] || {
            _host_inventory_error "第 $line_number 行字段过长"; exec {fd}<&-; return 1;
        }
        _host_inventory_valid_list "$groups" && _host_inventory_valid_list "$tags" || {
            _host_inventory_error "第 $line_number 行 groups/tags 非法"; exec {fd}<&-; return 1;
        }
        enabled="$(_host_inventory_normalize_enabled "$enabled")" || {
            _host_inventory_error "第 $line_number 行 enabled 非法"; exec {fd}<&-; return 1;
        }
        case "$provider" in
        local)
            [[ "$id" == "local" && -z "$address" && -z "$port" && -z "$user" ]] || {
                _host_inventory_error "本机条目不得携带远端连接字段"; exec {fd}<&-; return 1;
            }
            ((local_count += 1)); ((local_count == 1)) || {
                _host_inventory_error "本机条目重复"; exec {fd}<&-; return 1;
            }
            ;;
        ssh)
            if [[ "$id" == "local" ]] || ! _host_inventory_valid_address "$address" ||
                ! _host_inventory_valid_user "$user" || [[ ! "$port" =~ ^[0-9]+$ ]] ||
                ((10#$port < 1 || 10#$port > 65535)); then
                _host_inventory_error "第 $line_number 行 SSH 连接字段非法"; exec {fd}<&-; return 1
            fi
            ;;
        *) _host_inventory_error "第 $line_number 行 provider 非法"; exec {fd}<&-; return 1 ;;
        esac
        [[ -n "$display" ]] || display="$id"
        ids+=("$id")
        displays["$id"]="$display"; providers["$id"]="$provider"; addresses["$id"]="$address"
        ports["$id"]="$port"; users["$id"]="$user"; groups_map["$id"]="$groups"
        tags_map["$id"]="$tags"; enabled_map["$id"]="$enabled"
    done
    exec {fd}<&-
    ((header_seen == 1 && data_rows > 0)) || { _host_inventory_error "清单没有主机条目"; return 1; }
    _host_inventory_commit ids displays providers addresses ports users groups_map tags_map enabled_map
}

host_inventory_get() {
    local id="${1:-}" field="${2:-}"
    [[ -n "$id" && -n "${HOST_PROVIDER[$id]:-}" ]] || return 1
    case "$field" in
    display_name) printf '%s\n' "${HOST_DISPLAY_NAME[$id]}" ;; provider) printf '%s\n' "${HOST_PROVIDER[$id]}" ;;
    address) printf '%s\n' "${HOST_ADDRESS[$id]}" ;; port) printf '%s\n' "${HOST_PORT[$id]}" ;;
    user) printf '%s\n' "${HOST_USER[$id]}" ;; groups) printf '%s\n' "${HOST_GROUPS[$id]}" ;;
    tags) printf '%s\n' "${HOST_TAGS[$id]}" ;; enabled) printf '%s\n' "${HOST_ENABLED[$id]}" ;; *) return 1 ;;
    esac
}

host_inventory_list() {
    local id
    printf '%s\n' "$HOST_INVENTORY_HEADER"
    for id in "${HOST_INVENTORY_IDS[@]}"; do
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$id" "${HOST_DISPLAY_NAME[$id]}" "${HOST_PROVIDER[$id]}" "${HOST_ADDRESS[$id]}" \
            "${HOST_PORT[$id]}" "${HOST_USER[$id]}" "${HOST_GROUPS[$id]}" "${HOST_TAGS[$id]}" \
            "${HOST_ENABLED[$id]}"
    done
}

_host_inventory_in_group() {
    local groups="$1" wanted="$2" group
    local IFS=','
    for group in $groups; do [[ "$group" == "$wanted" ]] && return 0; done
    return 1
}

host_inventory_resolve() {
    local selector="${1:-local}" id wanted count=0
    case "$selector" in
    all) wanted='' ;;
    group:*) wanted="${selector#group:}"; [[ "$wanted" =~ ^[A-Za-z0-9._-]+$ ]] || return 1 ;;
    host:*) wanted="${selector#host:}"; [[ "$wanted" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1 ;;
    *) wanted="$selector"; [[ "$wanted" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1 ;;
    esac
    for id in "${HOST_INVENTORY_IDS[@]}"; do
        [[ "${HOST_ENABLED[$id]:-false}" == "true" ]] || continue
        case "$selector" in
        all) ;; group:*) _host_inventory_in_group "${HOST_GROUPS[$id]}" "$wanted" || continue ;;
        host:*) [[ "$id" == "$wanted" ]] || continue ;; *) [[ "$id" == "$wanted" ]] || continue ;;
        esac
        ((count += 1))
        ((count <= HOST_INVENTORY_TARGET_LIMIT)) || { _host_inventory_error "目标主机超过单次上限"; return 1; }
        printf '%s\n' "$id"
    done
    ((count > 0))
}
