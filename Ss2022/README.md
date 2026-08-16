# Ss2022

Ss2022 是一个基于 [sing-box](https://sing-box.sagernet.org/) 的统一代理节点管理工具。它把 Shadowsocks 2022、VLESS + REALITY + XTLS Vision、Hysteria2 与 TUIC v5 节点放在同一个 sing-box 进程中，由 `rem` 统一管理身份、端口、流量、配额、限速、证书、备份、恢复和更新。GitHub 目录继续保留 `Ss2022/`，终端界面使用 `REM Proxy Manager`。

## 支持范围

- Debian 11、Debian 12
- Ubuntu
- CentOS
- AlmaLinux
- Alpine Linux（OpenRC）
- amd64/x86_64、arm64/aarch64
- Shadowsocks 2022（TCP + UDP）：`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`
- VLESS（TCP）：仅 `REALITY + xtls-rprx-vision`
- Hysteria2（UDP）：每个节点独立密码和自签 ECDSA P-256 TLS 证书，客户端使用证书 DER SHA-256 pin
- TUIC v5（QUIC/UDP）：每个节点独立 UUID、Password 和自签 ECDSA P-256 TLS 证书；固定关闭 0-RTT，QUIC 拥塞控制为 BBR
- 每个节点一个全局唯一实际监听端口；四种协议之间也不允许实际端口重复。Hysteria2 可选地把一个连续 UDP 外部范围由 manager 自有 NAT REDIRECT 指向该实际端口

不支持的发行版或架构会在系统修改前明确退出。安装还会在临时 dummy 接口上探测 `clsact`、flower、当前启用地址族的 TCP/UDP、共享 gact/police action、cookie、action `bind` 计数和实际 `tc -j` 规则语义；IPv4-only 主机不会被强制要求 IPv6 filter，所需能力不完整时不会进入项目安装。启用 Hysteria2 端口跳跃时，manager 还会在自己的 NAT 命名空间中探测并核验连续 UDP 范围 REDIRECT；探测失败会保持关闭，不会改动用户规则。项目不会为了 BBR 升级内核。

## 安装

root 安装入口必须同时固定完整 Git commit 和该 commit 的 GitHub 归档 SHA256；不接受分支名。下面的值会在每次正式发布时固定更新：

```bash
SS_MANAGER_COMMIT='b5bdf2d982484c3b6cf78b9ffeff4c1bed71c5c9'
SS_MANAGER_ARCHIVE_SHA256='2a2c28083dc80cc2eef3cb12cf2d721b2aa554836f1a33805d16c42a0ec77373'
curl -fsSL "https://raw.githubusercontent.com/Rem-nm/Codex/$SS_MANAGER_COMMIT/Ss2022/bootstrap.sh" \
  | SS_MANAGER_COMMIT="$SS_MANAGER_COMMIT" SS_MANAGER_ARCHIVE_SHA256="$SS_MANAGER_ARCHIVE_SHA256" sh
```

最小化 Alpine 默认没有 Bash/curl 时，可使用 BusyBox 自带的 wget 启动：

```bash
SS_MANAGER_COMMIT='b5bdf2d982484c3b6cf78b9ffeff4c1bed71c5c9'
SS_MANAGER_ARCHIVE_SHA256='2a2c28083dc80cc2eef3cb12cf2d721b2aa554836f1a33805d16c42a0ec77373'
wget -qO- "https://raw.githubusercontent.com/Rem-nm/Codex/$SS_MANAGER_COMMIT/Ss2022/bootstrap.sh" \
  | SS_MANAGER_COMMIT="$SS_MANAGER_COMMIT" SS_MANAGER_ARCHIVE_SHA256="$SS_MANAGER_ARCHIVE_SHA256" sh
```

也可以下载完整项目后，在项目目录中执行：

```bash
bash install.sh
```

安装过程会自动识别发行版以及 apt/yum/dnf/apk，安装必要依赖，使用 SagerNet 官方 GitHub Release 下载 sing-box，在 Debian/Ubuntu/CentOS/AlmaLinux 上创建 systemd 服务、在 Alpine 上创建 OpenRC 服务，配置 BBR/TCP Fast Open 能力，并安装 `/usr/local/bin/rem`。依赖包会先由系统包管理器补齐且失败时不会反向卸载；重复修复时如果所需命令已经存在会跳过无必要的 APT 更新，避免旧 Debian 软件源阻断既有安装。Debian 11 若仍配置 `bullseye/updates` 或 `bullseye-backports`，依赖安装会临时使用官方 `bullseye`/`bullseye-security` 主源，不修改 `/etc/apt`；临时源也不可用时再提示升级系统或修复软件源。随后安装/修复会保存持久恢复日志，任一步失败会一起恢复旧程序、状态文件、服务定义、sing-box、`rem`、sysctl 文件和实时内核值。

首次安装完成后不会询问“是否创建节点”，而是直接进入第一个节点创建流程。节点名称仍是第一项输入，随后选择 Shadowsocks 2022、VLESS + REALITY + Vision、Hysteria2 或 TUIC。创建完成后，任意目录执行：

```bash
rem
```

即可进入管理菜单。重复运行 `install.sh` 是幂等的：已有节点、密码、UUID、Reality KeyPair、Short ID、HY2/TUIC 认证信息、证书、流量和备份不会被覆盖或重置；检测到既有 VLESS/HY2/TUIC 节点时，还会在安装事务提交前验证当前 sing-box、随机源和证书状态。

## 节点和凭据

每个节点拥有独立的永久 Node ID、名称、协议、端口、客户端地址和协议凭据。SS2022 tag 继续使用 `ss-<node-id>`，VLESS 使用 `vless-<node-id>`，Hysteria2 使用 `hy2-<node-id>`，TUIC 使用 `tuic-<node-id>`；仅在 `bindv6only=1` 的域名双 inbound 情况追加 `-ipv4`/`-ipv6`。名称、端口、地址或协议参数变化不会改变 Node ID，也不会丢失历史数据。第一版不提供协议之间的转换。

名称重复时使用当前最小可用后缀，例如 `Tokyo`、`Tokyo-3` 已存在时，新名称为 `Tokyo-2`；64 字符名称会先为后缀预留空间。端口会先检查统一节点数据库，再检查协议实际使用的系统监听：SS2022 检查 TCP/UDP，VLESS 检查 TCP，Hysteria2/TUIC 检查 UDP。任一 `ss` 查询失败都会停止选择。保留原端口时也必须确认所需监听都属于唯一的 sing-box PID，发现其他进程占用不会覆盖。

2022 密钥由 `sing-box generate rand --base64` 或等价的 OpenSSL CSPRNG 生成，AES-128 使用 16 字节，AES-256 使用 32 字节。不会接受空密码、固定默认密码、时间戳密码或人工弱密码。修改密钥时可以重新生成，也可以复制另一个使用相同加密方式的节点密钥；新建节点仍默认各自生成独立随机密钥。

每个 VLESS 节点独立生成 UUID、Reality X25519 KeyPair 和 Short ID，Flow 固定为 `xtls-rprx-vision`。Reality Private Key 只写入权限为 600 的节点数据库、备份和服务端配置，不显示在节点列表、普通详情、分享链接、Base64 或二维码中。重新生成 UUID、KeyPair 或 Short ID 前会明确提示现有客户端配置将失效。

每个 Hysteria2 节点独立生成密码和自签 ECDSA P-256 证书。证书固定保存在 `/etc/ss-manager/certs/<node-id>/`，目录权限 700、证书和私钥权限 600；客户端分享 URI 使用 TLS SNI、`insecure=1` 和叶子证书 DER SHA-256 的 `pinSHA256`，不显示或分享私钥。

每个 TUIC 节点独立生成 UUID、Password 和自签 ECDSA P-256 证书，证书路径同样由 Node ID 派生。服务端固定 `congestion_control=bbr`、`auth_timeout=3s`、`heartbeat=10s`、`zero_rtt_handshake=false`。通用 TUIC v5 URI 使用 `alpn=h3`、`udp_relay_mode=native` 和 `allow_insecure=1`；由于跨客户端通用 TUIC URI 没有可移植的证书 Pin 参数，项目会在凭据页单独显示并严格校验叶证书 DER SHA-256，绝不把 HY2 专属参数冒充为 TUIC 标准字段。

节点创建完成或用户主动查看节点链接时，菜单会按协议显示：

1. 对应协议的标准分享 URI
2. 标准 URI 的 Base64 节点信息
3. 终端二维码

Reality Private Key 永不出现在终端普通输出；VLESS UUID、Public Key 和 Short ID 可按需求显示在协议详情中。完整客户端链接、Base64 和二维码只在创建结果或“显示链接/二维码”这些明确操作中显示，不写入访问日志。生成配置、URI 和二维码时，秘密值通过受保护文件或标准输入传递，不放进外部命令的参数列表。

## 配置与服务管理

所有启用节点都在一个 `/etc/sing-box/config.json` 中按 `protocol` 生成 Shadowsocks、VLESS、Hysteria2 或 TUIC inbound，由一个 sing-box 服务进程统一管理。systemd 系统使用 `sing-box.service`，Alpine 使用 OpenRC `sing-box`；两者都只运行一个 sing-box 进程。节点停用时只从生成配置移除该 Node ID 的 inbound，不会停止其他协议或节点。`bindv6only=1` 且分享地址为域名时，同一节点会生成 IPv4/IPv6 两个同端口 inbound（tag 带家庭后缀），避免域名解析到另一地址族后无法连接。

如果用户在“Sing-box 管理”中手动停止整个服务，后续定时流量结算和配置事务会保留停止状态，不会擅自重新启动；再次选择“启动”后才恢复服务并执行完整端口健康检查。

SS2022 配置采用官方 Shadowsocks inbound 结构；TCP 和 UDP 同时启用时省略 `network` 字段，因为 sing-box 官方文档规定空值表示两者。VLESS 配置采用官方 VLESS inbound、TLS Reality server 和 `xtls-rprx-vision` 用户 Flow 结构。Hysteria2 与 TUIC 配置采用各自官方 UDP/QUIC inbound，服务端 TLS 只引用项目固定证书路径。不增加 WS、gRPC、普通 TLS、ACME 或其他传输。TCP Fast Open 只有在内核和当前 sing-box 构建都通过检测时才写入配置。

### Hysteria2 端口跳跃与订阅服务

Hysteria2 端口跳跃默认关闭。开启后 sing-box 仍只监听节点的一个实际 UDP 端口，manager 仅在自己的 nftables/iptables NAT 对象中维护用户声明的连续 UDP 范围，并同时维护对应的 tc 范围统计/限速规则；不会生成额外 inbound、进程或服务，也不会刷新用户的 filter policy。节点停用、删除、备份恢复、覆盖安装和重启都会执行同一个幂等 reconcile。请自行放行实际端口和外部跳跃范围，项目不管理云安全组或外部防火墙。

订阅服务是可选的单一 default subscription，默认关闭并只监听 `127.0.0.1:18080`。root 管理器从统一节点库生成不含 Reality Private Key、TLS Private Key 或证书私钥的派生快照，专用低权限账号只读取该快照。启用后提供 `/sub/<TOKEN>`（标准 Base64 URI Bundle）、`/raw`、`/base64` 和 `/sing-box` 四个只读 GET/HEAD 路由；停用或节点状态不是 `enabled` 的节点不会输出。Token 轮换立即使旧路径失效，派生内容生成失败时端点明确不可用而不提供陈旧敏感快照。订阅服务或端口跳跃服务故障都不停止 sing-box。

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
├── bandwidth-plan.json
├── port-hopping-plan.json
└── subscription/
    ├── subscription-export.json
    └── subscription-runtime.json

/etc/sing-box/config.json
/run/ss-manager/
/usr/local/bin/rem
```

manager 状态、包含密钥的节点数据库、流量数据和 sing-box 配置使用 root 所有、目录 700、敏感文件 600 的权限。manager 还保存项目管理的 sing-box 二进制 SHA-256；旧状态首次由本版本启动时会在版本匹配后补齐摘要，此后启动、修复和卸载都会同时核对版本与摘要，避免把同版本的外部替换文件当作项目二进制。GitHub 目录只保存源代码、默认配置、版本、文档和测试，不保存服务器密码、真实地址、域名、流量文件或备份。

## 流量统计、重置和限额

项目不开发连接日志、目标网站日志、DNS 查询日志、来源 IP 历史或访问监控。流量统计使用 Linux `tc` 专用过滤器的字节计数：

- 上传：客户端 → 代理服务器，按 ingress 的节点目标端口计数
- 下载：Internet → 服务器 → 客户端，按 egress 的节点源端口计数

这样不会把 Linux ingress/egress 直接当作客户端方向。统计每分钟由 systemd timer 或 OpenRC 监督的维护循环采样并持久化，sing-box 重启、服务器重启和 manager 更新不会清空累计值。累计值与对应的内核计数基线在同一个 `traffic.json` 中一次提交；任一接口/action 读取失败时，两者都不会写入。同一启动周期内若 filter 损坏，会先采样仍完整的共享 action，再重建规则；服务器重启才直接重置内核基线。统计是端口层网络接口字节计数，包含链路/传输层开销；上传也可能包含到达公开端口但未通过代理协议认证的流量。

每个节点可设置独立月流量限额，0 表示不限；默认只按下载（服务端发往客户端的 egress）判断配额，上传仍照常展示和归档。这会降低未认证 ingress 洪泛直接耗尽配额的风险，但端口层 egress 仍可能包含 TCP 握手回复等未认证响应，不能作为认证用户的精确账单或抗流量攻击边界。达到后状态为 `disabled_quota`，保留配置和数据。取消/提高限额会在低于新限额时立即恢复，降低到已用计费量以下会立即停用。配额与单项持久计数上限为 JSON 可精确表示的 `9007199254740991` 字节。每个节点的重置日为 1-28，维护逻辑使用 `last_reset_at`/`next_reset_at` 在启动后补齐错过周期；`disabled_quota` 在新周期自动恢复，其他停用状态不会自动恢复。

## 节点限速

限速在 Linux `tc` 层按节点端口实现：上传匹配 ingress 目标端口，下载匹配 egress 源端口；分别支持 Mbps，0 表示不限速。tc 地址族以主路由表实际存在的 IPv4/IPv6 默认出口为准：IPv4-only 不创建 IPv6 规则，IPv6-only 也不强制 IPv4 规则。每个节点、每个方向只使用一个带所有权 cookie 的共享 action；SS2022 的 TCP/UDP filter 或 VLESS 的 TCP filter、已启用地址族和多个默认路由接口都绑定到该节点方向的同一个限速桶，不会把设定速率按过滤器倍增。主路由表默认出口在同一次启动期间变化时，下一次维护会先保存仍可读的旧 action 计数，再用持久事务刷新接口、规则和计数基线；默认路由查询失败则不改规则。项目只按已保存的 action 身份、完整 `bind` 数和精确 filter handle 清理自己的规则；同一优先级里的外部规则会保留。无法证明所有权、`tc -j` 查询失败、JSON 异常、重复或混合 action 时会保留整个 clsact，而不是把查询错误当作空规则。非主路由表的策略路由不在自动发现范围内，部署前应单独核对。

本项目绝不会主动修改或放行用户的：

- UFW
- firewalld
- ipset
- 云厂商安全组

普通节点不会创建任何 NAT 规则。只有明确启用 Hysteria2 端口跳跃时，manager 才会在专属 nftables/iptables NAT table/chain 中创建带 Node ID 所有权标记的 UDP REDIRECT；不会 flush、改 policy、修改用户链或删除无法证明属于本项目的规则。创建节点或开启跳跃后，如果端口不可达，请自行检查服务器防火墙、云安全组和上游网络策略，并放行实际端口及跳跃范围。

## 更新

菜单中的“更新管理”分别管理 manager 和 sing-box 版本：

- sing-box 只从 `SagerNet/sing-box` 官方 GitHub Release 获取
- manager 只接受 `Rem-nm/Codex` 官方 Release 资产
- 下载必须经过 HTTPS、官方地址检查和 SHA256 校验
- 下载到临时文件，校验并检查配置后才替换
- 新版本启动/健康检查失败自动恢复旧二进制和配置
- manager 更新会建立持久事务；下载包在临时目录完成结构、语法和权限规范化后才切换。切换后的新程序先在 `/run/ss-manager/` 生成 schema 迁移与完整 sing-box 配置候选并执行兼容性预检，不提前修改永久数据；预检通过后才同步 systemd/OpenRC 定义、`rem` 和版本状态，并立即切换到新版本菜单。普通失败、崩溃或断电都会恢复旧程序、服务和状态
- 两者版本独立显示；可锁定或解除 sing-box 版本

没有可验证的 manager Release 资产时，更新操作会提示不可更新，不会执行远程脚本。

## 卸载

菜单提供三种模式：

1. 仅删除程序，保留节点、流量、历史、配置和备份
2. 删除程序和运行配置，保留备份
3. 完全卸载项目创建的程序、systemd/OpenRC 服务、sing-box（由本项目管理时）、rem、节点数据、流量、历史和备份

所有模式都会删除本项目自己的 tc 规则、端口跳跃 NAT 规则和订阅服务定义；不会删除任何用户已有的防火墙规则或反向代理配置。模式 1 会保留运行中的 sing-box 和配置，便于以后重新安装 manager 继续管理。模式 2 和模式 3 会在删除 manager 状态前恢复本项目记录的 BBR/TFO 内核原值并清理运行目录。维护服务或 sing-box 无法确认停止/禁用时，卸载会在删除对应程序和配置前停止。

## 安全注意事项

- 不要把 `/etc/ss-manager`、`/var/lib/ss-manager`、`/etc/sing-box/config.json` 或备份上传到 GitHub。
- 不要在普通聊天、工单或日志中粘贴完整密钥、URI 或二维码。
- 项目不会自动开放外部防火墙；请按云厂商和服务器策略手动放行 SS2022 的 TCP/UDP、VLESS 的 TCP、Hysteria2/TUIC 的 UDP 实际端口，以及已启用 Hysteria2 跳跃的外部 UDP 范围。
- sing-box 访问日志保持关闭；systemd/journald 或 OpenRC 仅用于必要的服务状态排障，不开发访问监控。

## 官方能力依据

- [sing-box Shadowsocks inbound](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/)
- [sing-box Shadowsocks protocol guide](https://sing-box.sagernet.org/manual/proxy-protocol/shadowsocks/)
- [sing-box VLESS inbound](https://sing-box.sagernet.org/configuration/inbound/vless/)
- [sing-box Hysteria2 inbound](https://sing-box.sagernet.org/configuration/inbound/hysteria2/)
- [sing-box TUIC inbound](https://sing-box.sagernet.org/configuration/inbound/tuic/)
- [sing-box TLS fields](https://sing-box.sagernet.org/configuration/shared/tls/)
- [sing-box TLS / Reality fields](https://sing-box.sagernet.org/configuration/shared/tls/#reality-fields)
- [sing-box Listen Fields / TCP Fast Open](https://sing-box.sagernet.org/configuration/shared/listen/)
- [sing-box configuration check](https://sing-box.sagernet.org/configuration/)
- [sing-box V2Ray API / stats（默认构建不保证包含）](https://sing-box.sagernet.org/configuration/experimental/v2ray-api/)
- [sing-box build tags](https://sing-box.sagernet.org/installation/build-from-source/)
- [sing-box package manager and service management](https://sing-box.sagernet.org/installation/package-manager/)
- [SagerNet/sing-box Releases](https://github.com/SagerNet/sing-box/releases)
