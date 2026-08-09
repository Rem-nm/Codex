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

不支持的发行版或架构会在系统修改前明确退出。安装还会在临时 dummy 接口上探测 `clsact`、flower、当前启用地址族的 TCP/UDP、共享 gact/police action、cookie、action `bind` 计数和实际 `tc -j` 规则语义；IPv4-only 主机不会被强制要求 IPv6 filter，所需能力不完整时不会进入项目安装。项目不会为了 BBR 升级内核。

## 安装

root 安装入口必须同时固定完整 Git commit 和该 commit 的 GitHub 归档 SHA256；不接受分支名。下面的值会在每次正式发布时固定更新：

```bash
SS_MANAGER_COMMIT='PINNED_COMMIT_TO_BE_FILLED'
SS_MANAGER_ARCHIVE_SHA256='PINNED_ARCHIVE_SHA256_TO_BE_FILLED'
curl -fsSL "https://raw.githubusercontent.com/Rem-nm/Codex/$SS_MANAGER_COMMIT/Ss2022/bootstrap.sh" \
  | sudo SS_MANAGER_COMMIT="$SS_MANAGER_COMMIT" SS_MANAGER_ARCHIVE_SHA256="$SS_MANAGER_ARCHIVE_SHA256" sh
```

最小化 Alpine 默认没有 Bash/curl 时，可使用 BusyBox 自带的 wget 启动：

```bash
SS_MANAGER_COMMIT='PINNED_COMMIT_TO_BE_FILLED'
SS_MANAGER_ARCHIVE_SHA256='PINNED_ARCHIVE_SHA256_TO_BE_FILLED'
wget -qO- "https://raw.githubusercontent.com/Rem-nm/Codex/$SS_MANAGER_COMMIT/Ss2022/bootstrap.sh" \
  | SS_MANAGER_COMMIT="$SS_MANAGER_COMMIT" SS_MANAGER_ARCHIVE_SHA256="$SS_MANAGER_ARCHIVE_SHA256" sh
```

也可以下载完整项目后，在项目目录中执行：

```bash
bash install.sh
```

安装过程会自动识别发行版以及 apt/yum/dnf/apk，安装必要依赖，使用 SagerNet 官方 GitHub Release 下载 sing-box，在 Debian/Ubuntu/CentOS/AlmaLinux 上创建 systemd 服务、在 Alpine 上创建 OpenRC 服务，配置 BBR/TCP Fast Open 能力，并安装 `/usr/local/bin/rem`。依赖包会先由系统包管理器补齐且失败时不会反向卸载；随后安装/修复会保存持久恢复日志，任一步失败会一起恢复旧程序、状态文件、服务定义、sing-box、`rem`、sysctl 文件和实时内核值。

首次安装完成后不会询问“是否创建节点”，而是直接进入第一个节点创建流程。创建完成后，任意目录执行：

```bash
rem
```

即可进入管理菜单。重复运行 `install.sh` 是幂等的：已有节点、密码、流量和备份不会被覆盖或重置。

## 节点和密钥

每个节点拥有独立的永久 Node ID、名称、端口、地址、加密方式和密钥。通常节点 tag 使用 `ss-<node-id>`；仅在 `bindv6only=1` 的域名双 inbound 情况追加 `-ipv4`/`-ipv6`。名称或端口变化不会改变 Node ID，也不会丢失历史数据。

名称重复时使用当前最小可用后缀，例如 `Tokyo`、`Tokyo-3` 已存在时，新名称为 `Tokyo-2`；64 字符名称会先为后缀预留空间。端口只检查 TCP/UDP 监听套接字和已有节点冲突，不会把普通出站连接误判为占用；任一 `ss` 查询失败都会停止选择。保留原端口时也必须确认 TCP/UDP 监听都属于唯一的 sing-box PID，发现其他进程占用不会覆盖。

2022 密钥由 `sing-box generate rand --base64` 或等价的 OpenSSL CSPRNG 生成，AES-128 使用 16 字节，AES-256 使用 32 字节。不会接受空密码、固定默认密码、时间戳密码或人工弱密码。修改密钥时可以重新生成，也可以复制另一个使用相同加密方式的节点密钥；新建节点仍默认各自生成独立随机密钥。

节点创建完成或用户主动查看节点链接时，菜单会显示：

1. SIP002 Shadowsocks URI
2. SIP002 URI 的 Base64 节点信息
3. 终端二维码

密钥和二维码只在创建结果、节点详细信息或“显示链接/二维码”这些明确操作中显示，不写入访问日志。生成配置、URI 和二维码时，密钥通过受保护文件或标准输入传递，不放进外部命令的参数列表。

## 配置与服务管理

所有启用节点都在一个 `/etc/sing-box/config.json` 中作为 Shadowsocks inbound，由一个 sing-box 服务进程统一管理。systemd 系统使用 `sing-box.service`，Alpine 使用 OpenRC `sing-box`；两者都只运行一个 sing-box 进程。节点停用时从生成配置移除 inbound，不会停止其他节点。`bindv6only=1` 且分享地址为域名时，同一节点会生成 IPv4/IPv6 两个同端口 inbound（tag 带家庭后缀），避免域名解析到另一地址族后无法连接。

如果用户在“Sing-box 管理”中手动停止整个服务，后续定时流量结算和配置事务会保留停止状态，不会擅自重新启动；再次选择“启动”后才恢复服务并执行完整端口健康检查。

配置采用官方 Shadowsocks inbound 结构；TCP 和 UDP 同时启用时省略 `network` 字段，因为 sing-box 官方文档规定空值表示两者。TCP Fast Open 只有在内核和当前 sing-box 构建都通过检测时才写入配置。

每次添加、删除、修改、启停、限额或限速变更都遵循：

```text
候选状态 → 生成候选 JSON → sing-box check → 备份 → 切换并快速 restart
→ 服务/进程/配置/端口/tc 健康检查 → 成功后提交数据库
```

检查失败时不重启或不提交；切换前会在 `/etc/ss-manager/state-transaction/` 同步保存旧状态和阶段日志。普通失败立即回滚，SIGKILL、断电或崩溃会在下次 `rem`/维护启动时先恢复，再接受新操作。备份先写入隐藏准备目录，完整校验并同步后才以目录重命名发布；默认只清理最近 10 次之外、可证明属于本项目且语义完整的快照，`backups/` 下其他目录不会被删除。“备份与恢复”菜单也可在采样最新流量后立即创建手动快照。

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
├── backups/
├── state-transaction/   # 仅未完成状态事务存在
└── install-transaction/ # 仅未完成安装事务存在

/var/lib/ss-manager/
├── nodes.json
├── traffic.json
├── traffic-history.json
├── interfaces.json
└── bandwidth-plan.json

/etc/sing-box/config.json
/run/ss-manager/
/usr/local/bin/rem
```

manager 状态、包含密钥的节点数据库、流量数据和 sing-box 配置使用 root 所有、目录 700、敏感文件 600 的权限。manager 还保存项目管理的 sing-box 二进制 SHA-256；旧状态首次由本版本启动时会在版本匹配后补齐摘要，此后启动、修复和卸载都会同时核对版本与摘要，避免把同版本的外部替换文件当作项目二进制。GitHub 目录只保存源代码、默认配置、版本、文档和测试，不保存服务器密码、真实地址、域名、流量文件或备份。

## 流量统计、重置和限额

项目不开发连接日志、目标网站日志、DNS 查询日志、来源 IP 历史或访问监控。流量统计使用 Linux `tc` 专用过滤器的字节计数：

- 上传：客户端 → Shadowsocks 服务器，按 ingress 的节点目标端口计数
- 下载：Internet → 服务器 → 客户端，按 egress 的节点源端口计数

这样不会把 Linux ingress/egress 直接当作客户端方向。统计每分钟由 systemd timer 或 OpenRC 监督的维护循环采样并持久化，sing-box 重启、服务器重启和 manager 更新不会清空累计值。累计值与对应的内核计数基线在同一个 `traffic.json` 中一次提交；任一接口/action 读取失败时，两者都不会写入。同一启动周期内若 filter 损坏，会先采样仍完整的共享 action，再重建规则；服务器重启才直接重置内核基线。统计是端口层网络接口字节计数，包含链路/传输层开销；上传也包含到达该公开端口但未通过 Shadowsocks 认证的流量。

每个节点可设置独立月流量限额，0 表示不限；默认只按下载（服务端发往客户端的 egress）判断配额，上传仍照常展示和归档。这会降低未认证 ingress 洪泛直接耗尽配额的风险，但端口层 egress 仍可能包含 TCP 握手回复等未认证响应，不能作为认证用户的精确账单或抗流量攻击边界。达到后状态为 `disabled_quota`，保留配置和数据。取消/提高限额会在低于新限额时立即恢复，降低到已用计费量以下会立即停用。配额与单项持久计数上限为 JSON 可精确表示的 `9007199254740991` 字节。每个节点的重置日为 1-28，维护逻辑使用 `last_reset_at`/`next_reset_at` 在启动后补齐错过周期；`disabled_quota` 在新周期自动恢复，其他停用状态不会自动恢复。

## 节点限速

限速在 Linux `tc` 层按节点端口实现：上传匹配 ingress 目标端口，下载匹配 egress 源端口；分别支持 Mbps，0 表示不限速。tc 地址族以主路由表实际存在的 IPv4/IPv6 默认出口为准：IPv4-only 不创建 IPv6 规则，IPv6-only 也不强制 IPv4 规则。每个节点、每个方向只使用一个带所有权 cookie 的共享 action，因此已启用地址族、TCP/UDP 和多个默认路由接口共同计入同一个限速桶，不会把设定速率按过滤器倍增。主路由表默认出口在同一次启动期间变化时，下一次维护会先保存仍可读的旧 action 计数，再用持久事务刷新接口、规则和计数基线；默认路由查询失败则不改规则。项目只按已保存的 action 身份、完整 `bind` 数和精确 filter handle 清理自己的规则；同一优先级里的外部规则会保留。无法证明所有权、`tc -j` 查询失败、JSON 异常、重复或混合 action 时会保留整个 clsact，而不是把查询错误当作空规则。非主路由表的策略路由不在自动发现范围内，部署前应单独核对。

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
- manager 更新会建立持久事务，规范化新程序权限，同步 systemd/OpenRC 定义、`rem` 和版本状态，并立即切换到新版本菜单；普通失败、崩溃或断电都会恢复旧程序、服务和状态
- 两者版本独立显示；可锁定或解除 sing-box 版本

没有可验证的 manager Release 资产时，更新操作会提示不可更新，不会执行远程脚本。

## 卸载

菜单提供三种模式：

1. 仅删除程序，保留节点、流量、历史、配置和备份
2. 删除程序和运行配置，保留备份
3. 完全卸载项目创建的程序、systemd/OpenRC 服务、sing-box（由本项目管理时）、rem、节点数据、流量、历史和备份

所有模式都会删除本项目自己的 tc 规则；不会删除任何用户已有的防火墙规则。模式 1 会保留运行中的 sing-box 和配置，便于以后重新安装 manager 继续管理。模式 2 和模式 3 会在删除 manager 状态前恢复本项目记录的 BBR/TFO 内核原值并清理运行目录。维护服务或 sing-box 无法确认停止/禁用时，卸载会在删除对应程序和配置前停止。

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
- [sing-box V2Ray API / stats（默认构建不保证包含）](https://sing-box.sagernet.org/configuration/experimental/v2ray-api/)
- [sing-box build tags](https://sing-box.sagernet.org/installation/build-from-source/)
- [sing-box package manager and service management](https://sing-box.sagernet.org/installation/package-manager/)
- [SagerNet/sing-box Releases](https://github.com/SagerNet/sing-box/releases)
