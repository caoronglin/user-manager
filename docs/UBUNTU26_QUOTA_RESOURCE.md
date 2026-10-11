# Ubuntu 26.04 配额与用户资源限制验收

## 适用范围与安全边界

本文针对 ext4 内置 user/group/project quota、systemd 管理的用户 slice 和 PAM limits.d。
所有读写操作仅限原有 CLI/TUI 管理员路径；`umweb` 保持无 sudo、无 systemd 写操作的只读边界。
脚本不应自动修改 `/etc/fstab`、关闭 `tmpfs` 配额、运行 `quotacheck` 或屏蔽系统服务错误。

## CLI 只读诊断

```bash
bash scripts/rl-user-quota.sh --health
bash scripts/rl-user-quota.sh --health /mnt/data06
bash scripts/rl-user-quota.sh --get USERNAME
```

`--health` 不传挂载点时检查配置中的已挂载 dataXX；指定挂载点时仅检查目标。
报告包含实际来源设备、文件系统、挂载参数以及用户/组 `repquota` 报告可读性。
`readable-with-warning` 表示 `repquota` 返回非零，但输出包含完整报告标题（例如无关 `tmpfs` stat 警告）。这是诊断信号，**不能**等同配额强制执行已经验证。
`unavailable` 必须返回失败，不以 0 使用量冒充读取成功。

需要核实内置 ext4 quota 时，可进一步只读检查：

```bash
findmnt -T /mnt/data06 -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo quotaon -p /mnt/data06
sudo repquota -u /mnt/data06
sudo repquota -g /mnt/data06
```

`quotaon -p` 和 `repquota` 输出中的 `Cannot stat() mounted device tmpfs` 可能来自 `/tmp` / `/dev/shm` 的 `usrquota`；应结合目标设备实际报告判断。
ext4 内置配额可以使用保留 inode，不要求存在 `aquota.user` / `aquota.group` 文件。
如果 `quotaon@.service` 因重复启用返回 2，不要简单设置 `SuccessExitStatus=2`；这种配置会掩盖其它参数错误。先核对实际配额和 systemd drop-in，维护窗口内单独处理启动单元。

## 用户限制与真实生效范围

`set_user_ulimit` 现在生成合法 PAM 四列配置：
```text
USERNAME soft nofile 65535
USERNAME hard nofile 524288
```

相同资源重新配置会替换旧值；旧版本错误三列记录在更新对应资源时移除。
配置在新的 PAM 登录会话中生效，不会修改已运行进程；
systemd 用户 slice 的 `TasksMax` / `EffectiveTasksMax`、`cpu.max` 和 `pids.max` 是另一层限制。

```bash
systemctl show "user-$(id -u).slice" -p TasksMax -p EffectiveTasksMax -p TasksCurrent
ulimit -Sn
ulimit -Hn
```

PAM 文件不能突破 systemd 上级 cgroup 限制；不要通过提高 `ulimit -u` 推断线程已无限制。

## 验收清单

1. `bash tests/test_quota_core.sh`：中文/英文配额报告、独立 tmpfs 警告、只读诊断、失败关闭。
2. `bash tests/test_resource_core.sh`：PAM 四列格式、重复设置、删除指定类型、输入校验。
3. `bash tests/run_regression.sh --level p1`：现有 CLI/TUI 兼容性。
4. 目标 Ubuntu 26.04 上执行 `--health` 和 `repquota`，确认实际报告及配额执行；只读诊断无法替代一次受控限额写入测试。
5. 重启后的 `quotaon@...` 服务状态需单独验收；该版本没有自动修改系统 unit 或磁盘配额元数据。

## 回滚

此变更只影响源代码及通过管理员显式命令写入的 PAM 配置。回滚代码可恢复上一版本；已写入的 PAM 文件需管理员按对应用户逐项检查与撤销，不要批量删除未确认的限制。
