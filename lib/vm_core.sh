#!/bin/bash
# vm_core.sh - 虚拟机管理核心模块

vm_require_name() {
    local vm_name="${1:-}"
    if [[ -z "$vm_name" ]]; then
        if declare -F msg_err >/dev/null 2>&1; then
            msg_err "虚拟机名称不能为空"
        else
            echo "虚拟机名称不能为空" >&2
        fi
        return 1
    fi
    return 0
}

vm_have_virsh() {
    command -v virsh >/dev/null 2>&1 || declare -F virsh >/dev/null 2>&1
}

list_virtual_machines() {
    if ! vm_have_virsh; then
        echo "未检测到 virsh/libvirt，无法列出虚拟机"
        return 0
    fi
    virsh list --all
}

show_virtual_machine_status() {
    local vm_name="${1:-}"
    vm_require_name "$vm_name" || return 1
    if ! vm_have_virsh; then
        echo "未检测到 virsh/libvirt，无法查询虚拟机状态"
        return 0
    fi
    virsh domstate "$vm_name"
}

start_virtual_machine() {
    local vm_name="${1:-}"
    vm_require_name "$vm_name" || return 1
    priv_virsh start "$vm_name"
}

shutdown_virtual_machine() {
    local vm_name="${1:-}"
    vm_require_name "$vm_name" || return 1
    priv_virsh shutdown "$vm_name"
}

reboot_virtual_machine() {
    local vm_name="${1:-}"
    vm_require_name "$vm_name" || return 1
    priv_virsh reboot "$vm_name"
}

destroy_virtual_machine() {
    local vm_name="${1:-}"
    vm_require_name "$vm_name" || return 1
    priv_virsh destroy "$vm_name"
}

set_virtual_machine_autostart() {
    local vm_name="${1:-}"
    local enabled="${2:-on}"
    vm_require_name "$vm_name" || return 1

    case "$enabled" in
        on|enable|enabled|true|1)
            priv_virsh autostart "$vm_name"
            ;;
        off|disable|disabled|false|0)
            priv_virsh autostart --disable "$vm_name"
            ;;
        *)
            if declare -F msg_err >/dev/null 2>&1; then
                msg_err "autostart 参数必须是 on/off"
            else
                echo "autostart 参数必须是 on/off" >&2
            fi
            return 1
            ;;
    esac
}
