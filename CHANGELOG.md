# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.2.1] - 2026-03-03

### Added
- 现代化玻璃拟态UI组件 (Modern Glassmorphism UI Components)
  - 新增 `ui_modern.sh` 模块，提供玻璃拟态视觉效果
  - 支持玻璃面板 (glass_panel)、玻璃按钮 (glass_button)、玻璃输入框 (glass_input)
  - 新增动画效果：淡入 (glass_fade_in)、打字机效果 (glass_typewriter)、进度条 (glass_progress)
  - 完整的Unicode图标系统 (150+ 图标)
- 权限最小化实现 (Privilege Minimization)
  - 基于ACL (Access Control List) 的分级权限系统
  - 四级权限模型：root(0), admin(1), user(2), guest(3)
  - 命令白名单机制 (PRIV_CMD_WHITELIST)
  - 权限缓存系统，提升性能
  - 审计日志系统，记录所有特权操作
- 模块化解耦设计 (Modular Decoupling)
  - 新增 `access_control.sh` 权限控制模块
  - 新增 `privilege.sh` 特权操作封装层
  - 新增 `privilege_cache.sh` 权限缓存模块
  - 延迟加载 (Lazy Loading) 机制
- 增强的错误处理
  - 统一的错误上下文 (msg_err_ctx)
  - 安全的参数校验 (require_param, require_file, require_dir)
  - 路径安全验证 (validate_path_safety)

### Changed
- 版本号从 v6.1.0 更新为 v0.2.1
- 主菜单UI升级为玻璃拟态风格
- 权限系统重构，采用ACL分级模型
- 日志系统增强，支持结构化审计日志

### Security
- 实现权限最小化原则 (Principle of Least Privilege)
- 所有特权操作必须通过白名单检查
- 敏感文件权限自动检查和修复
- 审计日志记录所有权限操作

### Technical Details
- 模块数量: 18个核心模块
- 代码行数: 约15,000行
- 图标数量: 150+ Unicode图标
- 权限级别: 4级
- 审计日志: 结构化JSON格式

## [0.1.0] - 2026-02-20

### Initial Release
- 基础用户管理功能
- 用户创建、删除、修改
- 配额管理
- 备份与恢复
- 防火墙管理
- DNS控制
- 软连接管理
- 作业统计
- 报告生成
- 密码轮换
