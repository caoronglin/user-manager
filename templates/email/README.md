# Email Templates Directory
# 现代化邮件模板，支持响应式设计

此目录包含各种邮件模板：

## 邮件模板

### 密码通知模板 (modern_password_notify.html)
- 设计风格：简约现代
- 颜色方案：柔和的蓝绿色系
- 响应式：自适应布局
- 图标：Unicode 符号，无需外部字体
- 特性：
  - 卡片式信息展示
  - 明显的密码框
  - 安全提示高亮
  - 移动端友好的阅读体验

## 模板使用说明

### 在代码中使用

```bash
# 在 lib/user_core.sh 中更新邮件发送函数
send_password_email() {
    local username="$1"
    local password="$2"
    local email="$3"
    local action="${4:-密码更新}"
    
    # 加载现代模板
    local template="$SCRIPT_DIR/templates/email/modern_password_notify.html"
    
    # 生成邮件内容（可添加更多变量）
    local html_content=$(envsubst "$template" << 'EOF' || true)
    
    # 发送邮件（保留现有的重试逻辑）
    # ...
}
```

### 模板变量

当前模板支持的变量：
- ${username} - 用户名
- ${password} - 密码
- ${action} - 操作类型（如"密码更新"）
- ${timestamp} - 时间戳（格式：2026-02-23 20:30:00）

### 扩展建议

1. **更多邮件类型**
   - `account_created.html` - 账户创建通知
   - `user_suspended.html` - 用户暂停通知
   - `quota_warning.html` - 配额警告

2. **支持暗模式**
   - 添加 `class="dark-mode"` 到 body 标签
   - 调整为深色主题

3. **品牌化支持**
   - 可配置的主题颜色变量
   - 支持 Logo 图片嵌入

4. **多语言支持**
   - 创建 `templates/email/` 目录按语言分类
   - 使用 `$template_dir/lang/zh-CN/` 动态加载模板

5. **A/B 测试**
   - 邮件主题模板（明/暗）
   - 状态通知模板（成功/失败）

## 技术要求

- 硯式：HTML5
- 编码：UTF-8
- 响应式：Flexbox（移动端优先）
- 兼容性：所有现代邮件客户端
