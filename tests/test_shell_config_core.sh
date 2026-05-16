#!/bin/bash
# test_shell_config_core.sh - Shell 配置核心验证测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/shell_config.sh"

TMP_DIR="$(mktemp -d)"
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN" \
    "$TMP_DIR/fishuser/.config/fish" \
    "$TMP_DIR/bashuser"
touch "$TMP_DIR/fishuser/.config/fish/config.fish"
touch "$TMP_DIR/bashuser/.bashrc"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$MOCK_BIN/id" <<'EOF'
#!/bin/bash
case "${1:-}" in
    fishuser|bashuser|emptyhome)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "$MOCK_BIN/getent" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "passwd" ]]; then
    case "\${2:-}" in
        fishuser) printf '%s\n' 'fishuser:x:1000:1000:Fish User:$TMP_DIR/fishuser:/usr/bin/fish' ;;
        bashuser) printf '%s\n' 'bashuser:x:1001:1001:Bash User:$TMP_DIR/bashuser:/bin/bash' ;;
        emptyhome) printf '%s\n' 'emptyhome:x:1002:1002:Empty Home::/bin/bash' ;;
        *) exit 2 ;;
    esac
else
    exit 2
fi
EOF

chmod +x "$MOCK_BIN/id" "$MOCK_BIN/getent"
export PATH="$MOCK_BIN:$PATH"

test_suite_start "Shell Config Core"

test_start "verify_shell_config accepts fish config.fish"
if verify_shell_config fishuser; then
    test_pass
else
    test_fail "fishuser with .config/fish/config.fish should pass"
fi

test_start "verify_shell_config accepts bash .bashrc"
if verify_shell_config bashuser; then
    test_pass
else
    test_fail "bashuser with .bashrc should pass"
fi

test_start "verify_shell_config rejects missing user"
if ! verify_shell_config missinguser; then
    test_pass
else
    test_fail "missing user should fail"
fi

test_start "verify_shell_config rejects missing argument without crash"
if ! verify_shell_config; then
    test_pass
else
    test_fail "missing argument should fail"
fi

test_start "verify_shell_config rejects empty home"
if ! verify_shell_config emptyhome; then
    test_pass
else
    test_fail "user with empty home should fail"
fi

test_suite_end
