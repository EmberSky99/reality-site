# REALITY 本机 HTTPS 网站一键部署

为 VLESS＋REALITY 搭建本机 HTTPS 目标网站。中文交互、网页内置，证书由 Caddy 自动申请和续期。节点协议和入站通过 3X-UI 配置。

## 下载并运行

在 VPS 的 **root 终端**执行，需要已安装 `curl`：

```bash
curl -fL https://raw.githubusercontent.com/tinkerlab-tech/reality-site/main/reality-site.sh -o /root/reality-site.sh && bash /root/reality-site.sh
```

更新或修复本脚本部署的同一站点，也执行上面这条命令。脚本自动完成必要检查，通过后直接询问域名、本机网站端口和可选邮箱；核对计划后输入 `DEPLOY`。

## 准备与演示顺序

1. 准备 VPS，将域名的 A/AAAA 解析到这台 VPS，关闭 CDN 代理。
2. 安装 3X-UI 并确认能登录；已有面板可以继续使用。
3. 运行本脚本，等待本机 HTTPS 验证成功。
4. 在 3X-UI 配置 VLESS＋REALITY＋Vision，使用脚本输出的 SNI、Target/Dest 和 Xver。
5. 验证公网 `https://你的域名/`，再验证真实客户端代理连接。

只有本机 HTTPS 验证成功时，公网 443 的 REALITY 回落和代理出站仍需分别验证。

## 端口与证书

| 端口 | 用途 |
| --- | --- |
| 公网 TCP 80 | HTTP-01 证书验证时临时使用，完成后释放；申请和续期时均需可达、可用 |
| 公网 TCP 443 | 留给 Xray；在面板配置入站 |
| 本机 127.0.0.1:8443 | HTTPS 网站；首次占用时推荐其他本机端口，最终以输出的 Target 为准 |
| 本机 2019 | Caddy 管理接口 |

网站只提供 HTTPS，不提供常驻 HTTP 网页或自动跳转。浏览器明确输入 `https://`；需要先配置好公网 443 的 Xray 入站。

只使用 Caddy＋HTTP-01，无 DNS API、acme.sh 或额外续期定时任务。脚本保留 SSH、防火墙、3X-UI 和 Xray 原配置。

## 已安装 Caddy 或端口被占用

- **由本脚本部署、配置未被人工修改**：识别部署记录后复用安装、端口、网页和证书缓存，备份配置后更新并重载。
- **其他来源安装的 Caddy**：安装前说明原因并退出，保留现有网站，需要人工合并配置。
- **本脚本的 Caddyfile 被人工修改**：停止，先人工合并修改。
- **80 被其他服务占用**：显示占用进程并退出，人工协调后再运行。
- **旧部署使用其他证书验证方式**：保留原配置和续期任务，先人工迁移。

## 系统适配

Ubuntu 22.04/24.04/26.04、Debian 12/13、CentOS Stream 9/10、AlmaLinux/Rocky/RHEL 8/9/10；架构 x86_64 或 aarch64。要求 systemd、root，未适配系统直接退出。

## 排查

查看 Caddy 日志：

```bash
journalctl -u caddy -n 60 --no-pager
```

检查是否有常驻 80 监听：

```bash
ss -lntp 'sport = :80'
```

没有证书验证任务或其他 HTTP 服务时，80 应只显示表头。证书问题先检查域名全部 A/AAAA、公网 80 可达性和 CAA；Caddy 会自动重试，无须反复安装或强制重签。

## 验证范围

本地已通过 Bash/ShellCheck、系统版本分类、端口冲突、预装 Caddy 退出、重复运行、配置失败恢复，以及真实 Caddy 的 TLS 1.3、HTTP/2 和网页 200。使用本地 CA 的升级测试已验证 HTTP 端口释放及原证书复用。

旧版曾在 Debian 13/amd64 完成真实安装、HTTP-01 正式签发和本机 HTTPS 验证。本精简版的真实 VPS 升级与后续自动续期待进一步验证；各发行版的完整安装与 SELinux 尚未逐一实机验证。

参考：[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)、[关闭自动跳转](https://caddyserver.com/docs/caddyfile/options#auto-https)。
