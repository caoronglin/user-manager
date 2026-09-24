#!/bin/bash
# test_snapshot_ops.sh - focused bounded/read-only P6 snapshot collector tests.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
setup_test_env
source "$PROJECT_ROOT/lib/snapshot_ops.sh"
test_suite_start "Ubuntu Ops Snapshot Sections (P6)"

OPS_STUB_BIN="$TEST_TMPDIR/stubs"
OPS_STUB_LOG="$TEST_TMPDIR/commands.log"
mkdir -p "$OPS_STUB_BIN"
export OPS_STUB_LOG

cat >"$OPS_STUB_BIN/df" <<'EOF'
#!/bin/bash
printf 'df' >>"$OPS_STUB_LOG"
printf ' %s' "$@" >>"$OPS_STUB_LOG"
printf '\n' >>"$OPS_STUB_LOG"
[[ "$1" == --block-size=1 && "$2" == --output=size,used,avail,pcent,itotal,iused,iavail,ipcent && "$3" == -- ]] || exit 90
[[ "${*: -1}" != /broken ]] || exit 1
printf 'Size Used Avail Use%% ITotal IUsed IFree IUse%%\n'
printf '1000 100 900 10%% 50 5 45 10%%\n'
EOF

cat >"$OPS_STUB_BIN/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl' >>"$OPS_STUB_LOG"
printf ' %s' "$@" >>"$OPS_STUB_LOG"
printf '\n' >>"$OPS_STUB_LOG"
if [[ "${OPS_SYSTEMCTL_MODE:-fail}" == ok ]]; then
    case "${1:-}" in
        --no-pager)
            if [[ " $* " == *' --failed '* ]]; then exit 0; fi
            printf 'loaded\nactive\n'
            exit 0
            ;;
        list-timers)
            printf 'Tue 2026-09-24 10:00:00 CST 1h left - - apt-daily.timer apt-daily.service\n'
            exit 0
            ;;
        is-system-running) printf 'running\n'; exit 0 ;;
        *) exit 90 ;;
    esac
fi
case "${1:-}" in
    --no-pager | list-timers | is-system-running) exit 1 ;;
    *) exit 90 ;;
esac
EOF

cat >"$OPS_STUB_BIN/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get' >>"$OPS_STUB_LOG"
printf ' %s' "$@" >>"$OPS_STUB_LOG"
printf '\n' >>"$OPS_STUB_LOG"
[[ " $* " == *' --simulate '* && " $* " == *' upgrade '* ]] || exit 90
cat <<'OUTPUT'
Inst alpha [1.0] (1.1 Ubuntu:stable-security [amd64])
Inst beta [1.0] (1.1 Ubuntu:stable-updates [amd64])
Inst gamma [1.0] (1.1 Debian-Security [amd64])
OUTPUT
EOF

cat >"$OPS_STUB_BIN/aa-status" <<'EOF'
#!/bin/bash
printf 'aa-status' >>"$OPS_STUB_LOG"
printf ' %s' "$@" >>"$OPS_STUB_LOG"
printf '\n' >>"$OPS_STUB_LOG"
[[ $# == 0 ]] || exit 90
cat <<'OUTPUT'
apparmor module is loaded.
12 profiles are loaded.
9 profiles are in enforce mode.
3 profiles are in complain mode.
0 processes are unconfined.
OUTPUT
EOF

cat >"$OPS_STUB_BIN/systemd-detect-virt" <<'EOF'
#!/bin/bash
printf 'systemd-detect-virt' >>"$OPS_STUB_LOG"
printf ' %s' "$@" >>"$OPS_STUB_LOG"
printf '\n' >>"$OPS_STUB_LOG"
[[ $# == 0 ]] || exit 90
printf 'kvm\n'
EOF

chmod +x "$OPS_STUB_BIN/df" "$OPS_STUB_BIN/systemctl" "$OPS_STUB_BIN/apt-get" "$OPS_STUB_BIN/aa-status" "$OPS_STUB_BIN/systemd-detect-virt"
PATH="$OPS_STUB_BIN:$PATH"
export PATH

mountinfo="$TEST_TMPDIR/mountinfo"
cat >"$mountinfo" <<'EOF'
1 0 8:1 / /good rw - ext4 /dev/sda rw
2 0 8:2 / /broken rw - nfs server:/export rw
EOF

test_start "filesystem collection isolates one failed mount and records inode metrics"
fs_json="$(_snapshot_ops_filesystem_section "$mountinfo")" || fs_json='{}'
if [[ "$(jq -r '.status' <<<"$fs_json")" == degraded &&
"$(jq -r '.mounts[0].available' <<<"$fs_json")" == true &&
"$(jq -r '.mounts[0].inode_total' <<<"$fs_json")" == 50 &&
"$(jq -r '.mounts[1].available' <<<"$fs_json")" == false &&
"$(jq -r '.mounts[1].error' <<<"$fs_json")" == unavailable ]]; then
    test_pass
else
    test_fail "filesystem did not isolate bad mount: $fs_json"
fi

auto_config="$TEST_TMPDIR/20auto-upgrades"
reboot_marker="$TEST_TMPDIR/reboot-required"
printf 'APT::Periodic::Unattended-Upgrade "1";\n' >"$auto_config"
: >"$reboot_marker"
printf 'linux-image\n' >"$reboot_marker.pkgs"
apparmor_file="$TEST_TMPDIR/apparmor-enabled"
printf 'Y\n' >"$apparmor_file"

test_start "APT simulation, security count, reboot marker, and timer data are bounded"
OPS_SYSTEMCTL_MODE=ok
export OPS_SYSTEMCTL_MODE
apt_json="$(_snapshot_ops_apt_section "$auto_config" "$reboot_marker")" || apt_json='{}'
if [[ "$(jq -r '.status' <<<"$apt_json")" == ok &&
"$(jq -r '.upgradable_count' <<<"$apt_json")" == 3 &&
"$(jq -r '.security_upgradable_count' <<<"$apt_json")" == 2 &&
"$(jq -r '.reboot_required' <<<"$apt_json")" == true &&
"$(jq -r '.reboot_required_package_count' <<<"$apt_json")" == 1 &&
"$(jq -r '.unattended_upgrades_configured' <<<"$apt_json")" == true &&
"$(jq -r '.apt_timers_available' <<<"$apt_json")" == true &&
"$(jq -r '.apt_timers | length' <<<"$apt_json")" == 2 &&
"$(jq -r '.apt_timers[0].available' <<<"$apt_json")" == true &&
"$(jq -r '.apt_timers[0].active_state' <<<"$apt_json")" == active ]]; then
    test_pass
else
    test_fail "APT section fields unexpected: $apt_json"
fi
OPS_SYSTEMCTL_MODE=fail
export OPS_SYSTEMCTL_MODE

test_start "AppArmor emits only profile counts and handles the optional tool"
apparmor_json="$(_snapshot_ops_apparmor_section "$apparmor_file")" || apparmor_json='{}'
if [[ "$(jq -r '.status' <<<"$apparmor_json")" == ok &&
"$(jq -r '.enabled' <<<"$apparmor_json")" == true &&
"$(jq -r '.profiles_loaded' <<<"$apparmor_json")" == 12 &&
"$(jq -r 'has("profile_names")' <<<"$apparmor_json")" == false ]]; then
    test_pass
else
    test_fail "AppArmor summary unexpected: $apparmor_json"
fi

test_start "systemd parser captures timer names and service states on success"
OPS_SYSTEMCTL_MODE=ok
export OPS_SYSTEMCTL_MODE
systemd_json="$(_snapshot_ops_systemd_section)" || systemd_json='{}'
if [[ "$(jq -r '.status' <<<"$systemd_json")" == ok &&
"$(jq -r '.boot_state' <<<"$systemd_json")" == running &&
"$(jq -r '.timers_available' <<<"$systemd_json")" == true &&
"$(jq -r '.timers[0]' <<<"$systemd_json")" == apt-daily.timer &&
"$(jq -r '.key_services[0].active_state' <<<"$systemd_json")" == active ]]; then
    test_pass
else
    test_fail "systemd success result unexpected: $systemd_json"
fi
OPS_SYSTEMCTL_MODE=fail
export OPS_SYSTEMCTL_MODE

os_release="$TEST_TMPDIR/os-release"
proc_stat="$TEST_TMPDIR/stat"
meminfo="$TEST_TMPDIR/meminfo"
pressure_dir="$TEST_TMPDIR/pressure"
mkdir -p "$pressure_dir"
cat >"$os_release" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
cat >"$proc_stat" <<'EOF'
cpu 100 0 20 200 10 0 0 0 0 0
cpu0 50 0 10 100 5 0 0 0 0 0
cpu1 50 0 10 100 5 0 0 0 0 0
btime 1727110000
EOF
cat >"$meminfo" <<'EOF'
MemTotal: 4096 kB
MemAvailable: 2048 kB
SwapTotal: 2048 kB
SwapFree: 1024 kB
EOF
cat >"$pressure_dir/cpu" <<'EOF'
some avg10=0.10 avg60=0.20 avg300=0.30 total=1200
EOF
cat >"$pressure_dir/memory" <<'EOF'
some avg10=0.40 avg60=0.50 avg300=0.60 total=3400
full avg10=0.01 avg60=0.02 avg300=0.03 total=400
EOF
cat >"$pressure_dir/io" <<'EOF'
some avg10=0.70 avg60=0.80 avg300=0.90 total=5600
full avg10=0.04 avg60=0.05 avg300=0.06 total=700
EOF

test_start "system summary includes Ubuntu, boot, virtualization, CPU, swap, and PSI"
summary_json="$(_snapshot_ops_system_summary "$os_release" "$proc_stat" "$meminfo" "$pressure_dir")" || summary_json='{}'
if jq -e '.ubuntu_version == "24.04" and .boot_time_epoch == 1727110000 and
    .virtualization.kind == "kvm" and .logical_cpu_count == 2 and
    .mem_total_bytes == 4194304 and .mem_available_bytes == 2097152 and
    .memory_status == "ok" and .cpu_status == "degraded" and
    .swap_total_bytes == 2097152 and .swap_available_bytes == 1048576 and
    .pressure.memory.some.avg10 == 0.4' <<<"$summary_json" >/dev/null; then
    test_pass
else
    test_fail "system summary fields unexpected: $summary_json"
fi

test_start "one systemd failure degrades that section without aborting other sections"
ops_json="$(snapshot_ops_collect)" || ops_json='{}'
if [[ "$(jq -r '.systemd.status' <<<"$ops_json")" == degraded &&
"$(jq -r '.systemd.timers_available' <<<"$ops_json")" == false &&
"$(jq -r '.apt.upgradable_count' <<<"$ops_json")" == 3 &&
"$(jq -r '.apparmor.profiles_loaded' <<<"$ops_json")" == 12 &&
"$(jq -r '.filesystems.mount_count > 0' <<<"$ops_json")" == true ]]; then
    test_pass
else
    test_fail "failure was not isolated across sections: $ops_json"
fi

test_start "only read-only allowlisted command forms were executed"
if [[ -s "$OPS_STUB_LOG" ]] &&
    ! grep -E 'systemctl (start|stop|restart|enable|disable|mask|unmask|daemon-reload)|apt-get (install|remove|purge|update|dist-upgrade)( |$)|(^| )user(add|del|mod)( |$)|(^| )setquota( |$)' "$OPS_STUB_LOG" >/dev/null; then
    test_pass
else
    test_fail "unexpected or mutating command observed: $(cat "$OPS_STUB_LOG")"
fi

test_suite_end
