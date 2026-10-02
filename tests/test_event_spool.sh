#!/bin/bash
# CLI-to-Web event spool producer tests.

# Private event helpers are loaded from user_core.sh through a variable-based
# source path, so ShellCheck cannot resolve their definitions statically.
# shellcheck disable=SC2218
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT

export USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data"
export USER_MANAGER_USER_CREATION_LOG="$TEST_TMPDIR/created_users.csv"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
# shellcheck source=lib/user_core.sh
source "$PROJECT_ROOT/lib/user_core.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf '[PASS] %s\n' "$1"
    ((PASS_COUNT += 1))
}

fail() {
    printf '[FAIL] %s: %s\n' "$1" "${2:-assertion failed}" >&2
    ((FAIL_COUNT += 1))
}

test_dir="$TEST_TMPDIR/spool"
test_owner="$(id -un)"
test_group="$(id -gn)"

if _um_publish_cli_user_event_spool_at "$test_dir" alice user.created "$test_owner" "$test_group"; then
    event_file="$(find "$test_dir" -maxdepth 1 -type f -name '*.json' -print -quit)"
    if [[ -n "$event_file" ]] && jq -e --arg path "$event_file" '
        .schema_version == 1 and
        .event_id == ($path | split("/")[-1] | sub("\\.json$"; "")) and
        (.event_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        .event_type == "user.created" and
        (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        .source == "cli" and .severity == "info" and
        .summary == "User account created." and .data == {username:"alice"} and
        ((keys | sort) == ["created_at","data","event_id","event_type","schema_version","severity","source","summary"])
    ' "$event_file" >/dev/null; then
        pass 'writes the agreed event JSON shape with safe fixed summary'
    else
        fail 'writes the agreed event JSON shape with safe fixed summary'
    fi

    expected_owner_uid="$(id -u "$test_owner")"
    expected_group_gid="$(getent group "$test_group" | cut -d: -f3)"
    dir_stat="$(stat -c '%u:%g:%a' "$test_dir")"
    file_stat="$(stat -c '%u:%g:%a' "$event_file")"
    if [[ "$dir_stat" == "$expected_owner_uid:$expected_group_gid:750" &&
        "$file_stat" == "$expected_owner_uid:$expected_group_gid:640" ]]; then
        pass 'sets spool directory and event owner/group/mode'
    else
        fail 'sets spool directory and event owner/group/mode' "dir=$dir_stat file=$file_stat"
    fi
else
    fail 'writes the agreed event JSON shape with safe fixed summary' 'publisher failed'
    fail 'sets spool directory and event owner/group/mode' 'publisher failed'
fi

disabled_dir="$TEST_TMPDIR/disabled-spool"
if _um_publish_cli_user_event_spool_at "$disabled_dir" alice user.disabled "$test_owner" "$test_group"; then
    disabled_file="$(find "$disabled_dir" -maxdepth 1 -type f -name '*.json' -print -quit)"
    if jq -e '.event_type == "user.disabled" and .severity == "warning" and .summary == "User account disabled." and .data == {username:"alice"}' "$disabled_file" >/dev/null; then
        pass 'writes the Rust-allowlisted disabled event summary and severity'
    else
        fail 'writes the Rust-allowlisted disabled event summary and severity'
    fi
else
    fail 'writes the Rust-allowlisted disabled event summary and severity'
fi

created_event_type="$(_um_cli_user_event_type_for_action create)"
disabled_event_type="$(_um_cli_user_event_type_for_action disable)"
if [[ "$created_event_type" == user.created && "$disabled_event_type" == user.disabled ]] &&
    ! _um_cli_user_event_type_for_action group_add >/dev/null 2>&1; then
    pass 'maps only create and disable actions to Web lifecycle events'
else
    fail 'maps only create and disable actions to Web lifecycle events'
fi

bad_names=("" "-alice" "1alice" "Alice" "daemon$" "alice/../../escape" "../alice" "$(printf 'a%.0s' {1..33})")
bad_name_ok=1
for bad_name in "${bad_names[@]}"; do
    if _um_event_spool_username_is_valid "$bad_name"; then
        bad_name_ok=0
        break
    fi
done
if ((bad_name_ok)) && _um_event_spool_username_is_valid '_alice' &&
    _um_event_spool_username_is_valid 'alice-1'; then
    pass 'accepts Linux usernames and rejects unsafe names'
else
    fail 'accepts Linux usernames and rejects unsafe names'
fi

if ! _um_publish_cli_user_event_spool_at "$TEST_TMPDIR/invalid-name-spool" '../alice' user.created "$test_owner" "$test_group" &&
    [[ ! -e "$TEST_TMPDIR/invalid-name-spool" ]]; then
    pass 'rejects unsafe usernames before creating a spool directory'
else
    fail 'rejects unsafe usernames before creating a spool directory'
fi

mkdir "$TEST_TMPDIR/real-spool"
ln -s "$TEST_TMPDIR/real-spool" "$TEST_TMPDIR/linked-spool"
if ! _um_publish_cli_user_event_spool_at "$TEST_TMPDIR/linked-spool" alice user.created "$test_owner" "$test_group"; then
    pass 'rejects a symlink spool directory'
else
    fail 'rejects a symlink spool directory'
fi

# Force a deterministic ID through the private UUID helper to prove an existing
# symlink target is rejected without replacing its referent.
fixed_event_id='01234567-89ab-cdef-0123-456789abcdef'
mkdir "$TEST_TMPDIR/file-link-spool"
printf 'preserve me\n' >"$TEST_TMPDIR/link-target"
ln -s "$TEST_TMPDIR/link-target" "$TEST_TMPDIR/file-link-spool/$fixed_event_id.json"
_um_event_spool_new_uuid() { printf '%s\n' "$fixed_event_id"; }
if ! _um_publish_cli_user_event_spool_at "$TEST_TMPDIR/file-link-spool" alice user.disabled "$test_owner" "$test_group" &&
    [[ "$(cat "$TEST_TMPDIR/link-target")" == 'preserve me' ]]; then
    pass 'refuses to overwrite a symlink event target'
else
    fail 'refuses to overwrite a symlink event target'
fi
source "$PROJECT_ROOT/lib/user_core.sh"

# Exercise the cleanup cap: one publish removes at most 16 old regular events.
mkdir "$TEST_TMPDIR/cleanup-spool"
for ((i = 0; i < 18; i++)); do
    printf '{}\n' >"$TEST_TMPDIR/cleanup-spool/old-$i.json"
    touch -d '45 days ago' "$TEST_TMPDIR/cleanup-spool/old-$i.json"
done
if _um_publish_cli_user_event_spool_at "$TEST_TMPDIR/cleanup-spool" alice user.created "$test_owner" "$test_group"; then
    old_count="$(find "$TEST_TMPDIR/cleanup-spool" -maxdepth 1 -type f -name 'old-*.json' | wc -l)"
    if [[ "$old_count" == 2 ]]; then
        pass 'bounds old-event cleanup to 16 files per publish'
    else
        fail 'bounds old-event cleanup to 16 files per publish' "remaining=$old_count"
    fi
else
    fail 'bounds old-event cleanup to 16 files per publish'
fi

# Verify the production wrapper refuses to publish as a non-root caller.
nonroot_marker="$TEST_TMPDIR/nonroot-called"
if ((EUID != 0)); then
    _um_publish_cli_user_event_spool_at() { : >"$nonroot_marker"; }
    _um_publish_cli_user_event_spool alice create
    if [[ ! -e "$nonroot_marker" ]]; then
        pass 'does not publish from a non-root caller'
    else
        fail 'does not publish from a non-root caller'
    fi
else
    nonroot_test_root="$TEST_TMPDIR/nonroot-test"
    mkdir -p "$nonroot_test_root/marker-dir"
    chmod 0755 "$TEST_TMPDIR"
    chmod 0755 "$nonroot_test_root"
    chmod 0777 "$nonroot_test_root/marker-dir"
    cp "$PROJECT_ROOT/lib/user_core.sh" "$nonroot_test_root/user_core.sh"
    chmod 0644 "$nonroot_test_root/user_core.sh"
    if command -v runuser >/dev/null 2>&1 && getent passwd nobody >/dev/null; then
        if runuser -u nobody -- env \
            UM_TEST_CORE="$nonroot_test_root/user_core.sh" \
            UM_TEST_MARKER="$nonroot_test_root/marker-dir/called" \
            bash -c 'source "$UM_TEST_CORE"; _um_publish_cli_user_event_spool_at() { : >"$UM_TEST_MARKER"; }; _um_publish_cli_user_event_spool alice create; [[ ! -e "$UM_TEST_MARKER" ]]'; then
            pass 'does not publish from a non-root caller'
        else
            fail 'does not publish from a non-root caller'
        fi
    else
        printf '[SKIP] does not publish from a non-root caller (runuser unavailable)\n'
    fi
fi

# A spool failure must not change the pre-existing CSV record operation.
_um_publish_cli_user_event_spool() { return 1; }
if record_user_event alice create '用户' '/mnt/data01' '/mnt/data01/alice' &&
    [[ "$(tail -n 1 "$USER_CREATION_LOG")" == *,alice,create,用户,/mnt/data01,/mnt/data01/alice,N/A ]]; then
    pass 'keeps CSV logging successful when Web spool publishing fails'
else
    fail 'keeps CSV logging successful when Web spool publishing fails'
fi

printf '\nEvent spool tests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
