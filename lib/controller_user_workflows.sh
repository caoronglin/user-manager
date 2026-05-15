#!/bin/bash
# controller_user_workflows.sh - 用户工作流聚合控制器

if [[ -z "${LIB_DIR:-}" ]]; then
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_listing.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_passwords.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_lifecycle.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_provisioning.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_limits.sh"
