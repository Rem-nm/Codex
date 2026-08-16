# Ss2022 增量开发规范：Hysteria2 UDP 端口跳跃与远程订阅服务

## 1. 文档定位

本文是 Rem-nm/Codex/Ss2022/ 的下一阶段增量开发规范，合并并修订以下两项需求：

1. Hysteria2 UDP Port Hopping；
2. 订阅链接与远程订阅服务。

本文以当前已合并 SS2022、VLESS + REALITY + Vision、Hysteria2、TUIC 的 manager 1.2.0-dev.1、nodes schema 4 为基线。本文只取代现有文档中与“禁止端口跳跃”“绝不创建任何 NAT 规则”及本次新增订阅功能直接冲突的条款；其他已稳定的安全、事务、备份、回滚、流量和协议行为继续有效。

这两个功能可以在同一开发版本中实现，但必须保持模块隔离：

- 端口跳跃是 Hysteria2 的可选网络入口能力；
- 订阅服务是统一节点系统的只读客户端输出层；
- 任一附加功能故障都不得停止或破坏 sing-box；
- 仍然只有一个 sing-box 进程、一个统一节点数据库；
- 不为节点创建独立 sing-box 服务或独立节点数据库。

本阶段建议版本：

| 对象 | 目标版本 |
|---|---:|
| Manager | 1.3.0-dev.1 |
| nodes.json | schema 5 |
| bandwidth-plan.json | schema 3 |
| port-hopping-plan.json | schema 1 |
| subscription.json | schema 1 |
| subscription-export.json | schema 1 |

## 2. 总体目标与不可破坏项

当前协议继续统一管理：

~~~text
Shadowsocks 2022
VLESS + REALITY + Vision
Hysteria2
TUIC
~~~

现有以下功能必须继续正常：

- 永久唯一 Node ID；
- 节点名称去重；
- 节点添加、修改、删除、启停；
- 上传、下载和合计流量统计；
- 全局配额策略默认只按下载量触发；
- 每节点独立流量重置日；
- 上传和下载独立限速；
- disabled_manual、disabled_quota、disabled_error 状态；
- 配置候选检查、健康检查、事务提交和自动回滚；
- 备份、恢复、覆盖安装、更新和卸载；
- 标准 URI、单节点 Base64 和终端二维码；
- Debian、Ubuntu 等 systemd 系统与 Alpine OpenRC；
- 一个 sing-box 服务和一个 sing-box 主进程。

本次禁止顺带增加：

- Hysteria2 混合端口列表或随机范围；
- TUIC 端口跳跃；
- 多订阅组、订阅用户体系或管理 HTTP API；
- ACME、Web Server、反向代理或云安全组自动配置；
- 来源 IP、设备数、连接数限制；
- 访问日志、连接日志或目标网站日志；
- 防火墙 filter policy 管理；
- 一个节点一个进程或一个节点一个服务。

## 3. 最终架构

~~~text
                             rem
                              │
                      统一节点事务与 Node ID
                              │
                 ┌────────────┴────────────┐
                 │                         │
             nodes.json               traffic/history
                 │
        ┌────────┼─────────┬──────────┐
        │        │         │          │
      SS2022   VLESS      HY2        TUIC
                           │
                 可选 UDP Port Hopping
                           │
              manager 专属 NAT + TC 范围规则

nodes.json
    │
    └── root 管理器生成无服务端私钥的派生订阅快照
                    │
             低权限订阅 HTTP 服务
                    │
          Base64 / Raw / sing-box Profile
~~~

nodes.json 始终是节点真实数据源。port-hopping-plan.json、subscription-export.json 都是可重建的派生状态，不得成为第二份可独立编辑的节点数据库。

## 4. 统一数据模型与迁移

### 4.1 nodes schema 5

所有协议的公共字段增加：

~~~json
"subscription_enabled": true
~~~

Hysteria2 专属字段增加：

~~~json
"port_hopping_enabled": false,
"hop_port_start": null,
"hop_port_end": null,
"hop_interval": "30s"
~~~

示例：

~~~json
{
  "schema_version": 5,
  "nodes": [
    {
      "node_id": "a1b2c3d4",
      "name": "Tokyo-HY2",
      "protocol": "hysteria2",
      "password": "...",
      "tls_server_name": "example.com",
      "certificate_sha256": "...",
      "port": 42851,
      "address": "203.0.113.10",
      "address_type": "ipv4",
      "status": "enabled",
      "status_reason": "",
      "subscription_enabled": true,
      "port_hopping_enabled": true,
      "hop_port_start": 20000,
      "hop_port_end": 50000,
      "hop_interval": "30s",
      "quota_bytes": 0,
      "reset_day": 1,
      "upload_limit_mbps": 0,
      "download_limit_mbps": 0,
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-01T00:00:00Z",
      "last_reset_at": "2026-01-01T00:00:00Z",
      "next_reset_at": "2026-02-01T00:00:00Z"
    }
  ]
}
~~~

严格语义：

- subscription_enabled 必须是布尔值，适用于所有协议；
- port_hopping_enabled 只允许出现在 Hysteria2 节点；
- port_hopping_enabled=false 时，hop_port_start 和 hop_port_end 必须为 null；
- port_hopping_enabled=true 时，起止端口必须是 1 至 65535 的整数，且 start 小于或等于 end；
- hop_interval 第一版必须严格等于 "30s"；
- 不在节点数据中保存 port_hopping_backend；
- 继续采用协议判别联合和精确字段集合校验，未知字段必须拒绝。

### 4.2 旧数据迁移

schema 1、2、3、4 必须通过候选文件迁移到 schema 5，迁移前使用现有持久事务保存：

- nodes.json；
- traffic.json；
- traffic-history.json；
- manager-state.json；
- 当前 sing-box 配置；
- 受管证书；
- bandwidth plan；
- 服务状态。

迁移规则：

1. schema 1 的旧 SS2022 节点继续补 protocol="shadowsocks"；
2. 所有旧节点补 subscription_enabled=true；
3. 只有 Hysteria2 补端口跳跃的四个默认字段；
4. SS2022、VLESS、TUIC 不得出现 Hysteria2 跳跃字段；
5. Node ID、名称、地址、端口、密码、UUID、Reality KeyPair、证书、流量、配额、限速和状态不得改变；
6. 迁移候选必须通过 schema 5 严格校验；
7. 迁移失败必须恢复原文件和服务，不得留下半迁移状态。

服务是否启用与节点是否加入订阅是两个不同概念。升级后节点默认允许加入订阅，但订阅 HTTP 服务默认保持关闭，不能因升级自动开放任何服务。

### 4.3 订阅设置文件

/etc/ss-manager/subscription.json 使用 schema 1，建议结构：

~~~json
{
  "schema_version": 1,
  "enabled": false,
  "listen_address": "127.0.0.1",
  "listen_port": 18080,
  "public_base_url": null,
  "token": null,
  "created_at": null,
  "updated_at": null
}
~~~

约束：

- listen_address 第一版只能是 127.0.0.1；
- listen_port 必须是 1 至 65535 的空闲 TCP 端口；
- public_base_url 只能是绝对 http 或 https URL；
- 第一版 public_base_url 只接受 scheme://host[:port]，不接受用户信息、查询参数、fragment 或额外路径；
- 保存前去除末尾斜杠并规范化；
- HTTP 允许使用，但必须二次确认并警告凭据可能被窃听；
- token 使用至少 32 个密码学安全随机字节生成，采用无填充 Base64URL，典型长度为 43 字符；
- enabled=true 时 token 和 public_base_url 必须有效；
- 停用服务只停止服务，不自动删除 token 或公网地址；
- 重新启用默认继续使用原 URL，除非用户主动轮换 token。

主设置文件必须是 root:root、0600、常规文件且不得为符号链接。

### 4.4 派生状态文件

建议增加：

~~~text
/var/lib/ss-manager/port-hopping-plan.json
/var/lib/ss-manager/subscription/subscription-export.json
/var/lib/ss-manager/subscription/subscription-runtime.json
~~~

要求：

- port-hopping-plan.json 记录后端、Node ID、地址族、接口、范围、实际端口和规则身份；
- subscription-export.json 只包含已导出的 URI、客户端 outbound、最终 Base64/Raw/Profile 或等价安全派生内容；
- subscription-runtime.json 只提供订阅服务运行所需 token 和生成状态；
- 派生订阅文件不得包含 Reality Private Key、TLS Private Key 或其他服务端专属秘密；
- 派生目录建议 root:ss-manager-subscription、0750；
- 服务可读文件建议 root:ss-manager-subscription、0640；
- 文件必须通过临时常规文件、fsync 和原子替换发布；
- 任一来源文件、候选文件或目标文件为符号链接时拒绝继续；
- 派生文件不作为备份真实数据源，恢复后必须从 nodes 和 subscription.json 重建。

## 5. Hysteria2 UDP 端口跳跃

### 5.1 工作原理

每个 Hysteria2 节点仍然只有一个 sing-box UDP 监听端口：

~~~text
客户端访问 UDP 20000-50000
              ↓
manager 专属 NAT REDIRECT
              ↓
实际监听 UDP 42851
              ↓
同一个 Hysteria2 inbound / 同一个 Node ID
~~~

不得：

- 为范围内每个端口生成 inbound；
- 修改节点实际 port；
- 创建额外 sing-box 进程；
- 将范围写进服务端 Hysteria2 inbound。

第一版只支持一个连续 UDP 范围。普通 Hysteria2 创建流程保持不变，新节点默认关闭端口跳跃。

### 5.2 菜单与交互

Hysteria2 修改菜单调整为：

~~~text
1. 名称
2. 端口
3. 节点地址
4. 修改密码
5. 重新生成自签名证书
6. 端口跳跃设置
7. 月流量限额
8. 流量重置日
9. 上传/下载限速
0. 返回
~~~

关闭状态：

~~~text
Hysteria2 端口跳跃

状态：关闭
实际端口：42851 / UDP

1. 开启端口跳跃
0. 返回
~~~

开启状态：

~~~text
Hysteria2 端口跳跃

状态：已开启
实际端口：42851 / UDP
跳跃范围：20000-50000 / UDP
跳跃间隔：30s

1. 修改跳跃端口范围
2. 关闭端口跳跃
0. 返回
~~~

输入方式固定为：

~~~text
请输入 UDP 跳跃端口范围（格式：20000-50000）：
>
~~~

不增加随机范围菜单，不询问跳跃间隔。

### 5.3 范围解析和校验

只接受十进制 start-end：

- 不允许空格、加号、前导负号、逗号或第二个范围；
- start 和 end 均为整数；
- 1 <= start <= end <= 65535；
- 禁止使用 eval；
- 所有端口、Node ID、接口名和后端参数必须经过白名单验证；
- 冲突计算必须使用区间相交公式，不能逐端口循环扫描数万个端口。

非常大的范围虽然语法合法，但必须警告。范围包含系统或项目已占用端口时仍应拒绝，不能只靠警告继续。

### 5.4 端口占用和范围冲突

启用或修改前必须一次性取得一致的系统 UDP 监听快照；查询失败时失败关闭。

新范围不得覆盖：

- 其他 Hysteria2 已配置的跳跃范围；
- 其他 SS2022 UDP 端口；
- 其他 Hysteria2 实际 UDP 端口；
- 其他 TUIC UDP 端口；
- 系统现有 UDP listener；
- 能安全识别的第三方 REDIRECT 或 DNAT 范围。

VLESS 只使用 TCP，不构成 UDP 冲突。

即使节点当前是 disabled_manual、disabled_quota 或 disabled_error，其已配置的跳跃范围仍然在数据库层保留占用，防止另一个节点占用后导致原节点无法恢复。

当前节点自己的实际端口允许位于自己的跳跃范围内。规则生成器必须通过排除该端口或拆分区间，避免 actual_port 重定向到自身；不能产生递归或无意义规则。

### 5.5 NAT 后端探测

优先顺序：

~~~text
nftables 能力探测成功
        ↓
使用 nftables

nftables 不可用或能力探测失败
        ↓
探测 iptables 和 ip6tables
~~~

仅检查命令是否存在不够。必须在隔离的临时专属 table/chain 中探测：

- NAT table/chain 创建；
- UDP 端口范围匹配；
- REDIRECT；
- comment 或等价规则身份；
- 列出、核验和精确删除；
- 所需 IPv4/IPv6 地址族。

探测产生的临时对象无论成功失败都必须清理。普通协议和未开启跳跃的 Hysteria2 不应把 nftables/iptables 作为全局强制依赖。

第一版采用完整地址族策略：节点实际对客户端暴露 IPv4、IPv6 或两者时，所需地址族必须全部能够安装并验证；不能含糊地只安装 IPv4 规则后报告整体成功。

### 5.6 规则所有权

nftables：

- 使用 manager 专属 table/chain；
- table/chain 命名固定并校验；
- 每条规则携带 Node ID 或等价稳定身份；
- 只修改本项目命名空间；
- 不 flush 用户 ruleset。

iptables：

- 使用 manager 专属自定义 chain；
- PREROUTING 中只维护一个可证明属于本项目的跳转；
- 节点规则带完整 Node ID comment；
- 使用锁等待参数避免并发修改；
- IPv6 必须单独验证 ip6tables；
- 不根据端口范围模糊删除规则。

绝对禁止：

~~~text
iptables -F
iptables -t nat -F
nft flush ruleset
修改 INPUT/FORWARD/OUTPUT policy
修改 UFW、firewalld、ipset 或云安全组
~~~

### 5.7 流量统计和限速

这是端口跳跃的强制实现项，不能只增加 NAT。

当前 manager 在外部接口使用 tc flower：

~~~text
客户端上传：ingress dst_port
客户端下载：egress  src_port
~~~

NAT PREROUTING 位于 tc ingress 之后，反向 NAT 也会影响外部 egress 所见端口。因此只匹配实际端口会使跳跃流量绕过或漏计统计与限速。

bandwidth-plan.json 必须升级为 schema 3，并支持：

- 精确端口匹配；
- start-end 范围匹配；
- 同一 Node ID 和同一方向继续共享一个 tc action；
- 启用跳跃时为外部范围绑定上传和下载规则；
- 实际端口不在范围内时，额外保留实际端口精确规则以兼容旧客户端直连；
- 实际端口在范围内时不得重复绑定；
- 更新 action bind 数量、cookie、handle、接口、地址族和传输集合校验；
- 更新所有权证明、损坏重建、清理和回滚；
- 继续只生成一个节点级流量对象，不按外部端口拆分。

运行时必须探测当前 tc flower 是否真正支持 src_port/dst_port 范围。目标系统能力不足时拒绝开启端口跳跃，不能让功能看似成功但统计或限速失效。

配额含义保持不变：

- 上传、下载、合计全部统计；
- 默认只按本周期下载量触发配额；
- 达到配额只停用该 Node ID；
- 不停止整个 sing-box；
- 重置日按现有状态规则自动恢复 disabled_quota；
- disabled_manual 和 disabled_error 保持现有语义。

### 5.8 期望规则状态

| 节点状态 | port_hopping_enabled | NAT 规则 |
|---|---:|---|
| enabled | true | 必须存在并健康 |
| enabled | false | 不得存在 |
| disabled_manual | true | 暂时移除 |
| disabled_quota | true | 暂时移除 |
| disabled_error | true | 暂时移除 |
| 节点已删除 | 任意 | 不得存在 |

停用节点时只移除运行规则，不清空已配置范围。重新启用节点时重新验证端口冲突、后端和地址族，再恢复规则。

### 5.9 端口跳跃事务

候选流程：

~~~text
验证候选 nodes schema
→ 验证范围和冲突
→ 探测 NAT 与 tc 范围能力
→ 建立持久事务日志
→ 确认 Hysteria2 实际 UDP 端口健康
→ 安装并核验新 NAT 规则
→ 应用并核验 tc 范围规则
→ 更新统计基线
→ 原子提交 nodes 和派生 plan
→ 生成新的分享/订阅派生内容
→ 综合健康检查
~~~

修改范围时必须先建立新规则并验证，再删除旧规则。任一步失败：

- 恢复旧 nodes；
- 根据旧 nodes 重建旧 NAT 规则；
- 恢复旧 tc 规则和统计基线；
- 验证旧 Hysteria2 仍可用；
- 保留足够恢复证据。

仅启用、关闭或修改跳跃范围不得重启 sing-box，但必须重新应用 tc。修改实际监听端口仍按现有 sing-box 配置事务处理。

删除节点、修改端口、修改地址族、启停节点、配额停用、结算恢复、备份恢复、安装事务恢复和卸载都必须调用同一个端口跳跃 reconcile 层，不能在菜单中散落拼接 nft/iptables 命令。

### 5.10 重启恢复和健康检查

增加一个全局附加服务：

~~~text
systemd: ss-manager-porthop.service
OpenRC:  ss-manager-porthop
~~~

不得为每个节点创建服务。服务职责：

1. 等待网络可用；
2. 确认 sing-box 服务和实际 Hysteria2 UDP 端口；
3. 从 nodes 重建期望规则；
4. 幂等核验已有规则；
5. 清理仅能证明属于 manager 的孤儿规则；
6. 不因自身失败使 sing-box 启动失败。

现有周期维护也应执行轻量 reconcile，修复项目规则被外部清空的情况。提供内部入口：

~~~text
ss-manager.sh --port-hop-restore
~~~

健康检查至少验证：

- sing-box 状态和进程；
- Hysteria2 actual_port UDP listener；
- NAT 后端、地址族、范围、目标端口和 Node ID 所有权；
- 无重复或额外项目规则；
- tc 范围规则、共享 action 和 bind 数量；
- 节点状态与规则存在性一致。

### 5.11 分享与客户端输出

普通 Hysteria2 URI 继续使用 actual_port。启用跳跃后：

~~~text
hysteria2://...@example.com:20000-50000/...
~~~

只修改统一 node_hysteria2_uri，单节点 Base64、二维码和订阅必须复用它。不要在 URI 中创造 hopInterval 查询参数；第一版固定 30 秒。

sing-box 客户端 outbound：

- 普通 Hysteria2 使用 server_port；
- 端口跳跃使用 server_ports: ["20000:50000"]；
- 同时设置 hop_interval: "30s"；
- 设置 server_ports 时不得同时输出 server_port；
- 不把服务端 NAT 规则写入客户端配置。

### 5.12 备份、恢复、卸载和提示

nodes 备份自然包含端口跳跃字段。不要备份原始系统 NAT 规则文本；恢复时从 nodes 重建。

恢复流程必须在节点、证书和 sing-box 实际端口恢复后安装 NAT 和 tc 规则，并纳入恢复回滚。

所有卸载模式在删除 manager 程序前都必须停止恢复服务并删除可证明属于 manager 的运行 NAT 规则。保留数据模式可保留节点字段和 plan 证据；完全卸载删除它们。不得删除用户规则。

开启成功后明确提示：

~~~text
Hysteria2 端口跳跃已启用。

实际监听：UDP 42851
外部跳跃范围：UDP 20000-50000

请自行确认云安全组和外部防火墙已放行 UDP 20000-50000。
~~~

README、安装提示和卸载提示必须改为：项目不管理用户防火墙，只为已明确启用的 Hysteria2 端口跳跃维护自身可证明所有权的 UDP NAT REDIRECT 规则。

## 6. 订阅链接与远程订阅服务

### 6.1 第一版范围

第一版只创建一个 default subscription，提供：

1. 默认 Base64 URI Bundle；
2. Raw URI 列表；
3. 完整 sing-box Remote Profile。

不开发多个订阅组、用户账户、订阅写 API、Web 管理页面或自动反向代理。

订阅节点的资格：

~~~text
subscription_enabled == true
并且
status == "enabled"
~~~

disabled_manual、disabled_quota、disabled_error 节点暂时不输出，但 subscription_enabled 原值不变。恢复为 enabled 后自动重新出现。

从订阅移除节点只改变 subscription_enabled，不改变节点运行状态、sing-box 配置、流量、配额、限速或端口跳跃状态。

输出顺序固定为：

1. created_at 升序；
2. created_at 相同时按 node_id 升序。

### 6.2 订阅输出格式

默认 URL：

~~~text
https://sub.example.com/sub/<TOKEN>
~~~

等价 Base64 URL：

~~~text
https://sub.example.com/sub/<TOKEN>/base64
~~~

Raw：

~~~text
https://sub.example.com/sub/<TOKEN>/raw
~~~

sing-box：

~~~text
https://sub.example.com/sub/<TOKEN>/sing-box
~~~

Raw 规范：

- UTF-8；
- 每节点一个标准 URI；
- 节点间只有一个 LF；
- 不插入空行；
- 统一保留一个最终 LF；
- 不输出注释或流量文本。

Base64 规范：

- 对完整 Raw 字节串整体编码；
- 使用 RFC 4648 标准 Base64；
- 保留标准 padding；
- 不换行；
- 不能把单节点 Base64 再逐行拼接。

Content-Type：

| 路由 | Content-Type |
|---|---|
| 默认、/base64 | text/plain; charset=utf-8 |
| /raw | text/plain; charset=utf-8 |
| /sing-box | application/json; charset=utf-8 |

### 6.3 统一导出层

现有 node_share_uri 已经是四协议统一 URI 分派入口，必须继续复用。新增客户端配置导出入口，例如：

~~~text
node_share_uri(node)
node_client_outbound(node)
subscription_build_artifacts(candidate_nodes)
~~~

不要为了订阅复制四套 URI 生成器，也不要大规模改写现有稳定的 links.sh。

建议新增：

~~~text
lib/export.sh
lib/subscription.sh
subscription/ss-manager-subscription.py
~~~

职责：

- links.sh：标准单节点 URI；
- export.sh：从经过严格校验的节点生成安全客户端 outbound；
- subscription.sh：设置、token、派生快照、服务和健康检查；
- Python HTTP 服务：只读取已发布的安全派生内容并响应固定路由，不解析 nodes.json。

### 6.4 权限隔离和派生快照

HTTP 服务不得以 root 身份直接读取 nodes.json。nodes.json 含有 Reality Private Key 等服务端秘密，把它交给网络服务违反最小权限原则。

正确流程：

~~~text
root manager 读取并校验 nodes 候选
→ 调用现有 URI 生成器
→ 生成客户端 outbound
→ 删除所有服务端专属字段
→ 生成 Raw、Base64、完整 sing-box Profile
→ sing-box check 校验客户端 Profile
→ 原子发布单一 subscription-export.json
→ 低权限 HTTP 服务只读发布结果
~~~

这不是第二份节点数据库，因为：

- 不允许人工修改；
- 不承载服务端运行状态；
- 不作为恢复真实数据源；
- 任意时刻都可以从 nodes 和公开证书重建；
- 节点事务完成后自动重建，不需要用户手动刷新。

订阅服务使用专用无登录系统用户，例如 ss-manager-subscription：

- 无 shell；
- 无 home；
- 不属于 root 组；
- 无权读取 /etc/ss-manager/nodes.json；
- 无权读取 Reality/TLS 私钥；
- 无权写入项目状态；
- 只读 subscription-runtime.json 和 subscription-export.json；
- 只能监听 127.0.0.1。

systemd 应启用适用的 NoNewPrivileges、ProtectSystem、ProtectHome、PrivateTmp、RestrictAddressFamilies 等加固；OpenRC 使用 command_user 和等价可用限制。加固不得破坏 Debian/Ubuntu/Alpine 兼容性。

### 6.5 协议导出要求

#### Shadowsocks 2022

URI 继续使用现有 SIP002 逻辑。客户端 outbound 包含：

- type=shadowsocks；
- server；
- server_port；
- method；
- password。

#### VLESS + REALITY + Vision

客户端只包含：

- server 和 server_port；
- uuid；
- flow=xtls-rprx-vision；
- tls.enabled=true；
- tls.server_name；
- tls.reality.enabled=true；
- Reality Public Key；
- Short ID。

绝对禁止 Reality Private Key 和 Reality handshake 服务端配置出现在订阅输出。

#### Hysteria2

客户端只包含：

- server；
- server_port，或跳跃时的 server_ports；
- password；
- hop_interval；
- tls.server_name；
- 客户端验证所需公开证书信息。

绝对禁止 TLS Private Key。

#### TUIC

客户端只包含：

- server 和 server_port；
- uuid；
- password；
- congestion_control=bbr；
- udp_relay_mode=native；
- zero_rtt_handshake=false；
- tls.server_name；
- 客户端验证所需公开证书信息。

绝对禁止 TLS Private Key。

### 6.6 证书 Pin 格式

现有 certificate_sha256 是叶证书 DER SHA-256 的十六进制摘要，用于现有详情和 URI 行为。不得把它直接放入 sing-box 的 certificate_public_key_sha256，因为后者要求服务器公钥 SPKI SHA-256 的 Base64 值，两者不是同一种摘要。

客户端 Profile 应从公开证书重新计算 SPKI SHA-256 Base64，并写入：

~~~json
"certificate_public_key_sha256": [
  "<base64-spki-sha256>"
]
~~~

要求：

- 不重新定义或覆盖现有 certificate_sha256；
- SPKI Pin 可作为派生字段，不需要成为节点永久身份；
- 公开证书缺失、证书与节点摘要不一致或 SPKI 计算失败时，该节点导出失败；
- 使用自签名证书时必须实测 insecure 与 SPKI Pin 的组合，确保 Pin 确实被验证；
- 不能为了省事只设置 insecure=true 而取消 Pin；
- TUIC 通用 URI 继续遵守当前实现：不创造不存在的可移植 Pin 参数；
- sing-box Profile 最低兼容版本应明确为 1.13.0，因为 certificate_public_key_sha256 从该版本开始支持。

### 6.7 Hysteria2 端口跳跃联动

port_hopping_enabled=false：

- URI 使用 actual port；
- sing-box outbound 使用 server_port。

port_hopping_enabled=true：

- URI authority 使用 start-end；
- sing-box outbound 使用 server_ports: ["start:end"]；
- 使用 hop_interval="30s"；
- 不输出 actual port 作为唯一客户端端口；
- 不把 NAT 后端、接口或服务器规则暴露给客户端。

端口跳跃修改事务成功后必须自动生成新的订阅派生内容。订阅生成失败不得回滚已经健康的代理或 NAT 功能，但订阅端点必须进入明确的降级状态，不能继续静默提供包含旧端口的陈旧订阅。

### 6.8 完整 sing-box Remote Profile

sing-box 图形客户端支持以 URL 为更新源的 Remote Profile，但返回内容必须是完整配置，而不是 outbounds 数组。

第一版 Profile 定义为版本化的最小客户端配置，至少包含：

- log；
- dns；
- 一个明确支持范围的本地 mixed inbound；
- 四协议节点 outbounds；
- selector outbound；
- direct outbound；
- route。

要求：

- 默认代理 selector 包含所有订阅节点；
- 节点 outbound tag 使用名称和永久 Node ID 组合，例如 Tokyo [node-a1b2c3d4]，避免与保留 tag 冲突并保证唯一；
- selector、direct 等内部 tag 使用固定 rem 前缀；
- 默认选择排序后的第一个节点；
- route final 指向 selector；
- 每次生成都使用当前受支持 sing-box 二进制执行 check；
- check 失败不得发布或返回损坏 JSON；
- 无可用订阅节点时不生成会静默直连的 Profile，/sing-box 返回 503；
- 必须实测代理连通性，不能只以 check 返回 0 作为完成标准；
- 一个通用 Profile 不能未经测试宣称兼容所有移动和桌面平台。第一版应明确其测试目标客户端和最低 sing-box 版本。

Profile 模板必须版本化。未来 sing-box 配置字段变化时，通过模板版本和兼容适配更新，不能根据服务器节点 JSON 直接拼接不受控字段。

### 6.9 自动更新和失败策略

以下操作成功后自动重建订阅派生内容：

- 添加或删除节点；
- 节点启用、手动停用、配额停用、错误停用和自动恢复；
- 修改名称、地址、端口或协议凭据；
- 重新生成 SS 密钥；
- 重新生成 VLESS UUID、Reality KeyPair 或 Short ID；
- 修改 HY2 密码、证书或端口跳跃；
- 修改 TUIC UUID、Password 或证书；
- 修改 subscription_enabled；
- 恢复备份。

不需要日常“手动刷新订阅”。菜单中的重建操作只作为故障修复和诊断。

失败策略：

- 单个节点 URI 或 outbound 导出失败：跳过该节点，记录 Node ID 和不含秘密的原因，继续导出其余节点；
- 不得输出损坏 URI；
- 系统性生成失败：原子发布 unavailable 标记，端点返回通用 503，不能继续提供可能含已删除凭据或旧端口的陈旧快照；
- sing-box Profile 单独校验失败时，Raw/Base64 可继续服务已验证内容，/sing-box 返回 500 或 503；
- HTTP 响应不得包含内部路径、命令输出、节点秘密或堆栈；
- 订阅失败不得回滚健康的 sing-box 节点事务，不得重启或停止 sing-box。

### 6.10 HTTP 服务

服务名称：

~~~text
systemd: ss-manager-subscription.service
OpenRC:  ss-manager-subscription
~~~

默认：

~~~text
127.0.0.1:18080
~~~

第一版监听地址不可修改，只允许高级设置修改本地 TCP 端口。启用前必须检查：

- 端口是整数且范围有效；
- 未被 127.0.0.1、0.0.0.0 或 IPv6 wildcard 的冲突 TCP listener 占用；
- 与项目 TCP 服务无绑定冲突；
- 服务模板和低权限用户完整；
- 派生订阅内容可生成；
- 本地健康检查成功。

订阅服务与 sing-box 独立。订阅服务停止、崩溃、升级或重启不得触发 sing-box 操作。

建议使用 Python 3 标准库实现小型只读 HTTP 服务，不引入外部包管理器。服务不得执行 shell、jq、sing-box、nft、iptables 或节点事务；所有复杂导出和检查由 root manager 在发布前完成。

### 6.11 路由和 HTTP 语义

固定路由：

~~~text
/sub/<TOKEN>
/sub/<TOKEN>/base64
/sub/<TOKEN>/raw
/sub/<TOKEN>/sing-box
~~~

可增加仅返回通用状态、不含节点数据的本地 /healthz。不得提供目录列表、token 列表、文件浏览或管理写接口。

要求：

- GET 返回正文；
- HEAD 返回与 GET 一致的状态和响应头，但没有正文；
- POST、PUT、PATCH、DELETE、OPTIONS 等不支持方法返回 405；
- 405 包含 Allow: GET, HEAD；
- 错误 token、缺少 token、未知路由、/sub 和 /sub/ 均返回相同通用 404；
- token 使用恒定时间比较；
- token 只允许固定 Base64URL 字符集和固定长度；
- 不进行模糊路径规范化；
- 编码斜杠、点段、双重编码、NUL、反斜杠和超长路径必须拒绝；
- 不从 Host、Forwarded 或 X-Forwarded-* 动态构造订阅 URL；
- 查询参数不参与认证，第一版可直接拒绝带查询参数的订阅请求；
- 路径不能映射为文件系统路径；
- /etc/ss-manager 绝不能作为 Web Root。

安全响应头至少包括：

~~~text
Cache-Control: no-store
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
~~~

错误响应使用固定、简短且不含秘密的正文。服务关闭访问日志，普通 journald/OpenRC 日志不记录完整请求路径。

### 6.12 Token 和反向代理安全

Token 是 Bearer Secret。获得完整 URL 的人可以获取全部订阅客户端凭据。

生成要求：

- 至少 256-bit CSPRNG；
- 不能使用时间戳、用户名、Node ID、IP 或 shell RANDOM；
- 不通过命令行参数传递或显示给进程列表；
- 普通日志中必须脱敏；
- 只有“查看订阅地址”和明确显示二维码时展示；
- 重新生成前必须确认旧 URL 立即失效；
- 轮换成功后验证旧 URL=404、新 URL=200；
- 新 token 或服务重载失败时恢复旧 token，避免两个 URL 都不可用。

公网地址优先使用 HTTPS。rem 不修改 Nginx、Caddy、Apache、1Panel 或证书配置，只提示用户把公网 HTTPS 反向代理到 127.0.0.1:18080。

由于 token 位于 URL path，Nginx、Caddy 等默认访问日志可能记录完整 token。启用流程和文档必须明确提醒用户对订阅 location 关闭或脱敏访问日志。rem 自己不能声称已经保护用户 Web Server 日志。

### 6.13 菜单

主菜单增加：

~~~text
12. 订阅管理
13. Sing-box 管理
14. 更新管理
15. 备份与恢复
16. 系统设置
17. 卸载
~~~

订阅管理：

~~~text
订阅状态：已启用/已停用/异常
本地监听：127.0.0.1:18080
公网地址：已配置/未配置
订阅节点：8
跳过节点：0

1. 查看订阅地址
2. 查看订阅节点
3. 管理订阅节点
4. 全部加入订阅
5. 全部移出订阅
6. 显示订阅二维码
7. 重新生成订阅 Token
8. 设置订阅公网地址
9. 设置本地监听端口
10. 检查订阅服务
11. 重建订阅输出
12. 启用 / 停用订阅服务
0. 返回
~~~

管理节点列表显示名称、协议、运行状态和订阅开关。切换 subscription_enabled 使用 Node ID，不使用显示序号作为永久身份。

全部加入或移出只修改 subscription_enabled。全部移出前必须确认。

订阅二维码编码默认 Base64 订阅 URL，不把全部节点 URI 直接塞入二维码。显示前提示完整 URL 属于敏感凭据。

### 6.14 订阅设置事务

首次启用：

~~~text
验证本地端口
→ 验证公网 URL
→ 生成 token
→ 创建/核验低权限用户和目录
→ 生成安全派生订阅候选
→ 校验 sing-box Profile
→ 安装并核验 systemd/OpenRC 服务
→ 原子提交 subscription.json 和运行文件
→ 启动订阅服务
→ 本地请求四个路由
→ 提交事务
~~~

失败时恢复旧设置、旧 token、旧派生内容和旧服务状态。不得影响 sing-box。

修改公网 URL只影响显示和生成 URL，不需要重启 sing-box。修改本地端口只重启订阅服务。切换 subscription_enabled 只更新节点元数据和订阅派生内容，不重新生成 sing-box 服务端配置、不重启 sing-box、不重新应用 tc 或 NAT。

现有 apply_state_transaction 默认会处理 sing-box 和 tc，因此必须增加明确的元数据事务或效果标志，不能为了切换订阅开关触发无关代理重启。

### 6.15 健康检查

本地检查优先，不依赖公网域名能否从服务器回环访问：

- 服务存在、启用状态和运行状态；
- 127.0.0.1:port listener；
- /healthz；
- 正确 token 的 Base64、Raw 和 sing-box 路由；
- 错误 token 404；
- HEAD 无正文；
- 派生快照来源版本和生成时间；
- 节点数量、跳过数量和失败原因；
- Profile 最近一次 check 结果；
- 服务用户无权读取 nodes 和私钥。

公网 URL 可作为额外测试，失败只提示 DNS、TLS 或反向代理问题，不能据此停止本地订阅服务。

### 6.16 备份、恢复和卸载

备份必须包含：

- nodes 中的 subscription_enabled；
- subscription.json；
- token；
- service desired state；
- listen port；
- public base URL。

备份权限继续为 0600。不得备份派生订阅内容作为真实数据源。

恢复：

1. 验证备份结构、权限和 token；
2. 恢复 nodes 与 subscription.json；
3. 保留原 token 和 URL；
4. 从节点和公开证书重建安全派生内容；
5. 根据 enabled 恢复订阅服务；
6. 验证旧 URL 继续可用；
7. 失败时恢复恢复前状态。

恢复不得自动重新生成 token。

所有卸载模式应停止并移除订阅服务程序。保留数据模式可保留 subscription.json；完全卸载删除设置和 token，并删除确属本项目的低权限服务用户。不得修改用户反向代理，只提示用户自行清理站点配置和访问日志。

### 6.17 订阅流量信息

第一版订阅只包含连接配置：

- 不修改节点名称以加入流量；
- 不输出 upload/download/total/expire；
- 不输出 Subscription-Userinfo。

原因是默认订阅包含多个独立 Node ID、配额和重置周期，不存在正确的单一订阅级流量数值。未来若增加多订阅聚合模型，再单独设计。

### 6.18 GitHub 数据边界

只能提交：

- 代码；
- 空模板；
- 示例 token 占位符；
- 测试夹具；
- 开发文档。

严禁提交：

- 真实 token 和完整订阅 URL；
- 真实节点 URI；
- 实际客户端 Profile；
- VPS 地址、域名和凭据；
- Reality Private Key；
- TLS Private Key；
- 用户备份和真实流量。

## 7. 两项功能的组合事务原则

代理运行优先级：

~~~text
sing-box 与现有节点
        >
流量统计、配额和限速一致性
        >
Hysteria2 端口跳跃附加入口
        >
订阅输出服务
~~~

但“优先级低”不表示可以静默成功：

- NAT 或 tc 规则未完整生效时，端口跳跃操作必须失败并回滚；
- 订阅生成失败时，代理节点事务可以成功，但订阅必须报告异常并拒绝提供陈旧敏感内容；
- 订阅服务故障不得触发 sing-box restart；
- 端口跳跃服务故障不得使 sing-box.service/OpenRC sing-box 启动失败；
- 任一事务都必须保留可重试和可审计的持久恢复证据。

建议把节点候选事务拆成明确效果：

~~~text
singbox_config
tc_rules
port_hopping
subscription_export
metadata_only
~~~

每个操作声明需要的效果，避免修改 subscription_enabled 时重启 sing-box，也避免修改跳跃范围时漏掉 tc。

## 8. 预计代码和文档修改范围

| 文件/模块 | 修改 |
|---|---|
| lib/common.sh | schema 5、严格字段、迁移、订阅和 plan 校验 |
| lib/nodes.sh | 新节点默认订阅字段、HY2 跳跃字段、范围冲突、详情 |
| lib/port_hopping.sh | 新增 NAT 能力探测、规则、所有权、reconcile |
| lib/bandwidth.sh | plan schema 3、tc 端口范围和绑定校验 |
| lib/links.sh | HY2 跳跃 URI，继续作为统一 URI 入口 |
| lib/export.sh | 新增四协议客户端 outbound 和安全导出 |
| lib/subscription.sh | 新增设置、token、派生内容、菜单后端和健康检查 |
| subscription/ss-manager-subscription.py | 低权限只读 HTTP 服务 |
| lib/backup.sh | NAT、订阅设置和服务事务、恢复与回滚 |
| lib/traffic.sh | quota 状态变化后的 port-hop 和订阅联动 |
| lib/service.sh | 两个新 systemd/OpenRC 服务抽象 |
| lib/menu.sh | HY2 跳跃菜单、订阅菜单、卸载提示 |
| lib/system.sh | 可选 NAT 依赖、订阅服务用户、端口检查 |
| lib/update.sh | 新模块/模板结构、语法和更新事务 |
| install.sh | 新文件、服务模板、用户和安装事务 |
| ss-manager.sh | --port-hop-restore、订阅内部命令 |
| systemd/ | port-hop 与 subscription 服务模板 |
| openrc/ | port-hop 与 subscription 服务模板 |
| README/docs | 防火墙例外、schema、事务、服务和安全边界 |
| tests/ | schema、NAT、tc、导出、HTTP、安全和全协议回归 |

不得为实现订阅而把所有稳定协议模块整体重写。公共导出层应在现有 node_share_uri 基础上增量抽象。

## 9. 测试要求

### 9.1 Schema 和迁移

1. schema 1、2、3、4 分别迁移到 schema 5；
2. 四协议旧节点的 Node ID、凭据、流量、配额、限速和状态完全不变；
3. 所有节点补 subscription_enabled=true；
4. 只有 HY2 补跳跃默认字段；
5. 未知字段、错误类型、半开启跳跃状态被拒绝；
6. 迁移故障和断电模拟能够恢复 schema 4 原状态。

### 9.2 Port Hopping 单元和集成

1. 范围解析边界、非法格式和超大范围；
2. 区间相交和不相交；
3. 与 SS/HY2/TUIC UDP 端口冲突；
4. 与禁用 HY2 保留范围冲突；
5. 系统 UDP listener 扫描失败时失败关闭；
6. 第三方 NAT 冲突处理；
7. nftables IPv4、IPv6、双栈能力探测；
8. iptables/ip6tables fallback；
9. 规则 Node ID 所有权和幂等；
10. 自身 actual port 位于范围内的排除；
11. 修改时新规则先建立、旧规则后删除；
12. 每个事务崩溃点的持久回滚；
13. reboot 后恢复且无重复规则；
14. enabled/disabled_manual/disabled_quota/disabled_error 状态矩阵；
15. 删除和三种卸载模式无孤儿规则；
16. tc src/dst 范围能力；
17. 跳跃流量上传、下载、合计均准确增长；
18. 跳跃流量上传和下载限速分别有效；
19. 下载配额达到后只停用当前 Node ID；
20. 实际端口旧客户端直连仍被统计和限速；
21. 不支持 tc 范围的系统拒绝开启；
22. NAT 服务失败不影响普通 HY2 和其他协议。

### 9.3 URI 和客户端导出

1. 四协议现有单节点 URI 回归；
2. 普通 HY2 URI 仍使用 actual port；
3. 跳跃 HY2 URI 使用 start-end；
4. 跳跃 sing-box outbound 使用 start:end 和 30s；
5. VLESS 不含 Reality Private Key；
6. HY2/TUIC 不含 TLS Private Key；
7. SPKI Pin 与公开证书重新计算值一致；
8. 叶证书 DER hex 不会误写到 SPKI Base64 字段；
9. 名称正确 URL/JSON 编码；
10. outbound tag 唯一且不与内部 tag 冲突。

### 9.4 订阅 HTTP

1. 四协议 Raw 每行一个且顺序稳定；
2. Base64 解码后与 Raw 字节完全一致；
3. 默认路径与 /base64 内容一致；
4. 完整 Profile 通过 sing-box check；
5. Profile 使用实际客户端建立代理连接；
6. GET 和 HEAD；
7. 不支持方法返回 405 和 Allow；
8. 错 token、短 token、/sub、未知路径统一 404；
9. token 轮换后旧 404、新 200；
10. ../、编码点段、编码斜杠、反斜杠、NUL、双重编码和超长路径；
11. Host/X-Forwarded-Host 注入不会改变生成 URL或路由；
12. 响应头 no-store、nosniff、no-referrer；
13. 服务日志和进程参数不出现完整 token；
14. 服务用户不能读取 nodes、Reality Private Key 和 TLS Private Key；
15. subscription_enabled=false 时节点仍运行但不输出；
16. disabled_manual/disabled_quota 暂时消失并在恢复后重新出现；
17. 添加、删除、改名、改地址、换凭据后无需手动刷新；
18. HY2 跳跃修改后订阅立即使用新范围；
19. 单节点导出失败只跳过该节点并显示诊断；
20. 系统性生成失败不继续提供陈旧快照；
21. 无可用节点时 /sing-box 不返回 direct-only 泄漏配置；
22. 订阅服务崩溃、重启和升级不影响四协议代理；
23. 本地健康正常但公网反代失败时只提示外部问题；
24. 重启后 token 不变、服务按 desired state 恢复；
25. 备份恢复后旧订阅 URL 继续工作；
26. 三种卸载模式正确处理服务和设置；
27. Nginx/Caddy 示例提示明确说明关闭或脱敏 token 路径日志。

### 9.5 全协议回归

在同一个 sing-box 进程中至少保留并测试：

- 两个 SS2022；
- 两个 VLESS；
- 一个普通 Hysteria2；
- 一个开启端口跳跃的 Hysteria2；
- 两个 TUIC。

逐项覆盖：

- 添加、修改、删除；
- 手动端口和随机端口；
- IPv4、IPv6、域名；
- 密钥/UUID/证书轮换；
- 启停、配额、重置、限速；
- 链接、Base64、二维码；
- 备份恢复；
- sing-box 更新；
- manager 覆盖安装；
- reboot；
- 卸载保留和重新安装。

### 9.6 实机矩阵

至少执行：

- Debian 11；
- Debian 12；
- Ubuntu LTS；
- Alpine OpenRC；
- nftables 后端；
- iptables/ip6tables fallback；
- IPv4-only；
- IPv6-only；
- 双栈；
- 低版本 iproute2 不支持范围的拒绝路径；
- 真实外部 Hysteria2/sing-box 客户端端口跳跃；
- 真实 Base64 订阅客户端；
- 真实 sing-box 图形客户端 Remote Profile。

本地模拟、shell 单测和 sing-box check 不能替代真实 VPS、真实重启和真实客户端流量验证。

## 10. 完成标准

只有同时满足以下条件才允许提交和合并：

1. schema 迁移与回滚通过；
2. 端口跳跃不会绕过统计、配额或限速；
3. NAT 和 tc 规则只能修改 manager 自有对象；
4. reboot 后端口跳跃恢复且无重复；
5. 订阅服务无权读取服务端私钥；
6. 订阅自动更新且不提供陈旧敏感快照；
7. Raw、Base64、sing-box Profile 均通过真实客户端验证；
8. 订阅和 port-hop 服务故障不影响 sing-box；
9. SS2022、VLESS、普通 HY2、TUIC 全量回归通过；
10. Debian/Ubuntu/Alpine 首装、覆盖安装、恢复和卸载通过；
11. README、架构、数据模型、流量、事务和更新文档同步；
12. 仓库不含任何真实服务器数据、token、订阅 URL 或私钥。

## 11. 官方实现依据

- Hysteria2 Port Hopping：https://v2.hysteria.network/docs/advanced/Port-Hopping/
- Hysteria2 URI Scheme：https://v2.hysteria.network/docs/developers/URI-Scheme/
- sing-box Hysteria2 outbound：https://sing-box.sagernet.org/configuration/outbound/hysteria2/
- sing-box graphical client Remote Profile：https://sing-box.sagernet.org/clients/general/
- sing-box Shadowsocks outbound：https://sing-box.sagernet.org/configuration/outbound/shadowsocks/
- sing-box VLESS outbound：https://sing-box.sagernet.org/configuration/outbound/vless/
- sing-box TUIC outbound：https://sing-box.sagernet.org/configuration/outbound/tuic/
- sing-box TLS/SPKI Pin：https://sing-box.sagernet.org/configuration/shared/tls/
- sing-box route：https://sing-box.sagernet.org/configuration/route/
- tc flower port range：https://man7.org/linux/man-pages/man8/tc-flower.8.html
- Linux flow/NAT ordering：https://www.kernel.org/doc/html/v5.12/networking/nf_flowtable.html
- nftables hooks and tc ordering：https://netfilter.org/projects/nftables/manpage.html
