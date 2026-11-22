# infra

GTMC 论坛（forum.gtmc.top，Discourse）的部署配置和初始化脚本。

```
infra/
  deploy-discourse.sh   一键部署：拉代码、更新容器配置、装主题、跑初始化脚本
  discourse/app.yml     Discourse 容器配置
  discourse/*.rb        新站的初始化脚本（设置、侧边栏、徽章、新手机器人、主题）
  content/              欢迎帖、新人指南、新手机器人文案、管理员上线清单
```

## 现在的架构

论坛跑在 PVE 上的虚拟机 `gtmc-forum`（192.168.2.111，Debian），Discourse 官方 Docker 安装在 `/var/discourse`。
没有公网 IP，对外走 Cloudflare Tunnel：

    浏览器 → Cloudflare → cloudflared（虚拟机上）→ 192.168.2.111:8880 → Discourse 容器

- 隧道在 Cloudflare 后台（Zero Trust → Networks → Tunnels）管理，Public Hostname 指到 `http://192.168.2.111:8880`。
  tunnel token 只存在虚拟机的 cloudflared 服务里，不要提交进仓库。
- HTTPS 由 Cloudflare 终结，cloudflared 带 `X-Forwarded-Proto: https`，Discourse 据此生成 https 链接。
  真实 IP 取 `CF-Connecting-IP`，`app.yml` 里的 nginx 配置已经处理，不然限流会把所有人当成同一个人。
- 虚拟机 4 核 8G，`app.yml` 里数据库内存和 unicorn 数量按这个配的。
- 8880 只绑内网地址，不要放到公网网卡。

## 部署

插件（`gtmc-forum-plugin`）由 `app.yml` 的钩子在重建容器时克隆，主题（`gtmc-forum-theme`）由脚本让容器从 GitHub 安装，
所以这个仓库里没有它们。

在虚拟机上，从仓库检出目录里：

```bash
sudo infra/deploy-discourse.sh              # 更新
sudo infra/deploy-discourse.sh --rebuild    # 强制重建容器
```

脚本可重复运行，`app.yml` 没变就不重建（重建会停机几分钟）。新站第一次跑会执行初始化脚本，
把论坛设成社团的出厂设置；之后设置归后台管，脚本不再覆盖。备份用后台自带的备份功能。

可用的环境变量：`GTMC_FORUM_HOST`（临时覆盖 `app.yml` 里的域名 `forum.gtmc.top`）、`GTMC_FORCE_HTTPS`（默认 true）、`GTMC_SMTP_ENV_FILE`（默认 `/etc/gtmc/smtp.env`）。

### 发信

SMTP 密码放在虚拟机的 `/etc/gtmc/smtp.env`（root 600，不进仓库），每行 `键=值`：

```
DISCOURSE_SMTP_ADDRESS=smtpdm.aliyun.com
DISCOURSE_SMTP_PORT=465
DISCOURSE_SMTP_USER_NAME=...
DISCOURSE_SMTP_PASSWORD=...
DISCOURSE_SMTP_FORCE_TLS=true
DISCOURSE_NOTIFICATION_EMAIL=...
```

部署脚本发现这个文件就写进容器配置并打开邮件，没有就保持关闭。
阿里云邮件推送每天有额度，超了连激活信都发不出去；`site_settings.rb` 已经把通知邮件压低了，开放注册时也请分批放人。

### 从零装一台

1. 装 Docker（`get.docker.com`）。这台机器连不上 Docker Hub，给 `/etc/docker/daemon.json` 配镜像源：
   `{"registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run"]}`，重启 docker。GitHub 能直连。
2. `git clone https://github.com/discourse/discourse_docker.git /var/discourse`。
3. 克隆本仓库，`sudo GTMC_FORUM_HOST=forum.gtmc.top infra/deploy-discourse.sh`。
4. 装 cloudflared（Cloudflare 的 apt 源），`sudo cloudflared service install <token>`，
   日志里出现 4 行 `Registered tunnel connection` 就通了；连不上 QUIC 时在服务参数里加 `--protocol http2`。
5. 按 `content/admin-setup.md` 做手工步骤（建管理员、上传 Logo、发置顶帖）。

静态 IP 的坑：Debian 13 把网卡从 dhcp 改成 static 后，`/etc/resolv.conf` 会被清空，需要手写 `nameserver`。
