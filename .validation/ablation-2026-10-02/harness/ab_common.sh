#!/bin/bash
# ab_common.sh - 守卫消融实验公共库
#
# 设计原则（对应任务书「怎么消融而不污染生产源码」）：
#   ab_prepare <scenario>  把生产 lib/ + scripts/ 复制到 .validation 下的隔离副本目录，
#                          之后所有 sed / 补丁只作用于副本；生产源码零写入。
#   ab_report <key> <value>  输出一行结构化观测结果。
#
# 本文件不修改任何生产文件，也不执行任何 git 写操作。

set -uo pipefail

AB_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB_ROOT="$(cd "$AB_SELF_DIR/../../.." && pwd)"
AB_WORK="$AB_ROOT/.validation/ablation-2026-10-02/work"
AB_LOGS="$AB_ROOT/.validation/ablation-2026-10-02/logs"

mkdir -p "$AB_WORK" "$AB_LOGS"

# ab_prepare <scenario-name> [module ...]
# 把给定模块从生产目录复制到隔离副本，返回副本仓库根。
ab_prepare() {
    local name="$1"; shift
    local dst="$AB_WORK/$name"
    rm -rf "$dst"
    mkdir -p "$dst"

    if [ $# -eq 0 ]; then set -- lib scripts; fi

    local m
    for m in "$@"; do
        if [ -e "$AB_ROOT/$m" ]; then
            cp -a "$AB_ROOT/$m" "$dst/$m"
        fi
    done
    # config.sh 用 BASH_SOURCE 推导 SCRIPT_DIR/DATA_DIR/LOG_DIR，副本需要这些目录存在
    mkdir -p "$dst/data" "$dst/logs" "$dst/etc" "$dst/data/secrets"
    printf '%s' "$dst"
}

# ab_ablate <file> <sed-expr...>  在副本文件上原地应用 sed 消融；sed 未命中则报错退出。
ab_ablate() {
    local file="$1"; shift
    local backup
    ab_detach "$file"
    backup="$file.ab-orig"
    cp -a "$file" "$backup"
    sed -i "$@" "$file" || return 1
    if cmp -s "$file" "$backup"; then
        echo "ABORT: 消融未改变文件内容（sed 未命中）：$file" >&2
        mv -f "$backup" "$file"
        return 2
    fi
    echo "  [ablate] $file <- $*"
    echo "  [ablate] diff -u:"
    diff -u "$backup" "$file" | sed -n '3,40p' | sed 's/^/    /'
    rm -f "$backup"
    return 0
}

ab_report() { printf '%s=%s\n' "$1" "$2"; }
ab_note()    { printf '# %s\n' "$*"; }

ab_expect_ok()   { if "$@" >/dev/null 2>&1; then echo "  [OK ] $*"; else echo "  [ERR] $* (期望成功却失败)"; fi; }
ab_expect_fail() { if "$@" >/dev/null 2>&1; then echo "  [ERR] $* (期望失败却成功)"; else echo "  [OK ] $*"; fi; }

# ab_probe <dest-file>  从 stdin 读取探针脚本原文写入 dest-file（内容不做任何展开）。
ab_probe() {
    mkdir -p "$(dirname "$1")"
    cat > "$1"
}

# ab_pair <scenario> <module...>  复制出 baseline/ablated 两份副本并打印两条路径。
ab_pair() {
    local sc="$1"; shift
    local base abl
    base=$(ab_prepare "$sc-baseline" "$@")
    abl=$(ab_prepare "$sc-ablated" "$@")
    printf '%s\n%s\n' "$base" "$abl"
}

# ---------------------------------------------------------------------------
# 无正则、无反斜杠的消融原语（避免 sed/正则转义把实验脚本搞坏）
#   ab_drop_block <file> <start-literal> <end-literal>
#   ab_sub <file> <old-literal> <new-literal>
#   ab_insert_after <file> <anchor-literal> <new-line>
# 三者在「未命中」时返回 3，调用方必须以 || exit 3 终止，绝不静默通过。
# ---------------------------------------------------------------------------

ab_drop_block() {
    local file="$1" start="$2" end="$3"
    local backup="$file.ab-orig" dropped
    ab_detach "$file"
    cp -a "$file" "$backup"
    dropped=$(python3 - "$file" "$start" "$end" <<'PYEOF'
import sys
path, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().split('\n')
out, i, dropped = [], 0, []
while i < len(lines):
    if start in lines[i]:
        j = i
        while j < len(lines) and end not in lines[j]:
            j += 1
        if j < len(lines):
            dropped = lines[i:j + 1]
            i = j + 1
            continue
    out.append(lines[i])
    i += 1
if not dropped:
    sys.exit(3)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
sys.stdout.write('\n'.join(dropped))
PYEOF
) || {
        echo "ABORT: ab_drop_block 未命中: start=[$start] end=[$end] in $file" >&2
        mv -f "$backup" "$file"
        return 3
    }
    echo "  [ablate] $file: 删除块行数=$(printf '%s\n' "$dropped" | wc -l)"
    printf '    - %s\n' "$dropped"
    rm -f "$backup"
    return 0
}

ab_sub() {
    local file="$1" old="$2" new="$3"
    local backup="$file.ab-orig"
    ab_detach "$file"
    cp -a "$file" "$backup"
    if ! python3 - "$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().split('\n')
for i, line in enumerate(lines):
    if old in line:
        lines[i] = line.replace(old, new)
        open(path, 'w', encoding='utf-8').write('\n'.join(lines))
        sys.exit(0)
sys.exit(3)
PYEOF
    then
        echo "ABORT: ab_sub 未命中: old=[$old] in $file" >&2
        mv -f "$backup" "$file"
        return 3
    fi
    echo "  [ablate] $file: 替换 [$old] -> [$new]"
    rm -f "$backup"
    return 0
}

ab_insert_after() {
    local file="$1" anchor="$2" newline="$3"
    ab_detach "$file"
    if ! python3 - "$file" "$anchor" "$newline" <<'PYEOF'
import sys
path, anchor, newline = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().split('\n')
for i, line in enumerate(lines):
    if anchor in line:
        lines.insert(i + 1, newline)
        open(path, 'w', encoding='utf-8').write('\n'.join(lines))
        sys.exit(0)
sys.exit(3)
PYEOF
    then
        echo "ABORT: ab_insert_after 未命中: anchor=[$anchor] in $file" >&2
        return 3
    fi
    echo "  [ablate] $file: 在 [$anchor] 后插入 [$newline]"
    return 0
}

# ---------------------------------------------------------------------------
# 2026-10-02 追加：硬链接树管理。基线树只准备一次，场景间复用；
# 消融树用 cp -al 硬链接克隆（近乎零成本），改文件前由 ab_detach 断开链接，
# 避免 python 原地写穿透回基线树。
# ---------------------------------------------------------------------------

# ab_detach <file>  用真实副本替换硬链接，使后续原地写只影响本副本。
ab_detach() {
    local f="$1" t="$1.ab-detach"
    [ -f "$f" ] || return 0
    cp --preserve=mode,timestamps "$f" "$t" 2>/dev/null || cp "$f" "$t"
    mv -f "$t" "$f"
}

# ab_tree_baseline  准备一次共享基线树，返回路径（已存在则直接复用）。
ab_tree_baseline() {
    local dst="$AB_WORK/_baseline"
    if [ -d "$dst/lib" ]; then printf '%s' "$dst"; return 0; fi
    rm -rf "$dst"; mkdir -p "$dst"
    cp -a "$AB_ROOT/lib" "$dst/lib"
    cp -a "$AB_ROOT/scripts" "$dst/scripts"
    mkdir -p "$dst/data/secrets" "$dst/logs" "$dst/etc"
    printf '%s' "$dst"
}

# ab_tree_ablated <scenario>  从共享基线树硬链接克隆一份消融树。
ab_tree_ablated() {
    local name="$1" src dst
    src=$(ab_tree_baseline) || return 3
    dst="$AB_WORK/$name"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -al "$src/lib" "$dst/lib"      || cp -a "$src/lib" "$dst/lib"
    cp -al "$src/scripts" "$dst/scripts" || cp -a "$src/scripts" "$dst/scripts"
    mkdir -p "$dst/data/secrets" "$dst/logs" "$dst/etc"
    printf '%s' "$dst"
}

# ab_selfcheck <baseline-reject-msg> <ablated-rc> <success-evidence>
# 打印并校验「只移除守卫、保留能力」三条硬判据。
ab_selfcheck() {
    local reject="$1" abl_rc="$2" ok_ev="$3" bad=0
    echo "  [自检1] baseline 拒绝理由: $reject"
    [ -n "$reject" ] || { echo "  [自检1] FAIL 未取到 baseline 拒绝消息"; bad=1; }
    echo "  [自检2] ablated rc=$abl_rc 成功证据: $ok_ev"
    { [ "$abl_rc" = "0" ] && [ -n "$ok_ev" ]; } || { echo "  [自检2] FAIL 无成功证据"; bad=1; }
    case "$reject$ok_ev" in
        *127*|*"not found"*|*"command not found"*|*"未找到命令"*)
            echo "  [自检3] FAIL 假失败特征（127/命令不存在）"; bad=1 ;;
        *) echo "  [自检3] OK 无 127/命令不存在类假失败" ;;
    esac
    [ $bad -eq 0 ] && echo "  [自检] PASS" || echo "  [自检] EXPERIMENT-INVALID"
    return $bad
}
