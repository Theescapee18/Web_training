# 部署与 SSH 密钥配置指南（CI/CD 自动化）

本项目的目标是：**多个成员各自维护 `site/<姓名>/` 下的静态页面，通过 GitHub Actions 自动部署到 Nginx 服务器，而整个过程不需要任何人共享 root 密码。**

核心思路一句话概括：
> 在服务器上建一个**专用部署用户**（非 root），为 CI/CD 生成**一对专属 SSH 密钥**；
> **公钥**放到服务器的 `authorized_keys`，**私钥**只存进 GitHub Secrets。
> GitHub Actions 用这把私钥登录部署用户并 `rsync` 同步文件，root 密码始终不出现在任何地方。

---

## 目录
1. [整体流程与信任关系](#1-整体流程与信任关系)
2. [第一步：在服务器上创建部署用户与站点目录](#2-在服务器上创建部署用户与站点目录)
3. [第二步：生成 CI/CD 专用 SSH 密钥对](#3-第二步生成-cicd-专用-ssh-密钥对)
4. [第三步：把公钥部署到服务器](#4-第三步把公钥部署到服务器)
5. [第四步：把私钥等写入 GitHub Secrets](#5-第四步把私钥等写入-github-secrets)
6. [第五步：配置 Nginx](#6-第五步配置-nginx)
7. [第六步：触发并验证部署](#7-第六步触发并验证部署)
8. [安全加固建议](#8-安全加固建议)
9. [常见问题排查](#9-常见问题排查)

---

## 1. 整体流程与信任关系

```
成员 push 到 main(site/ 有改动)
        │
        ▼
GitHub Actions Runner  ──(用 SSH 私钥登录)──▶  服务器的 deploy 用户
        │                                            │
        └── rsync 同步 site/ ───────────────────────▶└── 写入 /var/www/Web_training/
                                                            │
                                                     Nginx 读取该目录对外提供服务
```

- 私钥：**只**存在于 GitHub Secrets，永远不会进仓库。
- 公钥：放在部署用户的 `~/.ssh/authorized_keys`。
- 部署用户权限：只对 `/var/www/Web_training` 有写权限，动不了系统其他部分。

---

## 2. 在服务器上创建部署用户与站点目录

> 以下命令用 **root 或有 sudo 权限的账号**在服务器上执行一次即可（之后 CI/CD 不再需要 root）。

```bash
# 1) 创建专用部署用户 deploy（-m 建家目录，-s 指定 shell）
sudo adduser --disabled-password --gecos "" deploy

# 2) 创建站点根目录并归属给 deploy
sudo mkdir -p /var/www/Web_training
sudo chown -R deploy:deploy /var/www/Web_training
sudo chmod -R 755 /var/www/Web_training

# 3) 确认 rsync 已安装（Actions 会用 rsync 同步）
sudo apt update && sudo apt install -y rsync   # Debian/Ubuntu
# CentOS/RHEL: sudo yum install -y rsync
```

> 说明：把站点目录属主设为 `deploy`，这样 CI/CD 用 deploy 身份即可写入，无需 root。

---

## 3. 第二步：生成 CI/CD 专用 SSH 密钥对

在**你自己的电脑**（或任意安全的地方）生成，**不要**在服务器 `/root` 下生成。

**Windows PowerShell / macOS / Linux 通用：**

```bash
# ed25519 算法，更快更安全；-f 指定输出文件，不要用默认文件名以免覆盖个人密钥
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ./deploy_key
```

- 提示 `Enter passphrase` 时：
  - 为了 CI/CD **全自动**无人值守，可直接留空回车（无口令私钥）。
  - 若追求更安全，可设置口令，然后改用「加密后的 Secret + 在 workflow 里解锁」的方案（见第 8 节）。

生成两个文件：
- `deploy_key`　　→ **私钥**（保密，只进 GitHub Secrets）
- `deploy_key.pub` → **公钥**（可公开，放到服务器）

> 验证是否可用：`ssh-keygen -lf ./deploy_key.pub` 应打印指纹。

---

## 4. 第三步：把公钥部署到服务器

把 `deploy_key.pub` 的内容追加到**部署用户** deploy 的 `authorized_keys`。

**方式 A：从本地一键推送（需要此时能登录服务器）**
```bash
ssh-copy-id -i ./deploy_key.pub deploy@<服务器IP>
```

**方式 B：手动复制**
```bash
# 在服务器上：
sudo mkdir -p /home/deploy/.ssh
sudo touch /home/deploy/.ssh/authorized_keys
# 把本地 deploy_key.pub 里整行内容粘贴进去：
sudo nano /home/deploy/.ssh/authorized_keys

# 关键：权限必须正确，否则 sshd 会拒绝公钥登录
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

**（可选，推荐）限制这把公钥只能做部署相关操作**，在 `authorized_keys` 该行**最前面**加上：
```
command="/usr/local/bin/deploy-rsync.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,ssh-ed25519 AAAA... github-actions-deploy
```
> 简单训练阶段可先不加；正式环境建议加上 `from="<允许的IP>"` 与命令限制，缩小密钥被盗后的影响面。

**本地先自测登录（在你的电脑上）：**
```bash
ssh -i ./deploy_key -o StrictHostKeyChecking=accept-new deploy@<服务器IP> "echo OK && ls -ld /var/www/Web_training"
```
看到 `OK` 且能列目录，说明密钥配置成功。

---

## 5. 第四步：把私钥等写入 GitHub Secrets

进入仓库页面：**Settings → Secrets and variables → Actions → New repository secret**，逐个添加：

| Secret 名称     | 值                                                             |
|-----------------|---------------------------------------------------------------|
| `SERVER_HOST`   | 服务器公网 IP 或域名                                          |
| `SERVER_PORT`   | SSH 端口，通常 `22`                                           |
| `DEPLOY_USER`   | `deploy`                                                       |
| `DEPLOY_PATH`   | `/var/www/Web_training` （**不带结尾 `/`**，工作流会拼成 `<DEPLOY_PATH>/<成员>/`） |
| `SSH_PRIVATE_KEY` | 打开 `deploy_key`（私钥文件），**粘贴完整内容含首尾两行**     |

私钥粘贴示例（整段复制，包括空行）：
```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAA...(多行Base64)...
-----END OPENSSH PRIVATE KEY-----
```

> ⚠️ **部署隔离（重要）**：工作流已**不再**对整棵 `site/` 做 `rsync --delete`，
> 而是遍历 `site/*/` 每个成员目录，分别同步到 `<DEPLOY_PATH>/<成员>/`，
> `--delete` **只在该成员子目录内生效**，同步前还会把将被覆盖/删除的文件
> 备份到服务器 `/home/deploy/backups/<时间戳>/<成员>/`。因此**部署某个成员
> 永远不会波及其他人的线上内容**，误删也可从备份还原。`DEPLOY_PATH` 因此
> **不带**结尾斜杠（nginx 侧的 `alias /var/www/Web_training/;` 仍需带斜杠，两者独立）。

---

## 6. 第五步：配置 Nginx（挂载到已有项目，只新增不修改）

服务器现状：只有一个项目 `ynu-clubs`（`/etc/nginx/conf.d/ynu-clubs.conf`），
其 `443 ssl` server 块同时绑定 `yaustu.cn / www.yaustu.cn / 47.108.152.17`。
本项目**不独占端口/域名**，而是挂到该 server 块下、路径前缀 `/web_training/`。

做法：本项目的路由规则单独放 `/etc/nginx/snippets/web_training.conf`，
只在 ynu-clubs 的 443 块里加**一行 `include`**；已有的 `location /`、证书等一律不动。

推荐直接用仓库脚本（已内置：时间戳备份 → 安装片段 → 幂等插入 include → `nginx -t` 通过才 `reload`）：

```bash
# 把仓库 nginx/ 目录传到服务器后，在其父目录执行：
sudo bash nginx/install-route.sh
```

如手动操作，等价步骤为：

```bash
# 1) 备份
sudo cp -a /etc/nginx/conf.d/ynu-clubs.conf /etc/nginx/conf.d/ynu-clubs.conf.bak
# 2) 安装本项目路由片段
sudo mkdir -p /etc/nginx/snippets
sudo cp nginx/web_training.conf /etc/nginx/snippets/web_training.conf
# 3) 在 ynu-clubs 的 443 server 块内（index 行之后）加一行：
#        include /etc/nginx/snippets/web_training.conf;
sudo nano /etc/nginx/conf.d/ynu-clubs.conf
# 4) 校验并热加载（reload 不中断其他项目）
sudo nginx -t && sudo systemctl reload nginx
```

片段核心：

```nginx
location = /web_training { return 301 /web_training/; }
location /web_training/ {
    alias /var/www/Web_training/;   # = DEPLOY_PATH，结尾斜杠必须保留
    index index.html;
    try_files $uri $uri/ =404;
}
```

验证：`https://yaustu.cn/web_training/`（以及 `https://47.108.152.17/web_training/`，
后者因证书是给域名的会有名称告警，属正常）。确保 `DEPLOY_PATH` 与该片段里
`alias` 指向的目录一致即可。

---

## 7. 第六步：触发并验证部署

```bash
# 本地修改任意 site/ 下文件后
git add site/
git commit -m "chore: init static pages"
git push origin main
```

- 打开仓库 **Actions** 标签页，会看到 `Deploy Static Site` 工作流运行。
- 绿色成功 = 文件已同步到服务器；浏览器访问 `http://<服务器IP>/`、`/TMF/` 验证。
- 之后成员只需各自改 `site/<姓名>/`，push 即自动上线。

---

## 8. 安全加固建议

1. **优先用密钥、关闭 root 远程密码登录**：编辑 `/etc/ssh/sshd_config`
   ```
   PermitRootLogin no
   PasswordAuthentication no
   ```
   改完 `sudo systemctl restart sshd`（务必先确认密钥能登录再重启，避免把自己锁在外面）。
2. **给私钥设口令**：如需更高安全性，用带口令私钥时，把口令另存为一个 Secret（如 `SSH_KEY_PASSPHRASE`），并在 workflow 中用 `ssh-add` 解锁。
3. **最小权限**：部署用户只拥有站点目录写权限；生产环境可给它配仅限 `rsync`/特定命令的受限 shell（如 `rssh` 或 `command=` 限制）。
4. **定期轮换密钥**：私钥泄露时，删除服务器 `authorized_keys` 中该行 + 更换 GitHub Secret 即可，无需改 root 密码。
5. **仓库保护**：对 `main` 开启 Branch protection，要求 Actions 通过后才允许合并。

---

## 9. 常见问题排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| Actions 报 `Permission denied (publickey)` | 私钥与服务器公钥不匹配 / `authorized_keys` 权限错误 | 确认 Secret 用的是私钥本体；检查 `.ssh` 700、`authorized_keys` 600、属主正确 |
| 报 `Host key verification failed` | `known_hosts` 未预置 | workflow 已用 `ssh-keyscan`；确认 `SERVER_HOST/PORT` 正确 |
| 文件同步到了 `Web_training/site/` 里 | `DEPLOY_PATH` 或源路径斜杠不对 | 源 `site/` 和目标 `/var/www/Web_training/` 都要带结尾 `/` |
| rsync 命令找不到 | 服务器未装 rsync | `sudo apt install rsync` |
| 页面 404 | nginx root 与实际部署路径不一致 | 核对 `nginx/web_training.conf` 的 `root` 与 `DEPLOY_PATH` |
| 部署成功但页面没更新 | 浏览器缓存 / nginx 未 reload | 强刷或清缓存；`sudo systemctl reload nginx` |

---

### 附：本地 Windows 没有 ssh-keygen / rsync 怎么办
- Windows 10/11 自带 OpenSSH 客户端（含 `ssh-keygen`、`ssh`）。若没有：设置 → 可选功能 → 添加「OpenSSH 客户端」。
- `rsync` 主要由 **GitHub Actions Runner（Linux）** 执行，你本地无需安装；本地测试部署效果可直接 push 触发 Actions，或用 `scp -r site/* deploy@IP:/var/www/Web_training/` 临时验证。
