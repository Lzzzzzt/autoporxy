# Proxy Stack 一键部署

在一台 Linux VPS 上交互式部署以下三个入口：

- Hysteria 2：固定 UDP 端口，ACME 自动证书，应用层使用标准 BBR，出站 `mode: 46`（IPv4 优先、IPv6 回退）
- VLESS + REALITY + XTLS Vision：TCP 入口，Freedom 出站 `UseIPv4v6`
- Snell v5 + ShadowTLS v3：Snell 仅监听内部 IPv4，出站设置 `ipv6=false`，由 ShadowTLS 对外提供 TCP 入口

脚本会安装依赖与 Docker Compose、下载官方 Snell Server、生成全部凭据、切换 `BBR + fq`、配置已启用的 UFW/firewalld，并输出客户端配置。凭据和运行数据不会进入 Git。

当前锁定版本（2026-08-13 核对）：Hysteria `v2.12.0`、Xray-core `26.7.28`、ShadowTLS `v0.2.25`、Snell Server `v5.0.1`。

## 支持环境

- Debian / Ubuntu（`apt`）
- RHEL / CentOS / Rocky Linux / AlmaLinux / Fedora（`dnf`）
- CPU：x86_64 或 aarch64
- 需要 root/sudo、systemd、公网 IPv4，以及可直连 VPS 的域名 A 记录

建议使用较新的 Debian 12、Ubuntu 22.04/24.04 或 EL 9 系统。NAT VPS、OpenVZ 或容器内可能无法修改 BBR/sysctl。

## 部署前准备

1. 为 Hysteria 2 准备一个域名，例如 `hy2.example.com`。
2. 将域名的 **A 记录直接指向 VPS IPv4**。不要开启 CDN 代理。
3. 云厂商安全组至少放行：
   - `80/tcp`：Hysteria ACME HTTP-01 申请和续期证书
   - `443/tcp`：VLESS Reality 默认端口
   - `32123/udp`：Hysteria 2 默认端口
   - `32413/tcp`：Snell + ShadowTLS 默认端口
4. 确保 TCP 80 没有被 Nginx、Caddy 等服务占用。

## 一键部署

```bash
git clone <你的仓库地址> proxy-stack
cd proxy-stack
sudo ./install.sh
```

脚本会依次询问：

- 客户端连接地址
- Hysteria 2 域名与 Let's Encrypt 邮箱
- 三个对外端口
- Reality 与 ShadowTLS 的伪装/握手域名
- 是否启用 BBR + fq
- 二次运行时是否轮换全部凭据

安装完成后会打印配置，并保存到权限为 `0600` 的 `client-config.txt`。运行时密钥位于 `.env` 和 `data/`，均已由 `.gitignore` 排除。

## 日常管理

```bash
./manage.sh status
./manage.sh logs
./manage.sh logs hysteria
./manage.sh show
./manage.sh check
./manage.sh restart
./manage.sh stop
./manage.sh start
```

重新运行 `sudo ./install.sh` 可以修改参数。默认保留现有凭据；选择重新生成时会轮换全部客户端凭据。旧配置会备份到 `backups/<时间戳>/`。

## 版本更新

镜像版本锁在 `.env` 与 `.env.example` 中，避免 `latest` 带来的不可控升级。修改 `.env` 中的明确版本标签后运行：

```bash
./manage.sh update
```

`update` 只拉取 `.env` 指定的版本，不会自动改到未知的新版本。

## BBR 与协议行为

安装脚本写入 `/etc/sysctl.d/99-proxy-stack.conf` 和 `/etc/modules-load.d/proxy-stack.conf`，并验证 `net.ipv4.tcp_congestion_control=bbr` 与 `net.core.default_qdisc=fq` 是否生效。

BBR/fq 是主机 TCP 层优化，主要影响 VLESS Reality 和 Snell/ShadowTLS；Hysteria 2 基于 QUIC/UDP，不直接使用 Linux TCP BBR。Hysteria 自己的出站地址族策略仍设置为 IPv4 优先。

## 防火墙说明

脚本只会向**已经启用**的 UFW 或 firewalld 添加规则，不会自动启用一个新的防火墙，以免意外锁掉 SSH。云厂商安全组必须手动放行对应端口。

## 故障排查

```bash
./manage.sh status
docker compose logs --tail=200
./manage.sh check
```

常见问题：

- Hysteria 日志出现 ACME 失败：检查域名 A 记录、TCP 80、安全组和本机防火墙。
- Reality 无法连接：确认 TCP 端口放行，客户端 URI 中 `pbk`、`sid`、`sni` 未被改动。
- ShadowTLS 启动报 io_uring/memlock 错误：先查看日志；极小内存或受限虚拟化环境可能不支持所需能力。
- BBR 不可用：升级 VPS 内核，或确认服务商没有禁用拥塞控制模块。

## 上游项目

- [Hysteria 2](https://v2.hysteria.network/)
- [Xray-core / REALITY](https://xtls.github.io/)
- [Surge Snell](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)
- [ShadowTLS](https://github.com/ihciah/shadow-tls)
