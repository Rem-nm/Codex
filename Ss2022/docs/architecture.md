# 架构说明

## 进程模型

Ss2022 不为节点创建进程。启用节点按 `protocol` 转换为同一 `config.json` 的 Shadowsocks 2022、VLESS + REALITY + Vision、Hysteria2 或 TUIC inbound，由一个 sing-box 服务负责启动、停止和重启；Debian/Ubuntu/CentOS/AlmaLinux 使用 systemd，Alpine Linux 使用 OpenRC。协议只是统一节点模型的一个判别字段，不存在按协议拆分的服务或数据库。

节点地址是客户端分享信息，监听地址由系统 IPv4/IPv6 能力单独决定。IPv6 可用且 `bindv6only=0` 时默认监听 `::`；IPv4-only 系统监听 `0.0.0.0`；`bindv6only=1` 时 IPv4/IPv6 地址按各自家庭监听，域名节点生成两个同端口 inbound，并使用 `-ipv4`/`-ipv6` tag 后缀。

## 数据边界

`nodes.json` schema 5 保存节点身份、协议、凭据、端口、地址、状态、订阅开关、限额和限速，是唯一节点源数据。公共字段只维护一份；SS2022 保存 method/password，VLESS 保存 UUID、固定 Flow、独立 Reality KeyPair、Short ID、SNI 和握手目标，Hysteria2 保存独立 password、TLS SNI、证书 pin 和可选连续端口跳跃范围，TUIC 保存独立 UUID/password、固定 QUIC 参数、TLS SNI 和证书 pin。HY2/TUIC 证书文件均由 Node ID 固定派生。`traffic.json` 仍按永久 Node ID 保存当前周期、累计计数及对应的 tc 内核计数基线，`traffic-history.json` 保存已结算周期。sing-box 配置由节点源数据生成，不反向作为数据库。

旧 schema 1 SS2022 数据先创建完整快照，再增加 `protocol: "shadowsocks"`、`subscription_enabled: true` 并升级到 schema 5；旧 schema 2/3/4 保留所有协议凭据，补齐订阅字段和 HY2 跳跃默认值。Node ID、名称、端口、密码、UUID、密钥、证书、流量、历史、限额、重置日、限速和状态都保持不变；候选文件验证失败或提交失败时恢复迁移前文件。迁移不会为旧节点生成或轮换证书。

`manager.json` 只保存 manager/sing-box 版本、能力探测、监听模式、更新锁和 `time_sync` 时间同步设置，不保存节点密钥。`time_sync` 记录系统 NTP Provider 与 sing-box NTP 开关、服务器和状态；系统 Provider 仍属于主机基础服务，不由 sing-box 服务依赖或按节点拆分。

## 时间同步路径

时间同步采用两层机制：主机已有或按发行版选择的一套系统 Provider（`chrony`、`systemd-timesyncd` 或 `unknown`）负责校准操作系统 Unix 时间；sing-box 配置生成器再从 `manager.json.time_sync` 生成顶层 `ntp` 模块作为协议层 fallback。Provider 检查失败只产生辅助警告，不会停止四协议共用的 sing-box 进程。安装、更新、系统设置和恢复都不得自动修改时区，也不得同时启用两个 NTP daemon。

`rem → 系统设置 → 时间同步` 只修改 manager 状态并复用现有配置事务：候选 manager → 完整 sing-box 配置 → 官方 `sing-box check` → restart/健康检查 → 提交。时间显示同时包含 Local Time、UTC、Timezone、Provider 和同步状态，避免把时区差异误判为 Unix 时间错误。

`port-hopping-plan.json` 是由 nodes 重建的 HY2 NAT/tc 派生计划；它只描述 manager 自有规则的后端、地址族、范围和所有权，不包含用户防火墙策略。订阅设置单独保存在 root-only 的 `/etc/ss-manager/subscription.json`；root 管理器将符合条件的节点转换成不含服务端私钥的 `subscription-export.json`，低权限 HTTP 服务只读该派生文件，不读取 `nodes.json` 或证书目录。订阅默认关闭，生成失败会发布不可用状态而不是陈旧快照。

## 流量路径

每个 SS2022 节点使用 TCP + UDP，每个 VLESS Reality Vision 节点使用 TCP，每个 Hysteria2/TUIC 节点使用 UDP。tc 过滤器在默认路由接口上按节点实际传输匹配：

```text
上传：ingress dst_port=node.port
下载：egress  src_port=node.port
```

每个节点、每个方向建立一个带确定性 index 和 128-bit 所有权 cookie 的共享 tc action；当前实际启用的地址族、协议所需传输（SS2022 为 TCP/UDP，VLESS 为 TCP，Hysteria2/TUIC 为 UDP）及多个默认路由接口的 flower filter 都绑定到该 action。IPv4-only 主机不会创建 IPv6 filter。每分钟读取 action 聚合 bytes，与 `traffic.json` 基线做差，并把增量、累计和新基线作为一个 JSON 原子提交。任一计数读取失败则整次采样不写入；同一启动周期的 filter 损坏会先采样仍在的 action，再重建规则。

启用 HY2 端口跳跃时，客户端外部 UDP 连续范围由 manager 专属 NAT REDIRECT 指向唯一实际端口；tc 同时匹配该范围和必要的实际端口规则，因此统计、配额和限速仍按 Node ID 聚合。NAT 只维护可证明属于 manager 的命名空间，重启、停用、恢复和卸载都通过幂等 reconcile，绝不 flush 用户 ruleset。

端口 ingress 计数无法证明 SS2022、VLESS、Hysteria2 或 TUIC 认证成功，因此原始上传统计可能含未认证探测。四种协议共用 manager 的全局配额策略：默认只使用下载 egress 触发停用，上传、下载和合计仍全部统计、展示与归档；管理员若启用既有全局上传计费开关，则全部协议一起改为上传加下载。端口计数不是认证用户的精确业务账单，也不能替代抗流量攻击措施。

## 系统范围

项目使用 `tc` 进行统计和限速，并在明确启用 HY2 跳跃时使用 manager 专属 nftables/iptables NAT 对象；不使用或管理 UFW/firewalld/ipset/云安全组。tc/NAT 清理必须同时匹配所有权、精确规则和完整绑定；任何查询失败或范围外绑定都拒绝删除。服务存在性、启用状态与运行状态采用“存在/不存在/查询失败”三态判断，systemd/OpenRC 查询失败不会被当作已停止或不存在。BBR/TFO 只更新本项目标记的 sysctl 文件并保留其中其他项目设置，且只在能力通过时开启；设置、安装和更新都由持久事务保护，删除运行配置或完全卸载时恢复记录的原值。
