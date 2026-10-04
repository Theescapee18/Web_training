#!/usr/bin/env bash
# =====================================================================
# Web_training —— 在已有 nginx 配置中「只新增、不修改」本项目路由的脚本
# ---------------------------------------------------------------------
# 目标：把本项目挂到 ynu-clubs 的 443 server 块下，路径 /web_training/ 。
# 安全性：
#   - 修改前先带时间戳备份原文件；
#   - 用 grep 做幂等，重复执行不会插入两次；
#   - 只有 nginx -t 通过才 reload（reload 不中断现有连接）；
#   - nginx -t 失败则不 reload，并提示如何还原。
#
# 用法（在服务器上以 root 或 sudo 运行）：
#   sudo bash install-route.sh
# =====================================================================
set -euo pipefail

# ---- 可调参数 -------------------------------------------------------
TARGET="/etc/nginx/conf.d/ynu-clubs.conf"          # 要挂载进去的现有项目文件
SNIPPET_SRC="$(dirname "$0")/web_training.conf"     # 本仓库内的路由片段
SNIPPET_DST="/etc/nginx/snippets/web_training.conf" # 片段在服务器上的落点
SITE_ROOT="/var/www/Web_training"                   # 本项目站点根目录（=DEPLOY_PATH）
ANCHOR_LINE="index clubs.html index.html;"          # 在其所在 server 块后插入 include
# ---------------------------------------------------------------------

if [ ! -f "$TARGET" ]; then
  echo "!! 目标文件不存在：$TARGET"; exit 1
fi

# 1) 备份原文件
BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$TARGET" "$BACKUP"
echo "[1/5] 已备份：$BACKUP"

# 2) 部署路由片段
mkdir -p "$(dirname "$SNIPPET_DST")"
install -m 644 "$SNIPPET_SRC" "$SNIPPET_DST"
echo "[2/5] 片段已安装：$SNIPPET_DST"

# 3) 幂等插入 include 行（已存在则跳过）
if grep -q "snippets/web_training.conf" "$TARGET"; then
  echo "[3/5] include 已存在，跳过插入"
else
  sed -i "/$(echo "$ANCHOR_LINE" | sed 's/[.[\*^$/]/\\&/g')/a\\    include ${SNIPPET_DST};" "$TARGET"
  echo "[3/5] 已在 443 server 块内加入 include 行"
fi

# 4) 确保站点目录存在且 www-data 可读（属主存在则设为 deploy，否则 root 也可）
mkdir -p "$SITE_ROOT"
if id deploy >/dev/null 2>&1; then
  chown -R deploy:deploy "$SITE_ROOT" 2>/dev/null || true
fi
chmod 755 "$SITE_ROOT"
echo "[4/5] 站点目录就绪：$SITE_ROOT"

# 5) 语法校验，通过才 reload
echo "[5/5] nginx -t 校验中..."
if nginx -t; then
  systemctl reload nginx
  echo "✅ 完成并已 reload。访问： https://yaustu.cn/web_training/"
else
  echo "❌ nginx -t 失败，未 reload。其他项目不受影响。"
  echo "   如需还原： sudo cp -a $BACKUP $TARGET && sudo nginx -t && sudo systemctl reload nginx"
  exit 1
fi
