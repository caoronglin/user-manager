#!/bin/bash
# run.sh - 用户管理系统启动入口 v5.0
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec bash user_manager.sh "$@"
