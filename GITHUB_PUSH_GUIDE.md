# GitHub 仓库推送指南

## 方式一：使用 GitHub CLI（推荐）

```bash
# 安装 GitHub CLI
sudo apt install gh

# 登录 GitHub
gh auth login

# 创建仓库并推送
gh repo create user-manager --public --source=. --remote=origin --push
```

## 方式二：手动创建（无需 CLI）

### 1. 创建 GitHub 仓库

访问：https://github.com/new

- **Repository name**: `user-manager`
- **Description**: `Pure Bash user management for AI/ML multi-user environments`
- **Visibility**: Public (推荐) 或 Private
- **初始化选项**: 全部取消（已有本地代码）
- 点击 **Create repository**

### 2. 添加远程并推送

```bash
# 添加远程仓库
git remote add origin https://github.com/YOUR_USERNAME/user-manager.git

# 验证远程
git remote -v

# 推送到 GitHub
git push -u origin main

# 如果推送失败，检查认证
# 使用 Personal Access Token：
# https://github.com/settings/tokens
```

### 3. 验证推送

```bash
# 查看远程分支
git branch -r

# 查看提交历史
git log --oneline
```

## 方式三：使用 SSH

```bash
# 生成 SSH 密钥（如果没有）
ssh-keygen -t ed25519 -C "your_email@example.com"

# 添加公钥到 GitHub
# https://github.com/settings/keys

# 添加远程仓库
git remote add origin git@github.com:YOUR_USERNAME/user-manager.git

# 推送
git push -u origin main
```

## 后续操作

### 1. 配置 GitHub Pages（可选）

```yaml
# .github/workflows/pages.yml
name: Deploy Documentation

on:
  push:
    branches: [ main ]

jobs:
  pages:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
```

### 2. 添加仓库描述

在 GitHub 仓库页面添加：
- 简短描述
- 网站链接
- 话题标签：`bash`, `user-management`, `linux`, `ai-ml`, `devops`

### 3. 配置分支保护

Settings → Branches → Add branch protection rule:
- **Branch name pattern**: `main`
- ✅ Require pull request reviews before merging
- ✅ Require status checks to pass before merging
- ✅ Require branches to be up to date before merging

## 常见问题

### Q: 推送被拒绝？

**A**: 确保仓库是空的（没有 README/.gitignore），或先 pull：
```bash
git pull origin main --allow-unrelated-histories
git push -u origin main
```

### Q: 认证失败？

**A**: 使用 Personal Access Token 代替密码：
1. 访问 https://github.com/settings/tokens
2. 生成新 token（勾选 `repo` 权限）
3. 推送时使用 token 作为密码

### Q: 大文件推送失败？

**A**: Miniforge.sh 已被 .gitignore 排除，如果还有其他大文件：
```bash
git rm --cached Miniforge.sh
git commit -m "Remove large file from tracking"
git push
```

## 推送后检查清单

- [ ] 仓库页面显示最新提交
- [ ] README.md 正确渲染
- [ ] Actions 页面显示 CI 工作流
- [ ] 所有文件已上传（除了 .gitignore 排除的）
- [ ] LICENSE 文件存在
- [ ] .github/workflows/ci.yml 存在

## 下一步

1. 在 GitHub 上查看仓库
2. 配置 GitHub Actions（自动运行 CI）
3. 添加仓库到 GitHub Topics
4. 分享项目！

---

**提示**: 如果是首次使用 GitHub，建议先完成个人资料设置和邮箱验证。
