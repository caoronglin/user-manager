#!/usr/bin/env bats
# test_env_core.bats - env_core 模块 bats-core 试点测试（阶段 0）
#
# 背景：docs/bats-migration-assessment.md（Lane H5 评估）
# 目标：验证 bats-core 对纯函数模块的迁移可行性，与 tests/test_env_core.sh 覆盖等价。
# 约束：
#   - 只读引用真实 lib/env_core.sh（不复制实现、不修改任何现有文件）
#   - 不依赖 bats-assert/bats-support（仓库无包管理器，保持零外部依赖）
#   - mock 外部命令：临时目录注入 PATH；mock 系统环境：ENV_FORCE_SYSTEMD 钩子
#
# 运行：cd <repo-root> && bats tests/bats/

# BATS_TEST_DIRNAME 由 bats 提供（bats >= 1.0）
PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/.." && pwd)"
source "${PROJECT_ROOT}/lib/env_core.sh"

# 每个 @test 独立子 shell 运行，setup/teardown 提供每用例的 mock 临时目录
setup() {
    RL_BATS_MOCK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${RL_BATS_MOCK_DIR}"
}

# mock 一个外部命令：生成可执行脚本放入 mock 目录
rl_mock_command() {
    local name="$1"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${RL_BATS_MOCK_DIR}/${name}"
    chmod +x "${RL_BATS_MOCK_DIR}/${name}"
}

@test "env_has_command 能识别真实存在的命令" {
    run env_has_command bash
    [ "$status" -eq 0 ]

    run env_has_command sh
    [ "$status" -eq 0 ]
}

@test "env_has_command 能识别当前 shell 中定义的函数" {
    rl_demo_env_command() { :; }

    run env_has_command rl_demo_env_command
    [ "$status" -eq 0 ]
}

@test "env_has_command 对缺失命令与空参数返回非零" {
    run env_has_command definitely_missing_user_manager_command_999
    [ "$status" -ne 0 ]

    # 空参数：env_has_command "" 应直接返回 1，不做任何探测
    run env_has_command ""
    [ "$status" -ne 0 ]
}

@test "env_has_command 能发现 PATH 中注入的 mock 外部命令" {
    rl_mock_command rl-fake-tool
    PATH="${RL_BATS_MOCK_DIR}:${PATH}"

    run env_has_command rl-fake-tool
    [ "$status" -eq 0 ]

    # 移除 mock 后应恢复为缺失
    rm -f "${RL_BATS_MOCK_DIR}/rl-fake-tool"
    run env_has_command rl-fake-tool
    [ "$status" -ne 0 ]
}

@test "env_has_systemd 受 ENV_FORCE_SYSTEMD 强制开关控制" {
    ENV_FORCE_SYSTEMD=1
    run env_has_systemd
    [ "$status" -eq 0 ]

    ENV_FORCE_SYSTEMD=0
    run env_has_systemd
    [ "$status" -ne 0 ]

    unset ENV_FORCE_SYSTEMD
}

@test "env_capability_status 报告命令能力 ok/missing 状态与退出码" {
    rl_mock_command rl-fake-tool
    PATH="${RL_BATS_MOCK_DIR}:${PATH}"

    run env_capability_status command:rl-fake-tool
    [ "$status" -eq 0 ]
    [[ "$output" == *"capability=command:rl-fake-tool"* ]]
    [[ "$output" == *"status=ok"* ]]

    run env_capability_status command:definitely_missing_user_manager_command_999
    [ "$status" -ne 0 ]
    [[ "$output" == *"status=missing"* ]]
    [[ "$output" == *"reason=command-not-found"* ]]
}

@test "env_capability_status 对空能力与未注册能力返回 missing/unknown" {
    run env_capability_status ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"status=missing"* ]]
    [[ "$output" == *"reason=empty-capability"* ]]

    run env_capability_status not-a-registered-capability
    [ "$status" -ne 0 ]
    [[ "$output" == *"status=unknown"* ]]
    [[ "$output" == *"reason=not-registered"* ]]
}

@test "env_require_capability 全满足通过、任一缺失失败" {
    run env_require_capability command:bash
    [ "$status" -eq 0 ]

    run env_require_capability command:bash command:definitely_missing_user_manager_command_999
    [ "$status" -ne 0 ]
}
