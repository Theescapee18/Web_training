# Web_training

静态网页 **部署与维护训练** 仓库。多名成员（TMF / YLX / ZLY）各自维护一个子目录，
通过 **GitHub Actions（CI/CD）** 自动同步到 **Nginx** 服务器，全过程**无需共享 root 密码**。

## 目录结构

```
Web_training/
├── .github/workflows/deploy.yml   # CI/CD：push 后自动 rsync 部署到服务器
├── site/                          # 站点内容根（部署目标 = Nginx 的 root）
│   ├── index.html                 # 导航首页
│   ├── TMF/index.html             # 成员 TMF 的页面 → 访问 /web_training/TMF/
│   ├── YLX/index.html             # 成员 YLX 的页面 → 访问 /web_training/YLX/
│   └── ZLY/index.html             # 成员 ZLY 的页面 → 访问 /web_training/ZLY/
├── nginx/web_training.conf        # Nginx 路由片段（挂到已有域名的 /web_training/）
├── nginx/install-route.sh         # 服务器端「只新增不修改」部署路由的脚本
├── docs/DEPLOYMENT.md             # ⭐ SSH 密钥 + CI/CD 部署完整指南
└── README.md
```

服务器上站点根目录为 `/var/www/Web_training/`（= CI/CD 的 `DEPLOY_PATH`），
通过 Nginx 挂到已有域名的 `/web_training/` 路径下访问：

- 导航首页：`https://yaustu.cn/web_training/`
- 成员页面：`https://yaustu.cn/web_training/TMF/`（YLX、ZLY 同理）

## 分支与协作流程（按姓名缩写）

- **`main` = 生产分支**：只有 `main` 的推送会触发自动部署（避免各分支相互覆盖）。
- **每位成员一个长期分支**，以自己姓名缩写命名：`TMF` / `YLX` / `ZLY`，只改 `site/<自己缩写>/`。
- 流程：在自己分支改代码 → push 本分支 → 开 Pull Request 合入 `main` → 合并后 Actions 自动上线。

成员日常操作：

```bash
git checkout TMF                 # 切到自己的分支（首次由管理员创建后 fetch 下来）
# ...编辑 site/TMF/ 下的页面...
git add site/TMF
git commit -m "feat(TMF): 更新首页"
git push origin TMF              # 推到自己分支，然后在 GitHub 开 PR 合到 main
```

## 一次性初始化（管理员）

### a) 多人协作权限（避免“只一人能推/一人拍板”）

- **加协作者**：Settings → Collaborators and teams → Add people，把每位成员的 GitHub 账号加为 **Write**；每人用自己的账号认证，不共享任何密码。
- **保护 `main`**：Settings → Branches 对 `main` 开规则：Require a pull request before merging + Require approvals=1 + 勾选 Require review from Code Owners + 禁止 force push。
- **CODEOWNERS**（已内置 `.github/CODEOWNERS`）：把各 `site/<姓名>/` 的审批权分给对应成员。记得把里面 `@OWNER_*` 占位换成真实 GitHub 用户名。
- **部署权限**：服务器 SSH 私钥只存 Actions Secrets，成员无需也不能直接登录服务器。

### b) 服务器与密钥

CI/CD 依赖服务器上的一次性配置：**创建 deploy 用户 → 生成并部署 SSH 密钥 → 填 GitHub Secrets → 装 Nginx 配置**。
完整步骤见 **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**。

需要配置的 GitHub Secrets：

| Secret | 含义 |
|--------|------|
| `SERVER_HOST` | 服务器 IP/域名 |
| `SERVER_PORT` | SSH 端口（默认 22） |
| `DEPLOY_USER` | 非 root 部署用户（如 `deploy`） |
| `DEPLOY_PATH` | 站点根目录（如 `/var/www/Web_training/`） |
| `SSH_PRIVATE_KEY` | CI/CD 专用 SSH 私钥内容 |

## 安全要点

- 私钥只存 GitHub Secrets，绝不进仓库。
- 用专用非 root `deploy` 用户部署，root 密码不外泄。
- 建议生产环境关闭 SSH 的 root 与密码登录，并为公钥加命令/IP 限制（见文档第 8 节）。
