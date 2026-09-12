# 纳指定投计算器 · 部署手册

> 一套零成本、全自动的静态站点部署方案。覆盖 Cloudflare Pages、自有服务器两条路线，以及数据每日自动更新的链路。

---

## 目录

- [0. 项目结构](#0-项目结构)
- [1. 本地准备](#1-本地准备)
- [2. 数据自动更新（GitHub Actions）](#2-数据自动更新github-actions)
- [3. 部署方案 A：Cloudflare Pages（Git 集成）★ 推荐](#3-部署方案-acloudflare-pagesgit-集成-推荐)
- [4. 部署方案 B：Cloudflare Pages（拖拽上传）](#4-部署方案-bcloudflare-pages拖拽上传)
- [5. 部署方案 C：自有服务器](#5-部署方案-c自有服务器)
- [6. 自定义域名](#6-自定义域名)
- [7. 常见问题](#7-常见问题)
- [8. 日常维护](#8-日常维护)

---

## 0. 项目结构

```
ndx-calc/
├── index.html                      # 主页面（原 "!DOCTYPE html.txt" 改名而来）
├── update_ndx.sh                   # 数据抓取脚本
├── ndx-data.js                     # 纳指100 月线数据（脚本生成，勿手改）
├── spx-data.js                     # 标普500 月线数据（脚本生成，勿手改）
├── ndx.conf                        # API key 配置（可选，不要提交）
├── .gitignore
└── .github/
    └── workflows/
        └── update-data.yml         # 每日自动更新数据的 workflow
```

**要点：**

- 主页面**必须叫 `index.html`**，否则访问根路径 404。
- `ndx-data.js` / `spx-data.js` **不加也能跑**——页面内嵌了 1986-01 ~ 2026-08 的完整快照。但加上后，回测数据可以每日更新。
- `ndx.conf` 里放 API key，**绝对不能提交到公开仓库**。

`.gitignore`：

```
ndx.conf
*.tmp
```

---

## 1. 本地准备

### 1.1 初始化并推送到 GitHub

```bash
cd ndx-calc
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/<你的用户名>/ndx-calc.git
git push -u origin main
```

> **常见坑**：如果 `git push` 报 `src refspec main does not match any`，说明本地没有 commit。检查 `git log --oneline` 是否有输出，没有就先 `git add . && git commit -m "init"`。
>
> 如果 commit 静默失败，多半是 git 身份没配：
>
> ```bash
> git config --global user.name "你的名字"
> git config --global user.email "你的邮箱"
> ```

### 1.2 认证方式

GitHub 从 2021 年起**不接受账号密码**，两种方式二选一：

**方案 1：Personal Access Token（HTTPS）**

1. 打开 https://github.com/settings/tokens
2. **Generate new token (classic)**
3. Scopes 勾选：
   - ✅ `repo`
   - ✅ `workflow` ← **必须勾**，否则推 `.github/workflows/` 下的文件会被拒
4. 生成后立刻复制 `ghp_xxxxx`
5. push 时用户名填 GitHub 用户名，密码粘 token

**方案 2：SSH Key**

```bash
ssh-keygen -t ed25519 -C "你的邮箱"
cat ~/.ssh/id_ed25519.pub          # 复制公钥
```

打开 https://github.com/settings/keys → **New SSH key** → 粘贴 → 保存。

```bash
ssh -T git@github.com              # 验证
git remote set-url origin git@github.com:<用户名>/ndx-calc.git
```

---

## 2. 数据自动更新（GitHub Actions）

### 2.1 创建 workflow

新建 `.github/workflows/update-data.yml`：

```yaml
name: Update index data

on:
  schedule:
    # UTC 23:00 = 北京时间次日 07:00
    - cron: '0 23 * * *'
  workflow_dispatch:        # 允许手动触发

permissions:
  contents: write

concurrency:
  group: update-index-data
  cancel-in-progress: false

jobs:
  update:
    runs-on: ubuntu-latest
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Fetch & generate js
        env:
          NDX_FRED_KEY: ${{ secrets.NDX_FRED_KEY }}
          NDX_12D9_KEY: ${{ secrets.NDX_12D9_KEY }}
          NDX_AV_KEY:   ${{ secrets.NDX_AV_KEY }}
          NDX_TI_KEY:   ${{ secrets.NDX_TI_KEY }}
        run: bash update_ndx.sh

      - name: Commit if changed
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          if git diff --quiet -- ndx-data.js spx-data.js; then
            echo "数据没变化，跳过提交"
            exit 0
          fi
          git add ndx-data.js spx-data.js
          git commit -m "chore(data): $(date -u +%F) 自动更新指数月线"
          git pull --rebase origin main || true
          git push
```

> **`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` 说明**：Node.js 20 即将于 2026-06 弃用、2026-09 移除。这个环境变量让 Actions 提前在 Node.js 24 上跑，能消除 deprecation 警告。长期方案是把所有 Action 升级到支持 Node 24 的版本（如 `actions/checkout@v5`）。

### 2.2 配置 Secrets（可选）

脚本的**数据源降级顺序**：

```
东财 → FRED API → 腾讯行情 → Shiller → stooq → Yahoo
     → TwelveData → AlphaVantage → Tiingo → FRED Graph
```

**前几个免费源大概率能通，可以先不配任何 key 跑一次。** 全失败了再配：

| Secret 名 | 用途 | 申请地址 |
|---|---|---|
| `NDX_FRED_KEY` | FRED 官方 API（最稳） | https://fredaccount.stlouisfed.org/apikeys |
| `NDX_12D9_KEY` | TwelveData（800 次/天） | https://twelvedata.com/pricing |
| `NDX_AV_KEY` | AlphaVantage（25 次/天） | https://www.alphavantage.co/support |
| `NDX_TI_KEY` | Tiingo | https://www.tiingo.com/account/general/apikeys |

**配置步骤：**

1. 仓库 → **Settings** → **Secrets and variables** → **Actions**
2. 点 **New repository secret**
3. **Name** 填 `NDX_FRED_KEY`（一字不差，大小写敏感）
4. **Secret** 粘 key

   ⚠️ **别带首尾空格/换行**。粘完按 `End` 确认光标紧贴最后一个字符。
5. **Add secret**

> **坑**：`ndx.conf` 会 **source 覆盖** 环境变量。如果仓库里有 `ndx.conf`，Secrets 就白配了。二选一。

### 2.3 手动触发验证

1. 仓库 → **Actions** → 左侧选 **Update index data**
2. 右侧 **Run workflow** → 绿色按钮
3. 等十几秒，点进运行记录 → 左侧 **update** job → 展开 **Fetch & generate js**

**期望看到：**

```
== 纳指100 ==
  数据源: eastmoney (488 条)
[OK] 纳指100 1986-01 ~ 2026-08 共 488 个月 -> /.../ndx-data.js
== 标普500 ==
  数据源: eastmoney (488 条)
[OK] 标普500 1986-01 ~ 2026-08 共 488 个月 -> /.../spx-data.js
```

**如果全是 `源失败`：** 配 `NDX_FRED_KEY` 后重试。

---

## 3. 部署方案 A：Cloudflare Pages（Git 集成）★ 推荐

**优点**：push 即部署、免费、全球 CDN、自动 HTTPS。
**适用**：正常使用场景。Actions 自动提交的数据能自动上线。

### 3.1 新建 Pages 项目

1. 打开 https://dash.cloudflare.com/
2. 左侧 → **Workers & Pages**
3. 点 **Create** → 选 **Pages** 标签
4. 点 **Connect to Git**

### 3.2 授权并选仓库

1. 点 **Connect GitHub**
2. 弹窗选 **Only select repositories**，只勾 `ndx-calc`
3. **Install & Authorize**
4. 回到 Cloudflare，下拉框选 `wick233/ndx-calc`
5. **Begin setup**

### 3.3 构建设置

**这是唯一容易填错的地方：**

| 字段 | 值 |
|---|---|
| **Project name** | `ndx-calc`（会变成 `ndx-calc.pages.dev`） |
| **Production branch** | `main` |
| **Framework preset** | `None` |
| **Build command** | **留空** |
| **Build output directory** | `/` |
| **Root directory** | 留空 |
| **环境变量** | 不填 |

⚠️ **Build command 必须空着**。填了 `npm run build` 之类会失败——项目没有 `package.json`。

点 **Save and Deploy**。

### 3.4 等待首次部署

日志应该长这样：

```
Cloning repository...
Success: Finished cloning repository files
No build command specified, skipping build step.
Uploading... (5 files)
✨ Deployment complete!
```

30~60 秒后拿到地址：`https://ndx-calc.pages.dev`

### 3.5 验证自动更新链路

1. 去 GitHub **Actions** 手动跑一次数据更新
2. 等 bot 提交完成
3. 回到 Cloudflare **Deployments** 标签 —— **应该自动多出一条新部署**

如果没自动触发：**Settings → Builds & deployments** 检查 GitHub webhook。

---

## 4. 部署方案 B：Cloudflare Pages（拖拽上传）

**优点**：最快，2 分钟。
**缺点**：每次更新要手动重传，**Actions 自动提交的数据不会上线**。

**步骤：**

1. **Workers & Pages** → **Create** → **Pages** → **Upload assets**
2. 项目名填 `ndx-calc`
3. 把整个 `ndx-calc` 文件夹拖进去
4. **Deploy site**

**仅适合**：快速预览、临时演示。正式使用请用方案 A。

---

## 5. 部署方案 C：自有服务器

**优点**：完全掌控、可绑任意域名、无平台依赖。
**缺点**：要维护服务器、配 HTTPS、自己搞数据更新。

### 5.1 环境要求

- 一台能装 Nginx/Caddy 的 Linux 服务器（CentOS / Ubuntu / Debian 都行）
- 有公网 IP 和域名（可选，没域名用 IP 也能访问）
- 80 / 443 端口开放

### 5.2 上传代码

**方式 1：git clone（推荐，方便后续更新）**

```bash
# 服务器上
sudo mkdir -p /var/www/ndx-calc
sudo chown $USER:$USER /var/www/ndx-calc
cd /var/www/ndx-calc
git clone https://github.com/<用户名>/ndx-calc.git .
```

**方式 2：rsync 从本地推**

```bash
# 本地执行
rsync -avz --delete \
  --exclude='.git' \
  --exclude='ndx.conf' \
  ./ root@<服务器IP>:/var/www/ndx-calc/
```

### 5.3 方案 C1：Nginx

**安装：**

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y nginx

# CentOS / RHEL
sudo yum install -y nginx
sudo systemctl enable --now nginx
```

**配置 `/etc/nginx/conf.d/ndx-calc.conf`：**

```nginx
server {
    listen 80;
    server_name calc.example.com;      # 改成你的域名，没域名写 _

    root /var/www/ndx-calc;
    index index.html;

    # gzip 压缩（页面文字多，收益明显）
    gzip on;
    gzip_types text/html text/css application/javascript text/javascript;
    gzip_min_length 1024;

    # 安全头
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;

    # HTML 不缓存，js 数据短缓存
    location = /index.html {
        add_header Cache-Control "public, max-age=0, must-revalidate";
    }
    location ~* \.js$ {
        add_header Cache-Control "public, max-age=300";
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

**生效：**

```bash
sudo nginx -t                      # 语法检查
sudo systemctl reload nginx
```

**防火墙放行：**

```bash
# firewalld (CentOS)
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# ufw (Ubuntu)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 5.4 方案 C2：Caddy（更简单，自动 HTTPS）

**安装：**

```bash
# Ubuntu / Debian
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

**配置 `/etc/caddy/Caddyfile`：**

```
calc.example.com {
    root * /var/www/ndx-calc
    file_server

    encode gzip

    header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
    }

    @html path /index.html /
    header @html Cache-Control "public, max-age=0, must-revalidate"

    @js path *.js
    header @js Cache-Control "public, max-age=300"
}
```

**生效：**

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

**Caddy 会自动申请 Let's Encrypt 证书**，无需手动配 HTTPS。前提是域名的 A 记录已指向服务器 IP。

### 5.5 数据更新（服务器侧）

两种方式二选一：

#### 方式 1：服务器自己跑脚本 + cron

```bash
# 先手动测试能不能跑通
cd /var/www/ndx-calc
bash update_ndx.sh --probe           # 自检各数据源可用性
bash update_ndx.sh                    # 实际更新
```

跑通后配 cron：

```bash
crontab -e
```

加一行：

```cron
# 每天 07:00 更新数据
0 7 * * * cd /var/www/ndx-calc && bash update_ndx.sh >> /var/log/ndx-update.log 2>&1
```

> **注意**：脚本依赖 `curl` 和 GNU `date`。CentOS 7 默认的 `date` 支持 `-d`，没问题。Ubuntu/Debian 也支持。
>
> 如果服务器在**机房 IP**（如日本、美国 VPS），东财可能挡掉。建议先跑 `--probe` 看哪几个源能通。从**家宽 IP** 跑则最友好。

#### 方式 2：git pull 拉 GitHub Actions 生成的数据（推荐）

服务器只负责托管，数据由 GitHub Actions 生成、提交、推回仓库。

```bash
crontab -e
```

```cron
# 每 30 分钟拉一次最新代码
*/30 * * * * cd /var/www/ndx-calc && git pull --rebase origin main >> /var/log/ndx-sync.log 2>&1
```

**优点**：服务器不碰外网数据源，不受机房 IP 限制；数据一致性由 GitHub 保证。

**缺点**：延迟 30 分钟（对月频数据完全无感）。

### 5.6 无域名、只用 IP 访问

把 Nginx 配置里的 `server_name` 改成 `_` 或服务器 IP：

```nginx
server {
    listen 80 default_server;
    server_name _;
    root /var/www/ndx-calc;
    # ...
}
```

访问 `http://<服务器IP>/` 即可。

⚠️ **没域名就没法配 HTTPS**（除非用自签证书，但浏览器会报警告）。生产环境强烈建议买/绑一个域名。

### 5.7 服务器部署的日常维护

| 操作 | 命令 |
|---|---|
| 看 Nginx 日志 | `sudo tail -f /var/log/nginx/access.log` |
| 看数据更新日志 | `tail -f /var/log/ndx-update.log` |
| 重新加载配置 | `sudo nginx -t && sudo systemctl reload nginx` |
| 检查证书（Caddy） | `sudo journalctl -u caddy -n 50` |
| 检查证书（Nginx + certbot） | `sudo certbot certificates` |

---

## 6. 自定义域名

### 6.1 Cloudflare Pages

1. Pages 项目 → **Custom domains** → **Set up a custom domain**
2. 输入域名（如 `calc.example.com`）
3. **域名已托管在 Cloudflare**：自动加 CNAME 记录，点 **Activate domain**
4. **域名不在 Cloudflare**：去注册商加 CNAME `calc` → `ndx-calc.pages.dev`
5. 等 DNS 生效，SSL 自动签发

### 6.2 自有服务器

在域名注册商/Cloudflare DNS 加一条 **A 记录**指向服务器 IP：

```
类型: A
名称: calc
值:   1.2.3.4       # 你的服务器 IP
TTL:  Auto
```

等 DNS 生效（通常 1~5 分钟）。**用 Caddy 会自动签 HTTPS**；用 Nginx 则：

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d calc.example.com
```

---

## 7. 常见问题

### Q1：`git push` 报 `src refspec main does not match any`

本地没有 commit。检查：

```bash
git log --oneline          # 有没有输出？
git branch                 # 显示 main 还是 master？
```

没有 commit → `git add . && git commit -m "init"`
分支是 master → `git branch -M main`

### Q2：`git push` 报 `refusing to allow a PAT to create or update workflow`

Token 缺 `workflow` scope。

1. https://github.com/settings/tokens → 编辑 token → 勾上 `workflow` → 更新
2. **清掉 git 缓存的旧凭据**（这一步必做，否则新 scope 不生效）：

   ```bash
   git credential-cache exit 2>/dev/null
   sed -i '/github.com/d' ~/.git-credentials 2>/dev/null
   ```
3. 重新 `git push`

### Q3：`git push` 报 `rejected ... fetch first`

远端有你没有的提交（多半是 Actions bot 的）。

```bash
git pull --rebase origin main
git push
```

### Q4：Pages 构建失败

99% 是 **Build command 没留空**。去 **Settings → Builds & deployments** 改成空，然后 **Retry deployment**。

### Q5：Node.js 20 deprecation 警告

不影响运行，但建议处理：

- 升级 `actions/checkout@v4` → `@v5`
- 或在 workflow 顶层加 `env: FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`

### Q6：回测数据显示"数据未加载"

浏览器 F12 Console 看：

- `ndx-data.js 404` → 检查文件是否在仓库根目录、是否已 push
- 页面能开但回测空 → 打开 **Actions** 看数据更新是否成功

### Q7：国内访问 `*.pages.dev` 慢

两个办法：

1. **绑自定义域名**（会好很多）
2. **DNS 优选 IP**：搜"Cloudflare 优选 IP"，在 DNS 里手动指定较快的 Cloudflare 节点 IP

### Q8：`ndx.conf` 泄露了怎么办

1. **立刻去对应平台撤销/重置 key**（FRED、TwelveData、AlphaVantage、Tiingo）
2. 从 git 历史里移除：

   ```bash
   git rm --cached ndx.conf
   echo "ndx.conf" >> .gitignore
   git commit -m "chore: 移除泄露的配置文件"
   git push
   ```

   > 注意：这**不会**清除历史提交里的内容。彻底清除需 `git filter-repo`，但 key 已撤销就不用折腾了。

---

## 8. 日常维护

### 8.1 完整链路图（Cloudflare Pages）

```
┌─────────────────────────────────────────────────────────┐
│  每天 07:00 (北京时间)                                   │
│  GitHub Actions 跑 update_ndx.sh                        │
│         ↓                                               │
│  生成 ndx-data.js / spx-data.js 并 commit + push         │
│         ↓                                               │
│  Cloudflare 检测到 push，自动重新部署                     │
│         ↓                                               │
│  访客打开页面，回测用最新数据                              │
└─────────────────────────────────────────────────────────┘
```

### 8.2 完整链路图（自有服务器 + git pull）

```
GitHub Actions 生成数据 → push 到仓库
                              ↓
服务器 cron 每 30 分钟 git pull
                              ↓
Nginx/Caddy 直接读文件系统，新数据立即生效
```

### 8.3 改页面的流程

```bash
# 1. 改 index.html
git add index.html
git commit -m "update: xxx"
git pull --rebase origin main     # 防止和 bot 撞车
git push
```

Cloudflare Pages 自动部署；自有服务器等 cron 拉取（或手动 `git pull`）。

### 8.4 定期检查

| 频率 | 检查项 |
|---|---|
| 每周 | GitHub Actions 有没有跑红 |
| 每月 | 数据是否正常更新（月末后几天看一眼） |
| 每季度 | Token / API key 是否快过期 |
| 每年 | Actions 依赖版本是否该升级 |

### 8.5 免费额度参考

| 服务 | 免费额度 | 你的用量 |
|---|---|---|
| Cloudflare Pages | 500 次构建/月、无限带宽 | 每月 ~35 次构建 |
| GitHub Actions | 公开仓库无限、私有 2000 分钟/月 | 每次 ~30 秒 |
| FRED API | 120 次/分钟 | 每天 1 次 |
| Cloudflare DNS | 无限 | — |

**结论**：完全在免费额度内，无需付费。

---

## 附：快速部署 checklist

- [ ] `index.html` 已改名、`.gitignore` 已排除 `ndx.conf`
- [ ] 本地 `git init` + 首次 commit + push 成功
- [ ] `.github/workflows/update-data.yml` 已提交
- [ ] GitHub Actions 手动触发一次，跑通
- [ ] （可选）配置 `NDX_FRED_KEY` 等 Secrets
- [ ] Cloudflare Pages 接上 GitHub 仓库
- [ ] Build command 留空、Output directory 填 `/`
- [ ] 首次部署成功，访问 `*.pages.dev` 正常
- [ ] 手动触发 Actions，验证 Pages 自动重新部署
- [ ] （可选）绑自定义域名

---

*最后更新：2026-09-12*
