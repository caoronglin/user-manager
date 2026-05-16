#!/bin/bash
# check_sensitive_files.sh - 检查已跟踪的敏感文件和常见密钥内容

set -euo pipefail

REPO_ROOT="${1:-.}"

if ! command -v git >/dev/null 2>&1; then
    echo "Error: git command not found" >&2
    exit 2
fi

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: $REPO_ROOT is not a git repository" >&2
    exit 2
fi

declare -a suspicious_files=()
declare -a sensitive_matches=()

while IFS= read -r -d '' file_path; do
    base_name="$(basename "$file_path")"
    case "$base_name" in
        .env|.env.*|*.pem|*.key|*.p12|*.pfx|id_rsa|id_dsa|id_ecdsa|id_ed25519|.npmrc|.pypirc|.netrc|credentials.json|secrets.json|service-account.json|service_account.json)
            suspicious_files+=("$file_path")
            ;;
    esac
done < <(git -C "$REPO_ROOT" ls-files -z)

declare -a patterns=(
    '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----'
    'AKIA[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9_]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
)

while IFS= read -r -d '' file_path; do
    full_path="$REPO_ROOT/$file_path"
    [[ -f "$full_path" ]] || continue

    # Test fixtures intentionally include synthetic secret markers to verify this scanner.
    [[ "$file_path" == "tests/test_security_scan.sh" ]] && continue

    for pattern in "${patterns[@]}"; do
        while IFS= read -r match_line; do
            [[ -n "$match_line" ]] || continue
            sensitive_matches+=("${file_path}:${match_line}")
        done < <(LC_ALL=C grep -nI -E -- "$pattern" "$full_path" 2>/dev/null || true)
    done
done < <(git -C "$REPO_ROOT" ls-files -z)

if (( ${#suspicious_files[@]} == 0 && ${#sensitive_matches[@]} == 0 )); then
    echo "No sensitive tracked files detected."
    exit 0
fi

echo "Sensitive tracked files or secrets detected:" >&2

if (( ${#suspicious_files[@]} > 0 )); then
    echo "[Filenames]" >&2
    printf '  %s\n' "${suspicious_files[@]}" >&2
fi

if (( ${#sensitive_matches[@]} > 0 )); then
    echo "[Contents]" >&2
    printf '  %s\n' "${sensitive_matches[@]}" >&2
fi

exit 1
