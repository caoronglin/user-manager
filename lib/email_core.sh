#!/bin/bash
# email_core.sh - 兼容桥，加载拆分后的邮件模块

_EMAIL_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rl_mail_config.sh
source "$_EMAIL_CORE_DIR/rl_mail_config.sh"
# shellcheck source=lib/rl_mail_template.sh
source "$_EMAIL_CORE_DIR/rl_mail_template.sh"
# shellcheck source=lib/rl_mail_audit.sh
source "$_EMAIL_CORE_DIR/rl_mail_audit.sh"
# shellcheck source=lib/rl_mail_sender.sh
source "$_EMAIL_CORE_DIR/rl_mail_sender.sh"
# shellcheck source=lib/rl_mail_queue.sh
source "$_EMAIL_CORE_DIR/rl_mail_queue.sh"
# shellcheck source=lib/rl_mail_events.sh
source "$_EMAIL_CORE_DIR/rl_mail_events.sh"
