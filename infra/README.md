# infra 部署手册

本文件是 `infra/` 下各配置文件的部署步骤，对应 `PLAN.md` 第 5 节的 I1、I2、I3。
写代码的规范见 `AGENTS.md`，论坛设置归谁管、怎么备份和回档见 `CONFIGURATION.md`，
这里只管「在哪台机器上按什么顺序敲什么命令」。

没在真机上执行过的步骤和配置项，在所在小节里用「未验证：」开头的一行标出，执行后把结论补进正文、删掉那一行。

## 0. 约定

两台机器，文中的提示符表示命令在哪台执行：

| 提示符 | 机器 | 说明 |
|---|---|---|
| `VPS$` | 境外 VPS，Debian 12 | 终结 HTTPS，跑 frps、Caddy、给自有机器用的 HTTP 代理 |
| `HOME$` | 论坛虚拟机（PVE 上的 `100 gtmc-forum`），Debian | 跑 Discourse 容器，无公网 IP，经 frp 暴露（见「部署前提」） |

`HOME$` 上的命令默认用普通用户执行、需要时加 `sudo`；只能 root 做的步骤会写明在 root shell 里做。

需要替换的占位符：

| 占位符 | 换成 | 出现在 |
|---|---|---|
| `CHANGEME.forum.domain` | 真实论坛域名（`FORUM_HOST`） | `infra/caddy/Caddyfile`、`infra/discourse/app.yml`、Caddy 证书申请 |
| `CHANGEME.vps.ip` | VPS 的公网 IP | `infra/frp/frpc.toml`、SSH 隧道 |
| `CHANGEME-long-random-string` | 长随机串，两份 frp 配置里必须一致 | `infra/frp/frps.toml`、`infra/frp/frpc.toml` |

生成 token：`openssl rand -hex 32`（任意机器上跑一次，贴进两份配置，不要进仓库）。

端口一览，后面对命令有用：

| 端口 | 在哪 | 谁能访问 | 用途 |
|---|---|---|---|
| 22 | VPS | 公网 | SSH |
| 80 | VPS | 公网 | Caddy 申请证书、跳转 HTTPS |
| 443 | VPS | 公网 | Caddy 的 HTTPS 入口 |
| 7000 | VPS | 公网（只允许 frpc 连） | frps 控制端口 |
| 8880 | VPS | 仅 127.0.0.1 | frps 转出来的论坛端口，Caddy 反代目标 |
| 8888 | VPS | 仅 127.0.0.1 | 给自有机器用的 HTTP 代理 |
| 8880 | 自有机器 | 仅 127.0.0.1 | Discourse 容器 |
| 8118 | 自有机器 | 127.0.0.1 和 172.17.0.1 | SSH 隧道出来的代理端口 |

## 部署前提：PVE 宿主机与虚拟机

社团自有机器（X99）跑 Proxmox VE 9：节点 `gtmc`，内网 `192.168.2.108`，网关 `192.168.2.1`，32 线程、64G 内存，传统 BIOS 启动。
宿主机本身不需要代理，I2 的代理都配在论坛虚拟机里。软件源用北外 `mirrors.bfsu.edu.cn`：中科大和清华的镜像对这台机器返回 403。

- **存储**：
  - `local-btrfs`：128G 固态（`sdb3`），btrfs，数据 single、元数据 DUP。放 PVE 系统、论坛虚拟机系统盘和吃 IO 的 MC 服。
  - `hdd`：1T 机械盘（`sda3`），ext4，挂在 `/mnt/hdd`（fstab 带 `nofail`，PVE 存储设了 `is_mountpoint`，内容类型 `images,rootdir,backup,iso,vztmpl`）。
    放大容量的 MC 服和虚拟机磁盘、vzdump 备份、Discourse 备份副本和 ISO。
  - 两块盘的引导分区 `sda2`、`sdb2` 都由 `proxmox-boot-tool` 同步。
- **论坛放 KVM 虚拟机，不放 LXC**：Discourse 只支持官方 Docker 安装，Docker 跑在 LXC 里要开 nesting，
  非特权容器下 overlayfs 和 cgroup 常出问题，升级 PVE 时也容易坏。
  虚拟机 `100 gtmc-forum`（`192.168.2.111`）：4 核、8G 内存，CPU 类型 `host`，开启 qemu-guest-agent；
  25G 系统盘放 `local-btrfs`、开启 `discard`，不够时 `qm resize` 扩容或再挂 `hdd` 上的盘放附件和备份。
  按 8G 内存，`db_shared_buffers` 取 2048MB（约内存的 25%）、`UNICORN_WORKERS` 取 3（`app.internal.yml` 已是这两个值，
  `app.yml` 里还是 4096MB 和 4，换用它时要改）。
- **frpc 装在论坛虚拟机里**，「frpc → `127.0.0.1:8880` → 容器」这一段与单机时相同，`app.yml`、`frpc.toml`、Caddy 都不用为 PVE 改。
- **MC 服放其他虚拟机或 LXC**（不需要 Docker），4 个服可以各一台也可以合并，按负载分内存。
  MC 插件不能走本机回环：`forum_url` 填论坛虚拟机的内网地址，`app.yml` 的 `expose` 额外绑定内网 IP
  （如 `192.168.2.111:8880:80`），`Host` 和 `X-Forwarded-Proto` 两个头照旧带。
- **内网的 8880 只放行 MC 那几台机器**：容器里的 nginx 信任 docker 网桥地址发来的 `X-Forwarded-For`（见 `app.yml`），
  而经端口映射进来的请求来源都是网桥地址，谁能连上这个端口谁就能伪造真实 IP。用 PVE 防火墙把论坛虚拟机的 8880
  限定为只接受各 MC 机器的地址。
- **备份**：Discourse 自带的每日备份（可以单独恢复到任何机器）之外，用 PVE 的 vzdump 每周整机备份论坛虚拟机和 MC 机器，
  存到 `hdd`。两者不互相替代。

---

## I1 VPS 入口

未验证：本节在任何机器上都没跑过，包括 apt 包名、`ss` 输出格式、`nmap` 结果形态。

### I1.1 基础准备

```
VPS$ sudo apt update && sudo apt install -y curl ca-certificates openssl tinyproxy
VPS$ sudo timedatectl set-timezone Asia/Shanghai   # 日志时间和你对得上，排障时少换算一次
```

Caddy 的证书申请依赖系统时间正确，`timedatectl` 的输出里 `System clock synchronized: yes` 是前提。

### I1.2 安装 frps

frp 没有进 Debian 官方源，用官方 release 的二进制。版本号以
<https://github.com/fatedier/frp/releases> 上最新一个 `linux_amd64` 包为准，
`frps` 和 `frpc`（I2 用）建议用同一个版本。

```
VPS$ FRP_VERSION=0.61.0      # 按 release 页面实际版本改
VPS$ cd /tmp
VPS$ curl -fLO https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz
VPS$ tar xzf frp_${FRP_VERSION}_linux_amd64.tar.gz
VPS$ sudo mkdir -p /etc/frp
VPS$ sudo install -m 0755 frp_${FRP_VERSION}_linux_amd64/frps /usr/bin/frps
VPS$ /usr/bin/frps --version
```

装在 `/usr/bin` 是为了和 `infra/systemd/frps.service` 里的 `ExecStart` 对上；
装到别处就必须同步改 service 文件，否则 systemd 报 `status=203/EXEC`。

把本仓库的 `infra/frp/frps.toml` 拷到 `/etc/frp/frps.toml`，改掉 `auth.token`：

```
VPS$ sudo install -m 0640 /path/to/repo/infra/frp/frps.toml /etc/frp/frps.toml
VPS$ sudoedit /etc/frp/frps.toml      # 填 auth.token
```

然后装 systemd 单元：

```
VPS$ sudo install -m 0644 /path/to/repo/infra/systemd/frps.service /etc/systemd/system/frps.service
VPS$ sudo systemctl daemon-reload
VPS$ sudo systemctl enable --now frps
VPS$ systemctl status frps --no-pager
VPS$ journalctl -u frps -n 30 --no-pager
```

**验收**：`systemctl status frps` 是 `active (running)`，`journalctl` 里能看到 frps 开始监听 7000。
这时还没有 frpc 连上来，`ss -lntp | grep 8880` 应该是空的。

未验证：`infra/frp/frps.toml` 与 `frpc.toml` 按 frp v0.52+ 的 TOML 格式写，没用 `frps verify` 校验过，
装完后跑一次 `sudo frps verify -c /etc/frp/frps.toml`（frpc 同理）。

未验证：官方压缩包自带的 `frps.service`、`frpc.service` 与 `infra/systemd/` 下这两份内容不同（尤其 `ExecStart` 路径和 `RestartSec`），
二选一，不要同时启用；本仓库这两份没做过语法校验，可用 `systemd-analyze verify frps.service` 检查。

### I1.3 安装 Caddy

用官方 apt 源（`apt install caddy` 装的是 Debian 自己的包，版本旧，插件少，不用它）：

```
VPS$ sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
VPS$ curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
     | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
VPS$ curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
     | sudo tee /etc/apt/sources.list.d/caddy-stable.list
VPS$ sudo apt update && sudo apt install -y caddy
VPS$ caddy version
```

这个包自带 `caddy.service`（`After=network-online.target`、开机自启），不用另写单元文件；
我们只替换配置：

```
VPS$ sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak   # 覆盖前留个原件，便于对照默认值
VPS$ sudo install -m 0644 /path/to/repo/infra/caddy/Caddyfile /etc/caddy/Caddyfile
VPS$ sudoedit /etc/caddy/Caddyfile                            # 把 CHANGEME.forum.domain 换成真实域名
VPS$ sudo caddy validate --config /etc/caddy/Caddyfile
VPS$ sudo systemctl reload caddy
VPS$ journalctl -u caddy -n 50 --no-pager
```

`caddy validate` 必须通过再 reload；带病配置 reload 会被拒绝并保留旧配置，日志里会写哪一行错。

**验收（I1 的一半）**：后端还没起时 `curl -I` 拿到 502，但证书已经有效：

```
VPS$ curl -sI https://CHANGEME.forum.domain | head -3
HTTP/2 502

VPS$ echo | openssl s_client -connect CHANGEME.forum.domain:443 \
       -servername CHANGEME.forum.domain 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates
```

`issuer` 是 Let's Encrypt、`notAfter` 在三个月内，说明证书申请成功。502 属正常，因为 I2 还没做完。

未验证：`infra/caddy/Caddyfile` 没做过语法校验，以 `caddy validate` 通过为准。

未验证：这里假设 Caddy 默认不信任客户端自带的 `X-Forwarded-*`（未设置全局 `trusted_proxies` 时应如此），伪造的 XFF 会被丢弃。
用 `curl -H 'X-Forwarded-For: 1.2.3.4' https://CHANGEME.forum.domain` 访问一次，在管理后台确认记录到的 IP 不是 1.2.3.4。

### I1.4 只监听回环的 HTTP 代理

自有机器在大陆，连不上 Docker Hub、GitHub 不稳定，I2 的所有拉取都要经这台 VPS 走代理。
代理**只能**监听回环，靠 SSH 隧道给自有机器用，不对公网开放——相当于一个受 SSH 保护的出口。

```
VPS$ sudoedit /etc/tinyproxy/tinyproxy.conf
```

改动三处（其它保持默认）：

```
Listen 127.0.0.1        # 默认是 0.0.0.0，改成回环，公网就扫不到
Port 8888               # 默认 8888，保持即可；改了就同步改 I2 的隧道命令
Allow 127.0.0.1         # 只允许来自本机回环的连接（SSH 隧道正好从回环进来）
```

重新加载并验收：

```
VPS$ sudo systemctl enable --now tinyproxy
VPS$ sudo systemctl restart tinyproxy
VPS$ sudo systemctl status tinyproxy --no-pager
VPS$ ss -lntp | grep 8888
LISTEN 0  128  127.0.0.1:8888  0.0.0.0:*  users:(("tinyproxy",pid=...,fd=...))
VPS$ curl -x http://127.0.0.1:8888 -sI https://github.com | head -1
```

`ss` 那一行必须是 `127.0.0.1:8888`，出现 `0.0.0.0:8888` 或 `*:8888` 说明 `Listen` 没改对。
`curl -x` 返回 `HTTP/2 200`（或 301）说明代理本身能出网。

未验证：`Allow 127.0.0.1` 按「限制来源 IP」理解。经隧道来的请求被拒时对照 `tinyproxy.conf` 的注释调整；`Listen 127.0.0.1` 无论如何都要保留。

### I1.5 防火墙

只放行 22、80、443、7000。其余入站一律丢弃——8880 和 8888 只被回环访问，
不写例外规则它们就天然不可达，这是第二层保险。

用 ufw（Debian 12 下它写的是 nftables 规则，不必再自己维护一份 nftables）：

```
VPS$ sudo apt install -y ufw
VPS$ sudo ufw default deny incoming
VPS$ sudo ufw default allow outgoing
VPS$ sudo ufw allow 22/tcp comment 'ssh'
VPS$ sudo ufw allow 80/tcp comment 'caddy acme and redirect'
VPS$ sudo ufw allow 443/tcp comment 'caddy https'
VPS$ sudo ufw allow 7000/tcp comment 'frps control'
VPS$ sudo ufw enable          # 会提示可能中断现有 ssh 连接，确认规则里有 22 再回车
VPS$ sudo ufw status verbose
```

如果坚持手写 nftables（`/etc/nftables.conf`，之后 `sudo systemctl enable --now nftables`），
等价规则是：

```
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    tcp dport { 22, 80, 443, 7000 } accept
    counter comment "dropped inbound"   # 被丢弃的包会计数，排查「为什么连不上」时看这里
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output { type filter hook output priority 0; policy accept; }
}
```

两种方式只能选一个，混用会让规则互相覆盖。

未验证：nftables 版本没实际加载过，可先用 `sudo nft -c -f /etc/nftables.conf` 做语法检查。

还有一条 ufw 管不到的东西：**Docker 发布会自己写转发规则，绕过 ufw**。
所以 `infra/discourse/app.yml` 里的 `expose: "127.0.0.1:8880:80"` 必须保持只绑回环，
不要为了图方便改成 `8880:80`——那样 ufw 拦不住，端口直接对公网开放。

**验收（I1 的另一半）**：从**别的机器**（不是 VPS，也不是经 SSH 隧道）扫：

```
laptop$ nmap -Pn -p 22,80,443,7000,8880,8888,8118 CHANGEME.vps.ip
```

应当只有 22、80、443、7000 是 `open`，8880/8888/8118 是 `closed` 或 `filtered`。
再从 VPS 自己看监听地址：

```
VPS$ sudo ss -lntp
VPS$ sudo ufw status numbered
```

8880 只出现在 `127.0.0.1`，8888 只出现在 `127.0.0.1`；ufw 列表里只有 22/80/443/7000。

---

## I2 自有机器安装 Discourse

顺序有依赖：先隧道和代理（否则后面什么都拉不下来），再 Docker 和它的代理，再 frpc，最后 rebuild。
每一步都带验收命令，做完 I2.1–I2.4 各自的验收再 rebuild：代理没生效时，只在 `./launcher rebuild` 阶段才报错。

### I2.0 没有 VPS：只打通内网

域名和 VPS 没到位时（PLAN 的 H1），I2.1~I2.4 里的隧道、代理、frpc 都做不了。
这时用下面这套「无代理直连 + 国内镜像源」的装法，机器起来后内网可访问，
外网访问等 VPS 到位再补。配置见 `infra/discourse/app.internal.yml`。

在论坛虚拟机（`100 gtmc-forum`，`192.168.2.111`）上实测过的结果：

| 目标 | 结果 |
|---|---|
| `registry-1.docker.io`、`auth.docker.io`、`gcr.io` | 全部超时（被封） |
| `github.com` 0.5s、`raw.githubusercontent.com` 0.2s | 通，不需要代理 |
| `get.docker.com` 0.8s、`download.docker.com` 0.1s | 通 |
| `ghcr.io`、`quay.io` | 通（401，正常鉴权响应） |
| `docker.m.daocloud.io`、`docker.1ms.run` | 通，能换到 token 并取到 `discourse/base:release` 的 manifest |

所以只需要给 Docker Hub 配镜像源，其他都不配代理：

```
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true
}
EOF
sudo systemctl restart docker
HOME$ docker info | grep -A3 -i "registry mirrors"
HOME$ docker pull discourse/base:release      # 验收：约 3GB 能拉完就说明镜像源可用
```

**踩过的坑：改成静态 IP 后 DNS 会消失。** Debian 13 的 `ifupdown` 用 `dhcpcd` 拿 DHCP，
`dhcpcd` 会接管 `/etc/resolv.conf`；把网卡从 `inet dhcp` 改成 `inet static` 并
`systemctl restart networking` 之后，`dhcpcd` 退出前把 `resolv.conf` 重写成只剩一行注释，
于是 `apt`、NTP、`curl` 全部报「暂时不能解析域名」，但 `ping 223.5.5.5` 是通的。
静态配置下没人再写这个文件，直接写死即可：

```
HOME$ sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF
HOME$ getent hosts mirrors.bfsu.edu.cn     # 有输出才算好
```

部署顺序：装 Docker（用 `get.docker.com` 的官方脚本，得到 docker-ce）→ 配上面的镜像源
→ 克隆 `discourse_docker` 到 `/var/discourse` → 克隆本仓库 → 跑一键部署脚本：

```
HOME$ git clone --depth 1 https://github.com/GTIIT-MC-Club/gtmc-forum-infra.git ~/gtmc-forum-infra
HOME$ sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORCE_HTTPS=false \
        ~/gtmc-forum-infra/infra/deploy-discourse.sh
```

这个脚本做三件事：拉最新代码 → 把选定的 `app.yml` 装到 `/var/discourse/containers/`
（内容没变就不重建容器，重建有停机；插件 `gtmc-forum-plugin` 由 `app.yml` 的钩子在重建时克隆）
→ 从 GitHub 更新主题 `gtmc-forum-theme`。
新站第一次部署时还会先跑一遍初始化脚本，把论坛设成社团的出厂设置；之后论坛设置归后台管理，部署不再改它们
（见仓库根目录的 `CONFIGURATION.md`）。

脚本可重复执行。`GTMC_FORCE_HTTPS=false` 必须在没有 TLS 的阶段传（只在初始化时用到），
否则 `force_https` 打开后全站 301 到 https:// 而那个端口没有 TLS。
域名和 TLS 就绪后到后台打开 `force_https`，部署时去掉 `GTMC_APP_TEMPLATE`。

**内网阶段的第一个管理员**：邮件是关着的，网页注册的账号收不到激活信、登不进去，
所以第一个管理员在容器里直接建（建出来就是已激活的），之后用它在后台给别人改权限：

```
HOME$ cd /var/discourse && sudo ./launcher enter app
app# rake admin:create        # 按提示填邮箱、密码，问是否设为管理员时答 Y
```

论坛的数据（帖子、用户、站点设置、主题）在这台机器自己的数据库里，**和本地开发站不互通**。
本地开发时在后台点出来的东西不会跟过来；能跟过来的只有写进本仓库脚本的那部分。

**踩过的坑：不要引 `templates/web.china.template.yml`。** 它的 `before_code` 把容器里所有
`https://github.com/` 改写成 `https://mirror.ghproxy.com/https://github.com/`，而这个代理站从
这台机器连不上（`curl` 6 秒超时），`git fetch` 于是无限重试，`./launcher rebuild` 永远停在
「拉代码」那一步，最后报 `bootstrap failed with exit code 128` 或干脆不动。它顺带配的 gem/npm
镜像也不需要：直连 `rubygems.org` 0.29s、`registry.npmjs.org` 0.12s，而 `mirrors.tuna.tsinghua.edu.cn`
对这台机器返回 403。

```
HOME$ sudo install -o root -g root -m 644 app.internal.yml /var/discourse/containers/app.yml
HOME$ cd /var/discourse && sudo ./launcher rebuild app
```

插件仓库 `gtmc-forum-plugin` 和主题仓库 `gtmc-forum-theme` 都是公开的，所以容器里 `hooks.after_code` 的 `git clone`
和 `import_theme.rb` 安装主题都不需要令牌；改成私有仓库时要换成只读 Deploy Key，不要把 PAT 写进 `app.yml`。

### I2.0a 有域名、没有 VPS：用 Cloudflare Tunnel 对外

域名托管在 Cloudflare 上时，可以先不买 VPS：在论坛虚拟机里跑 `cloudflared`，它主动连到 Cloudflare，
HTTPS 由 Cloudflare 终结（真实 IP 取 `CF-Connecting-IP`），家里不用开端口。这是过渡方案，原因有两个：

- Cloudflare 免费版在大陆没有节点，国内访问要绕路，速度随运营商和时段波动。要用手机流量、校园网实测过再决定长期用不用。
- 第三期的 bridge 必须在境外机器上和 Discord 通信，到时候 VPS 还是要买，入口可以一起迁回 Caddy + frp。

**1. 在 Cloudflare 后台建 tunnel**（只能在网页上做）：Zero Trust → Networks → Tunnels → Create a tunnel →
Cloudflared，起名 `gtmc-forum`。Public Hostname 填论坛域名（如 `tempforum.<domain>`），
Service 选 HTTP、地址 `192.168.2.111:8880`（`app.internal.yml` 的 `expose` 只绑这个地址，不绑回环）。
复制页面上 `cloudflared service install` 后面那串 token。token 能冒充这条隧道，不要发到群里或提交进仓库。

**2. 在论坛虚拟机上装 cloudflared**（Cloudflare 的 apt 源，跟着系统一起升级）：

```
HOME$ sudo mkdir -p --mode=0755 /usr/share/keyrings
HOME$ curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
HOME$ echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        | sudo tee /etc/apt/sources.list.d/cloudflared.list
HOME$ sudo apt-get update && sudo apt-get install -y cloudflared
HOME$ sudo cloudflared service install <token>
HOME$ journalctl -u cloudflared -n 30 --no-pager | grep -i 'registered tunnel connection'
```

正常会看到 4 行 `Registered tunnel connection`。没有的话看日志里是不是 QUIC（UDP 7844）连不上，
是的话在 `/etc/systemd/system/cloudflared.service` 的启动参数里加 `--protocol http2` 后 `systemctl daemon-reload && systemctl restart cloudflared`。

**3. 用域名重新部署**。`GTMC_FORCE_HTTPS` 保持默认的 true：浏览器到 Cloudflare 这一段是 HTTPS，
cloudflared 会带上 `X-Forwarded-Proto: https`，Discourse 据此生成 https 链接。

```
HOME$ sudo GTMC_APP_TEMPLATE=app.internal.yml GTMC_FORUM_HOST=tempforum.<domain> \
        ~/gtmc-forum-infra/infra/deploy-discourse.sh
```

之后 `http://192.168.2.111:8880` 不再是可用的入口：页面里的链接、登录后的跳转都指向域名，
登录 cookie 也只在 https 下发。调试时直接 `curl -H 'Host: tempforum.<domain>' http://192.168.2.111:8880/`。

**4. 验收**：

- 在虚拟机上 `curl -sI https://tempforum.<domain>/ | head -1` 返回 200。
  不要用开着代理的电脑测 DNS 和速度：代理软件的 fake-ip 会让 `dig` 返回 `198.18.x.x`，速度测的也是代理线路。
- 用手机流量打开一次论坛，再看 `/var/discourse/shared/standalone/log/var-log/nginx/access.log` 最后一行，
  来源 IP 应该是手机的公网地址，不是 `172.x` 或 `192.168.2.111`。是后者说明真实 IP 没取到，限流会误伤所有人。

### I2.0b 发信

发信用阿里云邮件推送（免费每天 200 封，服务器在国内，学校邮箱收得到；论坛虚拟机连 `smtpdm.aliyun.com:465` 实测可通）。
域名只是发件人的身份，真正投递靠发信服务：Cloudflare 只能收信转发、不能发信，自建 SMTP 又过不了 25 端口封锁和 IP 信誉。

**1. 阿里云控制台**（地域选华东1（杭州），`smtpdm.aliyun.com` 是这个地域的地址）：
发信域名里新建发信用的子域名（如 `tempmail.<domain>`），把控制台列出的 DKIM、SPF、DMARC 三条 TXT 和一条 MX
记录加到 Cloudflare DNS，点验证；再新建发信地址 `noreply@<发信域名>`，类型选「触发邮件」，设置 SMTP 密码。
阿里云要求发件人和登录用的发信地址一致，Discourse 所有通知都从 `notification_email` 这一个地址发，正好满足。

**2. 在论坛虚拟机上写 `/etc/gtmc/smtp.env`**（只有 root 能读，密码不进仓库）：

```
# /etc/gtmc/smtp.env，属主 root、权限 600。由 infra/deploy-discourse.sh 合并进容器配置，改完重跑部署脚本生效。
DISCOURSE_SMTP_ADDRESS=smtpdm.aliyun.com
DISCOURSE_SMTP_PORT=465
DISCOURSE_SMTP_USER_NAME=noreply@tempmail.<domain>
DISCOURSE_SMTP_PASSWORD=CHANGEME
# 465 是直接 TLS。不必再把 SMTP_ENABLE_START_TLS 设成 false：FORCE_TLS 打开时核心本来就不用 STARTTLS，
# 而设成 false 会让后台仪表盘一直挂一条「STARTTLS 已禁用」的高优先级警告
DISCOURSE_SMTP_FORCE_TLS=true
# Discourse 把任何 DISCOURSE_<站点设置名> 当成全局设置，覆盖同名站点设置并在后台隐藏
DISCOURSE_NOTIFICATION_EMAIL=noreply@tempmail.<domain>
```

每行 `键=值`，值不加引号、原样写，`#` 开头的行是注释。部署脚本发现这个文件就把这些键写进 `app.yml` 的 env 段、
去掉 `DISCOURSE_DISABLE_EMAILS`，所以重跑部署脚本（会重建一次容器）后邮件就打开了。
装到 `/var/discourse/containers/app.yml` 的成品里有密码，脚本按 600 权限安装。

**3. 额度**：Discourse 没有全站每日上限，超过 200 封后连注册激活信、密码重置都会失败。
`site_settings.rb` 已经压低了通知类邮件（关摘要、每人每天最多 5 封、通知 30 分钟后才发等，理由见脚本注释）。
另外两条要靠人：开放注册时分批放人，每天四五十人；在阿里云控制台看到当天快用完时，
后台把 `disable_emails` 设为 `non-staff`，只给管理员发信，第二天再改回 `no`。

### I2.1 建立 SSH 隧道到 VPS 的代理

未验证：I2.1~I2.5 在任何机器上都没跑过。

在自有机器上开一条到 VPS 的本地转发。`-N` 表示只转发不开 shell，这条命令会一直占着终端，
所以放在 `tmux`/`screen` 里跑，或者相关的几条命令做完再关掉。

```
HOME$ ssh -N -L 127.0.0.1:8118:127.0.0.1:8888 CHANGEME@CHANGEME.vps.ip
```

装好 Docker 之后，要再加一条让**容器**也能用的绑定：容器里访问不到宿主机的回环，
只能用宿主机在 docker 网桥上的地址 `172.17.0.1`。这时把隧道写成两条 `-L`：

```
HOME$ ssh -N \
     -L 127.0.0.1:8118:127.0.0.1:8888 \
     -L 172.17.0.1:8118:127.0.0.1:8888 \
     CHANGEME@CHANGEME.vps.ip
```

第二条要求 `172.17.0.1`（docker0）已经存在，即 Docker 已安装并启动过；否则 ssh 会报
`bind: Cannot assign requested address`，这时先跑 I2.2。

**验收**：在另一个终端里

```
HOME$ curl -x http://127.0.0.1:8118 -sI https://github.com | head -1
HOME$ curl -x http://172.17.0.1:8118 -sI https://github.com | head -1
```

两条都返回 `HTTP/2 200` 或 301 才算通。第二条报 `Connection refused` 就是隧道没绑上 172.17.0.1。

隧道本身没有 systemd 单元：它只在装机和升级时用，用完可以关。断线重连用 `autossh -M 0 -N ...`
（需要自己装 `autossh`），不要指望这条 ssh 一直活着。

### I2.2 安装 Docker 并给守护进程配代理

```
HOME$ export http_proxy=http://127.0.0.1:8118
HOME$ export https_proxy=$http_proxy
HOME$ curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
HOME$ sudo -E sh /tmp/get-docker.sh      # -E 让 sudo 保留代理环境变量，脚本要经代理下载镜像
HOME$ sudo systemctl enable --now docker
HOME$ docker version
```

`sudo -E` 在某些 sudoers 配置下会被拒绝（`sorry, you are not allowed to preserve the environment`）。
遇到就改用 root shell，并在里面重新 export 一次代理：

```
HOME$ sudo -i
HOME# export http_proxy=http://127.0.0.1:8118 https_proxy=http://127.0.0.1:8118
HOME# sh /tmp/get-docker.sh
HOME# exit
```

守护进程自己拉镜像（`docker pull`）不走你的 shell 环境变量，要单独配一个 drop-in：

```
HOME$ sudo mkdir -p /etc/systemd/system/docker.service.d
HOME$ sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<'EOF'
# 让 dockerd 经 SSH 隧道访问 Docker Hub / GHCR。
# 地址用 127.0.0.1：dockerd 跑在宿主机网络命名空间里，隧道的第一条 -L 就绑在回环上。
# 只有构建容器内部才需要 172.17.0.1。
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:8118"
Environment="HTTPS_PROXY=http://127.0.0.1:8118"
Environment="NO_PROXY=localhost,127.0.0.1,172.17.0.1"
EOF
HOME$ sudo systemctl daemon-reload
HOME$ sudo systemctl restart docker
```

**验收**：

```
HOME$ docker info | grep -i -A1 proxy
HOME$ docker pull hello-world && docker run --rm hello-world
```

`docker info` 里能看到 `HTTP Proxy: http://127.0.0.1:8118`；`docker pull` 不再卡在
`Waiting for another application to release...` 或超时。隧道断了这里会立刻报
`proxyconnect tcp: dial tcp 127.0.0.1:8118: connect: connection refused`——这就是要修隧道。

### I2.3 给 git 配代理

`git clone` 之类由你自己敲的命令会读到这份配置。**但容器里的克隆读不到**：
`infra/discourse/app.yml` 的 `after_code` 钩子（`git clone .../docker_manager.git`，
以后的 `discourse-gtmc`）在构建容器内部以 root 执行，用的是容器自己的环境，
能否出网取决于 I2.5 的构建代理是否生效。

```
HOME$ git config --global http.proxy http://127.0.0.1:8118
HOME$ git config --global https.proxy http://127.0.0.1:8118
HOME$ git config --global --get-regexp '^http'      # 确认写进去了
```

**验收**：

```
HOME$ git ls-remote https://github.com/discourse/discourse_docker.git HEAD
```

能打印出一个 `HEAD` 的 SHA 即可。报 `Could not resolve proxy` / `Connection refused` 就是隧道没起。

代理只对 GitHub 之类的境外站点需要；从国内源拉东西时用
`git -c http.proxy= -c https.proxy= clone <国内地址>` 临时绕开。

### I2.4 安装 frpc

```
HOME$ FRP_VERSION=0.61.0      # 与 I1.2 用的版本保持一致
HOME$ cd /tmp
HOME$ curl -fLO https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz
HOME$ tar xzf frp_${FRP_VERSION}_linux_amd64.tar.gz
HOME$ sudo install -m 0755 frp_${FRP_VERSION}_linux_amd64/frpc /usr/bin/frpc
HOME$ /usr/bin/frpc --version
```

放入配置和单元文件，`auth.token` 与 VPS 上 `frps.toml` 保持一致：

```
HOME$ sudo mkdir -p /etc/frp
HOME$ sudo install -m 0640 /path/to/repo/infra/frp/frpc.toml /etc/frp/frpc.toml
HOME$ sudoedit /etc/frp/frpc.toml        # 填 serverAddr、auth.token
HOME$ sudo install -m 0644 /path/to/repo/infra/systemd/frpc.service /etc/systemd/system/frpc.service
HOME$ sudo systemctl daemon-reload
HOME$ sudo systemctl enable --now frpc
HOME$ systemctl status frpc --no-pager
HOME$ journalctl -u frpc -n 30 --no-pager
```

**验收**：

```
HOME$ journalctl -u frpc -n 30 --no-pager | grep -i 'login to server success'
```

以及回到 VPS 上看隧道端口已经出现：

```
VPS$ ss -lntp | grep 8880
LISTEN 0  128  127.0.0.1:8880  0.0.0.0:*  users:(("frps",pid=...,fd=...))
```

这时 Discourse 还没起，`VPS$ curl -sI http://127.0.0.1:8880` 会报连接被拒或 502，属正常。
如果 frpc 日志里是 `authorization failed`，就是两份配置的 token 不一致。

未验证：`transport.tls.enable = true` 在没配 `trustedCaFile` 时是否跳过对 frps 证书的校验，要按所选 frp 版本的文档确认。
不跳过而报证书错误时，frps 配 `certFile`/`keyFile`，frpc 补 `transport.tls.trustedCaFile` 和 `transport.tls.serverName`。

### I2.5 克隆 discourse_docker 并 rebuild

按官方方式装在 `/var/discourse`：

```
HOME$ sudo mkdir -p /var/discourse
HOME$ sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
HOME$ cd /var/discourse && sudo git log --oneline -1
```

`sudo git clone` 用的是 root 的 git 配置，**没有** I2.3 里给普通用户配的代理。
用 `sudo git -c` 把代理直接写在命令行上，不依赖任何配置文件：

```
HOME$ sudo git -c http.proxy=http://127.0.0.1:8118 \
        -c https.proxy=http://127.0.0.1:8118 \
        clone https://github.com/discourse/discourse_docker.git /var/discourse
```

放入容器配置并填占位符：

```
HOME$ sudo install -m 0644 /path/to/repo/infra/discourse/app.yml /var/discourse/containers/app.yml
HOME$ sudoedit /var/discourse/containers/app.yml
```

必须改的项（都在 `env:` 段，`CHANGEME` 一个都不许留）：

| 键 | 填什么 |
|---|---|
| `DISCOURSE_HOSTNAME` | `CHANGEME.forum.domain` 换成真实域名，与 Caddyfile 完全一致 |
| `DISCOURSE_DEVELOPER_EMAILS` | 负责人自己的 `@gtiit.edu.cn` 邮箱，用它注册即为管理员 |
| `DISCOURSE_SMTP_ADDRESS` / `_PORT` / `_USER_NAME` / `_PASSWORD` | H1 拿到的 SMTP 凭据 |
| `DISCOURSE_NOTIFICATION_EMAIL` | 发件地址，需与 SMTP 服务商验证过的域名一致 |

SMTP 密码只写在这台机器的这个文件里，不要提交回仓库：

```
HOME$ sudo grep -n CHANGEME /var/discourse/containers/app.yml    # 应当没有输出
HOME$ sudo chmod 600 /var/discourse/containers/app.yml
```

开始重建。构建容器（apt、gem、镜像）都要出网，所以先把代理变量导进这个 shell：

```
HOME$ export http_proxy=http://172.17.0.1:8118
HOME$ export https_proxy=$http_proxy
HOME$ export no_proxy=localhost,127.0.0.1
HOME$ cd /var/discourse
HOME$ sudo -E ./launcher rebuild app 2>&1 | tee /tmp/rebuild-$(date +%F).log
```

用 `172.17.0.1` 而不是 `127.0.0.1`：这些变量最终要在构建容器内部生效，容器里没有宿主机的回环。
`sudo -E` 被拒绝时同样改成 `sudo -i`、在 root shell 里 export 这三个变量再 `./launcher rebuild app`。
`tee` 留一份日志，出了问题按行号查。

**排查**：卡在下载步骤时，先确认代理变量真的进了构建过程——

```
HOME$ sudo docker exec app env | grep -i proxy
HOME$ sudo journalctl -u docker -n 50 --no-pager
```

未验证：`./launcher rebuild` 会不会把 shell 里的 `http_proxy`/`https_proxy`/`no_proxy` 转成 `--build-arg`，
没核对当前 discourse_docker 的 launcher 源码。容器里没有 `http_proxy` 就是没转。
这时 apt 层仍可经 `docker.service.d/http-proxy.conf` 里配的 daemon 代理出去；
gem 层不要用 `templates/web.china.template.yml`（见 I2.0 的坑），改为在 `before_web` 钩子里显式把 `bundle config`
指向一个实测可用的 rubygems 镜像；构建就能继续，但浏览器里访问 GitHub 之类的地址仍要走 I2.1 的隧道。

未验证：运行中的容器能否连上 github.com。主题从 Git 安装（PLAN 第 2 节），`import_theme.rb` 让容器里的核心在运行时
`git clone` 主题仓库，这和重建时的 `--build-arg` 代理不是一条路。I2.0 的直连阶段 github.com 是通的；
走 VPS 代理时用 `docker exec app git ls-remote https://github.com/GTIIT-MC-Club/gtmc-forum-theme.git` 确认。
不通时 `import_theme.rb` 报错退出、主题保持原样，后台「外观 → 主题」的「检查更新」同样会失败。

### I2 验收

**1）重建全程无错**

```
HOME$ sudo tail -30 /tmp/rebuild-$(date +%F).log
HOME$ sudo docker ps --filter name=app --format '{{.Names}} {{.Status}}'
```

`launcher rebuild` 最后一行是 `... app ...` 的启动信息，没有 `Error`/`failed`；
`docker ps` 里 `app` 是 `Up`。

**2）浏览器打开 `https://CHANGEME.forum.domain` 看到 Discourse**

```
laptop$ curl -sI https://CHANGEME.forum.domain | head -3
```

第一行 `HTTP/2 200`，且 `openssl s_client` 的证书仍然是有效的（I1.3 的验收命令）。
浏览器里能看到论坛首页，控制台没有混合内容告警。

**3）机器重启后 frpc 和论坛都自动恢复**

```
HOME$ sudo reboot
# 等机器起来（约 1~2 分钟），然后
HOME$ systemctl is-enabled frpc
enabled
HOME$ systemctl is-active frpc
active
HOME$ sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' app
always
HOME$ sudo docker ps --filter name=app --format '{{.Status}}'
Up ...
laptop$ curl -sI https://CHANGEME.forum.domain | head -1
HTTP/2 200
```

注意：重启**不会**自动恢复 SSH 隧道（I2.1 说明它没有 systemd 单元），
所以重启后 `docker pull` / `git clone` 需要重新开隧道；论坛本身的运行不依赖隧道，不受影响。

未验证：`RestartPolicy.Name` 是否为 `always`。discourse_docker 的 launcher 通常带 `--restart=always`，没在当前版本核对。

**4）真实 IP 与站点设置** 属于 I3，见下。

---

## I3 上线前验证

尚未开始，要做的事见 `PLAN.md` 第 5 节 I3。
