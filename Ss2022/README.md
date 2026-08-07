# Ss2022

Ss2022 是一个基于 [sing-box](https://sing-box.sagernet.org/) 的 Shadowsocks 2022 服务器管理工具。它把多个 Shadowsocks 节点放在一个 sing-box 进程中，由 `rem` 统一管理节点、密钥、端口、流量、配额、限速、备份、恢复和更新。

## 支持范围

- Debian 11、Debian 12
- Ubuntu
- CentOS
- AlmaLinux
- Alpine Linux（OpenRC）
- amd64/x86_64、arm64/aarch64
- TCP + UDP；每个节点一个端口
- Shadowsocks 2022：`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`

不支持的发行版或架构会在系统修改前明确退出。项目不会为了 BBR 升级内核。

## 安装

公开仓库可直接以 root 身份执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Rem-nm/Codex/codex/ss2022-manager/Ss2022/bootstrap.sh)"
```

最小化 Alpine 默认没有 Bash/curl 时，可使用 BusyBox 自带的 wget 启动：

```bash
sh -c "$(wget -qO- https://raw.githubusercontent.com/Rem-nm/Codex/codex/ss2022-manager/Ss2022/bootstrap.sh)"
```

也可以下载完整项目后，在项目目录中执行：

```bash
bash install.sh
```

安装过程会自动识别发行版以及 apt/yum/dnf/apk，安装必要依赖，使用 SagerNet 官方 GitHub Release 下载 sing-box，在 Debian/Ubuntu/CentOS/AlmaLinux 上创建 systemd 服务、在 Alpine 上创建 OpenRC 服务，配置 BBR/TCP Fast Open 能力，并安装 `/usr/local/bin/rem`。

首次安装完成后不会询问“是否创建节点”，而是直接进入第一个节点创建流程。创建完成后，任意目录执行：

```bash
rem
```

即可进入管理菜单。重复运行 `install.sh` 是幂等的：已有节点、密码、流量和备份不会被覆盖或重置。

## 节点和密钥

每个节点拥有独立的永久 Node ID、名称、端口、地址、加密方式和密钥。节点 tag 使用 `ss-<node-id>`，名称或端口变化不会改变 Node ID，也不会丢失历史数据。

名称重复时使用当前最小可用后缀，例如 `Tokyo`、`Tokyo-3` 已存在时，新名称为 `Tokyo-2`。端口会同时检查 TCP、UDP、系统占用和已有节点冲突；发现冲突不会覆盖。

2022 密钥由 `sing-box generate rand --base64` 或等价的 OpenSSL CSPRNG 生成，AES-128 使用 16 字节，AES-256 使用 32 字节。不会接受空密码、固定默认密码、时间戳密码或人工弱密码。修改密钥时可以重新生成，也可以复制另一个使用相同加密方式的节点密钥；新建节点仍默认各自生成独立随机密钥。

节点创建完成或用户主动查看节点链接时，菜单会显示：

1. SIP002 Shadowsocks URI
2. SIP002 URI 的 Base64 节点信息
3. 终端二维码

密钥和二维码只在创建结果、节点详细信息或“显示链接/二维码”这些明确操作中显示，不写入访问日志。

## 配置与服务管理

所有启用节点都在一个 `/etc/sing-box/config.json` 中作为 Shadowsocks inbound，由一个 sing-box 服务进程统一管理。systemd 系统使用 `sing-box.service`，Alpine 使用 OpenRC `sing-box`；两者都只运行一个 sing-box 进程。节点停用时从生成配置移除 inbound，不会停止其他节点。

如果用户在“Sing-box 管理”中手动停止整个服务，后续定时流量结算和配置事务会保留停止状态，不会擅自重新启动；再次选择“启动”后才恢复服务并执行完整端口健康检查。

配置采用官方 Shadowsocks inbound 结构；TCP 和 UDP 同时启用时省略 `network` 字段，因为 sing-box 官方文档规定空值表示两者。TCP Fast Open 只有在内核和当前 sing-box 构建都通过检测时才写入配置。

每次添加、删除、修改、启停、限额或限速变更都遵循：

```text
候选状态 → 生成候选 JSON → sing-box check → 备份 → 切换并快速 restart
→ 服务/进程/配置/端口/tc 健康检查 → 成功后提交数据库
```

检查失败时不重启或不提交；切换后健康检查失败时自动恢复上一版本，并提示“本次操作失败，已自动恢复上一版本配置”。默认保留最近 10 次配置变更备份；“备份与恢复”菜单也可在采样最新流量后立即创建手动快照。

当前 sing-box 官方能力没有可依赖的通用热 reload 命令，因此项目通过当前系统的服务管理器执行短暂、可回滚的快速 restart。

## 数据目录

程序和运行数据分离：

```text
/opt/ss-manager/
├── ss-manager.sh
├── lib/
├── config/
├── systemd/
└── openrc/

/etc/ss-manager/
├── manager.json
└── backups/

/var/lib/ss-manager/
├── nodes.json
├── traffic.json
├── traffic-history.json
├── tc-counters.json
├── interfaces.json
└── bandwidth-plan.json

/etc/sing-box/config.json
/run/ss-manager/
/usr/local/bin/rem
```

包含密钥的 manager 状态、节点数据库、流量数据和 sing-box 配置使用 root 所有、目录 700、文件 600 的权限。GitHub 目录只保存源代码、默认配置、版本、文档和测试，不保存服务器密码、真实地址、域名、流量文件或备份。

## 流量统计、重置和限额

项目不开发连接日志、目标网站日志、DNS 查询日志、来源 IP 历史或访问监控。流量统计使用 Linux `tc` 专用过滤器的字节计数：

- 上传：客户端 → Shadowsocks 服务器，按 ingress 的节点目标端口计数
- 下载：Internet → 服务器 → 客户端，按 egress 的节点源端口计数

这样不会把 Linux ingress/egress 直接当作客户端方向。统计每分钟由 systemd timer 或 OpenRC 监督的维护循环采样并持久化，sing-box 重启、服务器重启和 manager 更新不会清空累计值。服务器重启后，采样器会先验证并重建已消失的内核 `tc` 计数/限速规则，再重置内核计数基线，避免把计数归零误判为新增流量。统计是网络接口字节计数，包含链路/传输层开销；接口来自 IPv4/IPv6 默认路由。如果服务器有复杂多出口路由，请在“系统设置”中确认检测到的接口。

每个节点可设置独立月流量限额，0 表示不限；限额按本周期上传+下载判断，达到后状态为 `disabled_quota`，保留配置和数据。每个节点的重置日为 1-28，timer 使用 `last_reset_at`/`next_reset_at` 补执行，错过关机时间不会永久漏结算。`disabled_quota` 在新周期自动恢复，`disabled_manual` 和 `disabled_error` 不会被自动恢复。累计流量永久保留，结算历史默认保留最近 12 个周期。

## 节点限速

限速在 Linux `tc` 层按节点端口实现：上传匹配 ingress 目标端口，下载匹配 egress 源端口；分别支持 Mbps，0 表示不限速。项目只使用自己的 tc 优先级，保留其他优先级的规则；配置失败会重新应用旧节点的规则。

本项目绝不会主动修改或放行：

- iptables
- nftables
- UFW
- firewalld
- ipset
- 云厂商安全组

创建节点后，如果端口不可达，请自行检查服务器防火墙、云安全组和上游网络策略。

## 更新

菜单中的“更新管理”分别管理 manager 和 sing-box 版本：

- sing-box 只从 `SagerNet/sing-box` 官方 GitHub Release 获取
- manager 只接受 `Rem-nm/Codex` 官方 Release 资产
- 下载必须经过 HTTPS、官方地址检查和 SHA256 校验
- 下载到临时文件，校验并检查配置后才替换
- 新版本启动/健康检查失败自动恢复旧二进制和配置
- 两者版本独立显示；可锁定或解除 sing-box 版本

没有可验证的 manager Release 资产时，更新操作会提示不可更新，不会执行远程脚本。

## 卸载

菜单提供三种模式：

1. 仅删除程序，保留节点、流量、历史、配置和备份
2. 删除程序和运行配置，保留备份
3. 完全卸载项目创建的程序、systemd/OpenRC 服务、sing-box（由本项目管理时）、rem、节点数据、流量、历史和备份

所有模式都会删除本项目自己的 tc 规则；不会删除任何用户已有的防火墙规则。模式 1 会保留运行中的 sing-box 和配置，便于以后重新安装 manager 继续管理。

## 安全注意事项

- 不要把 `/etc/ss-manager`、`/var/lib/ss-manager`、`/etc/sing-box/config.json` 或备份上传到 GitHub。
- 不要在普通聊天、工单或日志中粘贴完整密钥、URI 或二维码。
- 项目不会自动开放防火墙；请按云厂商和服务器策略手动放行每个节点的 TCP/UDP 端口。
- sing-box 访问日志保持关闭；systemd/journald 或 OpenRC 仅用于必要的服务状态排障，不开发访问监控。

## 官方能力依据

- [sing-box Shadowsocks inbound](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)
- [sing-box Shadowsocks protocol guide](https://sing-box.sagernet.org/manual/proxy-protocol/shadowsocks/)
- [sing-box Listen Fields / TCP Fast Open](https://sing-box.sagernet.org/configuration/shared/listen/)
- [sing-box configuration check](https://sing-box.sagernet.org/configuration/)
- [sing-box package manager and service management](https://sing-box.sagernet.org/installation/package-manager/)
- [SagerNet/sing-box Releases](https://github.com/SagerNet/sing-box/releases)
