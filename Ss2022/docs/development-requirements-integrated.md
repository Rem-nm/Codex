# Ss2022 增量开发需求（统一整合版）

## 文档定位

本文是以下内容的唯一整合版本：

1. 原 Shadowsocks 2022 项目开发需求；
2. VLESS + REALITY + XTLS Vision 增量需求；
3. 针对现有 Ss2022 1.0.20 稳定实现所做的兼容性修订。

后续实现、测试和评审以本文为准。本文明确写出的兼容性条款优先于原文档中与其冲突的表述。

稳定性优先级保持为：

~~~
稳定性
  >
数据一致性
  >
安全性
  >
可恢复性
  >
易用性
  >
新增功能数量
~~~

本需求是增量开发，不是重写项目。除非本文明确要求，现有 Shadowsocks 2022 的行为、数据格式语义、事务边界和用户体验不得改变。

---

## 一、项目目标和范围

项目目录继续使用：

~~~
Rem-nm/Codex/Ss2022/
~~~

所有代码、脚本、默认配置、文档和测试只能位于该目录内，不得修改仓库其他项目。

现有项目继续支持：

- Shadowsocks 2022；
- 多节点、多端口、一节点一端口；
- 一个 sing-box 进程统一管理全部节点；
- 节点增删改、启用/停用；
- Node ID 关联的流量统计、流量历史和独立重置日；
- 全局配额策略下的节点限额；
- 节点上传/下载限速；
- 配置检查、应用、备份、恢复和自动回滚；
- sing-box 更新和版本锁定；
- manager 更新；
- rem 管理菜单。

新增且只新增以下协议模式：

- VLESS；
- REALITY；
- XTLS Vision；
- 固定 flow：xtls-rprx-vision；
- 固定安全模式：reality；
- 固定传输：TCP。

第一版明确不实现：

- VLESS + WS；
- VLESS + gRPC；
- VLESS + HTTPUpgrade；
- VLESS + 普通 TLS；
- VLESS + CDN；
- VLESS + ACME；
- 证书申请和证书管理；
- 防火墙或云安全组管理；
- 设备数、连接数、来源 IP 限制；
- 访问日志、连接日志、DNS 历史和目标网站历史。

不得设计一个节点一个 sing-box 进程，也不得增加按节点拆分的 sing-box 服务。

---

## 二、支持系统、架构和运行时边界

继续支持当前项目已经覆盖的系统：

- Debian 11；
- Debian 12；
- Ubuntu；
- CentOS；
- AlmaLinux；
- Alpine Linux（OpenRC）。

优先支持：

- x86_64 / amd64；
- arm64 / aarch64。

系统和架构不受支持时，必须在修改系统前明确退出。

初始化系统按实际环境选择：

- systemd：sing-box.service、流量维护 service/timer；
- Alpine OpenRC：sing-box、流量维护 service。

依赖由当前系统包管理器安装。已存在的命令不得重复安装。软件源失败时不得覆盖用户的 APT 配置；应使用当前项目已有的安全兼容路径或明确退出。

BBR 和 TCP Fast Open 继续遵守现有行为：

- 已启用时不重复修改；
- 内核支持时才启用；
- 内核不支持时只提示，不升级内核；
- sing-box 配置字段必须先通过实际版本能力检查；
- 能力不支持时跳过对应优化，不得因此破坏节点安装。

只提高 sing-box 服务自身的文件描述符限制。不得对无关系统服务进行大范围 sysctl 或资源限制修改。

项目不会自动修改或放行 iptables、nftables、UFW、firewalld、ipset、云厂商安全组或其他安全策略。

---

## 三、现有 Shadowsocks 2022 兼容性合同

新增 VLESS 后，现有 Shadowsocks 2022 必须继续满足：

- 原 Node ID 不变；
- 原名称、端口、地址、地址类型不变；
- 原 method 和 password 不变；
- 原当前/累计流量和历史不变；
- 原限额、重置日、上下行限速和状态不变；
- 原节点仍能在一个 sing-box 进程中运行；
- 原 SIP002 URI、Base64 和终端二维码继续可用；
- 原 ss-<node_id> inbound tag 保持不变；
- 原备份、恢复、升级和卸载行为继续成立；
- 原事务失败时不提交半成品状态。

新增协议选择会插入在名称之后，但用户选择 Shadowsocks 2022 后，后续现有流程不改变：

~~~
名称
↓
协议选择
↓
Shadowsocks 加密方式
↓
端口
↓
节点地址
↓
自动生成密码
↓
配置检查
↓
应用和健康检查
↓
显示 SS URI、Base64、二维码
~~~

“保持 SS2022 体验不变”指协议分支确定后的流程不变，不要求新增协议选择前的旧菜单顺序继续隐藏协议。

---

## 四、统一节点架构

Shadowsocks 2022 和 VLESS 必须使用同一个节点数据库：

~~~
/var/lib/ss-manager/nodes.json
~~~

不得建立 ss_nodes.json、vless_nodes.json 或两套独立管理菜单。

节点是统一实体，协议只是节点属性。

### 4.1 公共节点字段

每个节点必须具有：

- node_id
- name
- protocol
- port
- address
- address_type
- status
- status_reason
- quota_bytes
- reset_day
- upload_limit_mbps
- download_limit_mbps
- created_at
- updated_at
- last_reset_at
- next_reset_at

流量值继续单独保存于：

~~~
/var/lib/ss-manager/traffic.json
~~~

流量、基线和累计值通过 node_id 关联，不得同时写入两个可变数据源。

### 4.2 协议字段

Shadowsocks 节点增加或保留：

- method
- password

VLESS 节点必须保存：

- uuid
- flow，固定为 xtls-rprx-vision
- reality_private_key
- reality_public_key
- reality_short_id
- reality_server_name
- reality_handshake_server
- reality_handshake_port

可将 security、network、fingerprint 作为协议常量，不必重复存储；若存储，必须使用严格固定值：

- security = reality
- network = tcp
- fingerprint = chrome

### 4.3 Schema

新增协议后节点文件使用 schema_version: 2。每个节点根据 protocol 使用判别联合校验：

- protocol: shadowsocks 时必须有 SS 字段，禁止 VLESS 专属字段；
- protocol: vless 时必须有完整 VLESS 字段，禁止 SS password/method 字段；
- 公共字段必须完整、类型正确、取值合法；
- Node ID、名称和端口的全局唯一性继续校验；VLESS UUID、Reality private/public key 和 Short ID 也必须分别保持节点间唯一，防止恢复或异常候选数据让多个节点共用身份。

traffic、history、interfaces、bandwidth-plan 的现有 schema 和语义尽量保持不变；只有确有必要时才升级其 schema，并提供旧文件迁移。

第一版不允许直接把一个已创建节点从 SS 转换为 VLESS，或从 VLESS 转换为 SS。若以后支持转换，必须另行定义凭据、流量、分享链接和回滚语义。

---

## 五、Node ID、名称和 inbound tag

Node ID 必须永久唯一，使用现有小写十六进制格式。

以下操作不得改变 Node ID：

- 修改名称；
- 修改端口；
- 修改地址或地址类型；
- 修改 SS 加密方式或密码；
- 修改 VLESS UUID；
- 重新生成 Reality KeyPair；
- 重新生成 Reality Short ID；
- 修改限额、重置日或限速。

名称继续使用现有唯一化规则：

- Tokyo 已存在时生成 Tokyo-2；
- 已有 Tokyo、Tokyo-3 时优先生成 Tokyo-2；
- 使用最小可用编号；
- 名称最长 64 个字符；
- 名称不得包含控制字符、路径字符或换行。

tag 规则：

- 现有 Shadowsocks 节点继续使用 ss-<node_id>；
- 新 VLESS 节点使用 vless-<node_id>；
- family-specific 模式下可以追加 -ipv4、-ipv6；
- 不能因为新增 VLESS 而重命名或迁移旧 SS tag；
- tag 永远不能基于名称或端口。

---

## 六、协议传输和端口模型

| 项目 | Shadowsocks 2022 | VLESS Reality Vision |
|---|---|---|
| sing-box inbound | shadowsocks | vless |
| 公网传输 | TCP + UDP | TCP |
| TLS/安全 | 无额外 TLS | REALITY |
| Flow | 不适用 | xtls-rprx-vision |
| 服务器端秘密 | password（同时供客户端使用） | Reality private key |
| 客户端所需凭据 | method + password | UUID + Reality public key + Short ID + SNI |
| tc 传输匹配 | TCP + UDP | TCP |
| 端口占用检查 | TCP 和 UDP | TCP |

这个差异是协议实现差异，不是两套节点系统。

### 6.1 端口唯一性

SS 和 VLESS 共用同一端口空间：

- 任意两个节点不得使用相同端口；
- VLESS 与现有 SS 端口冲突时必须拒绝；
- 端口范围为 1-65535；
- 随机端口继续使用当前默认范围 10000-60000；
- 不得覆盖其他服务的必要监听。

系统监听检查按节点协议的实际传输集合执行：

- SS 新建/修改时检查 TCP 和 UDP；
- VLESS 新建/修改时检查 TCP；
- 数据库冲突检查对两种协议始终相同；
- 查询失败必须 fail closed，不得猜测端口空闲。

节点编辑保留自己原有的监听端口时，只能在确认相应传输监听均属于唯一的项目 sing-box 进程后放行。

### 6.2 端口交互

两种协议都直接输入端口：

~~~
请输入端口（回车随机，范围 10000-60000）：
>
~~~

空回车时自动选择有效随机端口，并明确显示最终端口：

~~~
已自动选择端口：42851
~~~

手动输入时校验数字、范围、节点冲突和系统监听冲突。发现冲突不得强行覆盖。

### 6.3 地址交互

两种协议复用同一地址选择逻辑：

~~~
请输入节点地址（回车自动检测公网 IPv4；输入 ipv6 可自动检测公网 IPv6）：
>
~~~

规则：

- 空回车：自动检测公网 IPv4，失败后尝试 IPv6；
- 输入 ipv6：自动检测公网 IPv6；
- 输入 IPv4、IPv6 或域名：直接校验并保存；
- IPv6 分享链接必须加方括号；
- 客户端地址与 sing-box bind 地址分开处理；
- 未检测到公网地址时允许用户手动输入；
- 不得把客户端地址直接当作唯一监听地址。

在 family-specific 模式下，域名节点可以生成两个同端口的 TCP inbound；两个 inbound 属于同一个 Node ID，使用同一份协议凭据。

---

## 七、创建节点流程

### 7.1 统一入口

执行 rem 的“添加节点”或首次安装创建首节点时：

~~~
请输入节点名称：
>

请选择协议：
1. Shadowsocks 2022
2. VLESS + REALITY + Vision
>
~~~

名称始终是第一步。名称冲突时自动使用最小可用后缀。

### 7.2 Shadowsocks 2022 分支

选择 1 后继续使用现有流程：

~~~
请选择加密方式：
1. 2022-blake3-aes-128-gcm
2. 2022-blake3-aes-256-gcm（默认）
>

请输入端口（回车随机，范围 10000-60000）：
>

请输入节点地址（回车自动检测公网 IPv4；输入 ipv6 可自动检测公网 IPv6）：
>
~~~

密码由安全随机源生成，不允许人工输入弱密码。

### 7.3 VLESS 分支

选择 2 后执行：

~~~
请输入端口（回车随机，范围 10000-60000）：
>

请输入节点地址（回车自动检测公网 IPv4；输入 ipv6 可自动检测公网 IPv6）：
>

请输入 Reality Server Name / SNI：
>

请输入 Reality 握手目标（域名或域名:端口）：
>
~~~

随后自动生成：

- UUID；
- Reality private key；
- Reality public key；
- Reality short ID。

不询问 flow、security、fingerprint、UUID、KeyPair 或 Short ID。

固定值：

- flow = xtls-rprx-vision
- security = reality
- network = tcp
- 分享链接指纹 fp = chrome

生成临时完整 sing-box 配置，依次执行：

~~~
字段校验
↓
sing-box check
↓
事务备份
↓
配置切换
↓
快速 restart（若服务原本运行）
↓
协议传输和全节点健康检查
↓
提交节点、流量和历史数据
↓
显示 VLESS URI、Base64 和二维码
~~~

任一步失败都不得提交新节点。

---

## 八、VLESS Reality 参数和 sing-box 配置

服务器端 VLESS inbound 应使用官方支持的结构，核心形态为：

~~~
{
  "type": "vless",
  "tag": "vless-<node_id>",
  "listen": "0.0.0.0",
  "listen_port": 32581,
  "users": [
    {
      "uuid": "<uuid>",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "<reality_server_name>",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "<reality_handshake_server>",
        "server_port": 443
      },
      "private_key": "<reality_private_key>",
      "short_id": [
        "<reality_short_id>"
      ]
    }
  }
}
~~~

最终字段必须以实际安装版本的 sing-box 官方 schema 为准；不得因为文档示例而加入版本不支持的字段。

官方 VLESS inbound 支持用户 UUID 和 xtls-rprx-vision flow；Reality 服务器需要 handshake、private key 和 short ID。参考：

- https://sing-box.sagernet.org/configuration/inbound/vless/
- https://sing-box.sagernet.org/configuration/shared/tls/#reality-fields

### 8.1 KeyPair 和 Short ID

UUID 和 Reality KeyPair 使用目标 sing-box 二进制提供的能力；Short ID 使用已作为项目依赖的 OpenSSL CSPRNG 生成，避免不同 sing-box 版本对 `generate rand` 参数顺序解析不一致：

~~~
sing-box generate uuid
sing-box generate reality-keypair
openssl rand -hex 8
~~~

命令输出必须通过受保护的标准输入、临时文件或内存变量处理，不能把 private key 放到外部命令参数或日志中。

每个 VLESS 节点独立生成 UUID、KeyPair 和 Short ID，不得默认共用。

reality_public_key 必须与 reality_private_key 成对对应。恢复和导入时必须校验二者一致，不能悄悄重新生成。

### 8.2 SNI 校验

SNI 必须：

- 非空；
- 是 DNS 名称；
- 使用 IDNA/punycode 规范化；
- 不包含路径、端口、控制字符或 shell 元字符；
- 不允许把未经校验的文本直接拼入 JSON；
- 第一版不接受 IP 作为 Reality SNI。

### 8.3 握手目标校验

握手目标允许：

- example.com，默认端口 443；
- example.com:8443；
- 明确约定格式的 IPv6 地址和端口（IPv6 必须使用方括号）。

必须拆分保存：

- reality_handshake_server
- reality_handshake_port

必须校验 Host、端口和整体格式。应对 DNS/TCP/TLS 可达性进行检查或警告；可达性失败时不能伪造“运行正常”，但是否阻止创建要由实现明确一致地决定。

---

## 九、VLESS 分享链接、Base64 和二维码

VLESS 分享必须是标准 URI，不得创造私有参数。目标格式至少包含：

~~~
vless://<uuid>@<host>:<port>?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&sni=<sni>&fp=chrome&pbk=<reality_public_key>&sid=<short_id>#<node_name>
~~~

要求：

- type=tcp；
- encryption=none；
- security=reality；
- flow=xtls-rprx-vision；
- sni；
- fp=chrome；
- pbk 为 Reality public key；
- sid 为 Reality short ID；
- fragment 为 URL 编码后的节点名称；
- 所有参数值必须进行 URL 编码；
- IPv6 地址必须用方括号；
- 不得出现 Reality private key。

URI 字段和兼容性应以目标客户端矩阵进行验证，至少覆盖项目实际声明支持的客户端。不能仅凭字符串拼接成功就宣称所有客户端兼容。

Base64 为完整标准 VLESS URI 的无换行 Base64 表示，不替代原始 URI。

二维码直接编码完整标准 URI，并通过现有 qrencode 终端输出逻辑显示。

SS 继续使用现有 SIP002 URI、Base64 和二维码逻辑。

---

## 十、节点列表、详情、修改和分享显示

### 10.1 统一列表

不得拆分 SS 列表和 VLESS 列表。统一列表至少显示：

~~~
名称       协议       端口     本周期     限额     状态
Tokyo-SS   SS2022     58227    118GB      500GB    运行中
Tokyo-VL   VLESS      35128     82GB      500GB    运行中
~~~

协议标签只表示节点属性，不改变公共管理入口。

### 10.2 详情

公共字段继续显示：

- 名称；
- Node ID；
- 协议；
- 状态；
- 地址；
- 端口；
- 本周期上传、下载、合计；
- 累计上传、下载、合计；
- 月流量限额；
- 重置日；
- 上传和下载限速；
- 下次重置时间。

VLESS 额外显示：

- UUID；
- Flow；
- Reality SNI；
- Reality 握手目标；
- Reality Public Key；
- Short ID。

不得显示 Reality private key。private key 只能存在于受保护的节点数据库、运行配置、安装/状态事务和备份中。

### 10.3 修改

公共修改项继续支持：

- 名称；
- 端口；
- 地址；
- 月流量限额；
- 重置日；
- 上传限速；
- 下载限速。

SS 专属修改项：

- 加密方式；
- 密码；
- 复制同算法节点密钥。

VLESS 专属修改项：

- Reality SNI；
- Reality 握手目标；
- UUID；
- Reality KeyPair；
- Reality Short ID。

重新生成 UUID、KeyPair 或 Short ID 前必须明确提示：

~~~
重新生成后，现有客户端配置将失效，需要重新导入。
~~~

并要求用户确认。Node ID、流量、限额、重置日和限速不能因此改变。

### 10.4 删除和状态

删除前显示名称、协议和端口并要求确认。

删除一个 VLESS Node ID 时，只移除该 Node ID 派生的全部 inbound、tc action、流量关联和节点记录；不得影响其他 VLESS、SS 或整个 sing-box。

节点状态继续使用：

- enabled
- disabled_manual
- disabled_quota
- disabled_error

不得为 VLESS 增加第二套状态字段。

---

## 十一、统一流量统计、配额和重置

### 11.1 统计数据源

VLESS 和 SS 共用 traffic.json，按 Node ID 独立记录：

- 当前上传；
- 当前下载；
- 当前合计（显示值，不重复存储也可以）；
- 累计上传；
- 累计下载；
- tc action 基线；
- 配额和结算时间关联。

重启 sing-box、服务器重启和 manager 更新不得清空已持久化统计。

统计仍按客户端视角：

- 上传：客户端 → 服务器 → Internet；
- 下载：Internet → 服务器 → 客户端。

Linux ingress/egress 方向必须通过端口和传输方向正确映射，不能直接把内核方向名称当作用户方向。

### 11.2 全局配额策略（已确认）

SS2022 和 VLESS 共用现有 manager 全局配额策略，不按协议拆分。

默认策略：

~~~
计费值 = current_download_bytes
~~~

因此默认仅按下载触发限额。上传、下载、合计必须始终统计、显示和归档。

如果管理员明确启用现有全局选项：

~~~
quota_include_unauthenticated_upload = true
~~~

则所有协议统一使用：

~~~
计费值 = current_upload_bytes + current_download_bytes
~~~

不得让 VLESS 单独使用“上传+下载”而 SS 使用“仅下载”。

达到配额时：

~~~
节点状态 → disabled_quota
节点 inbound 从运行配置移除
保留节点数据库、协议凭据、流量和历史
不停止其他节点或整个 sing-box
~~~

“保留配置”指保留节点记录和凭据，不指停用节点仍必须出现在运行中的 inbound 配置。

### 11.3 独立重置日

每节点独立重置日范围 1-28，默认 1。

结算时：

~~~
归档上一周期
↓
当前上传归零
↓
当前下载归零
↓
更新 last_reset_at
↓
更新 next_reset_at
~~~

disabled_quota 在该节点的新周期自动恢复；disabled_manual 和 disabled_error 不自动恢复。

维护任务必须基于 last_reset_at 和 next_reset_at 补执行错过的结算，不要求恰好在零点运行。

---

## 十二、节点限速和 tc 规则

限速继续由 Linux tc 实现，不创造 sing-box 私有限速字段：

- 上传和下载分别设置；
- 单位 Mbps；
- 0 表示不限速；
- 每个 Node ID 和方向使用独立、可证明归属的 action；
- 修改一个节点不得影响其他节点；
- 规则变更必须纳入事务并可回滚；
- 继续支持当前实际默认路由接口和地址族探测。

规则方向：

- 上传：匹配节点入口的目标端口；
- 下载：匹配节点出口的源端口。

传输规则按节点协议生成：

- SS：每个地址族的 TCP 和 UDP；
- VLESS：每个地址族的 TCP；
- VLESS 的 UDP/XUDP 数据通过 TCP 传输，因此计入 VLESS TCP 端口的统计和限速；
- VLESS 不得因为没有独立 UDP listener 而被健康检查或 tc 校验错误判定为缺失。

bandwidth-plan 必须记录节点传输集合或等价可重建信息；旧版只含 SS 的计划迁移时默认解释为 TCP+UDP。

tc 能力探测也要区分：

- SS 仍验证 TCP/UDP；
- VLESS 至少验证 TCP；
- 不能因为目标系统没有 IPv6 filter 能力而破坏 IPv4-only 主机的已支持行为。

---

## 十三、配置生成、事务、应用和健康检查

所有新增、删除、修改、启停、限额和限速操作继续使用现有统一状态事务：

~~~
读取当前有效状态
↓
构造候选节点、流量、历史和完整 sing-box 配置
↓
验证节点 schema 和交叉引用
↓
sing-box 官方配置检查
↓
创建备份和持久事务快照
↓
写入候选配置
↓
如果服务原本运行，执行快速 restart
↓
按协议传输集合执行健康检查
↓
应用 tc 规则并验证所有权、数量和 handle
↓
重置候选 tc 基线
↓
原子提交节点、流量和历史
↓
最终健康检查
↓
写入 committed 并清理事务
~~~

配置检查失败时：

- 不修改正式配置；
- 不重启 sing-box；
- 不提交节点数据库；
- 不改变现有节点；
- 给出明确错误。

### 13.1 reload 规则

现有项目继续使用快速 restart。不能把 HUP 或未经验证的命令称为可靠 reload。

只有目标 sing-box 版本提供官方支持且经过实际能力探测、事务测试和回滚测试的 reload，才允许未来作为优化；本增量需求不强制实现 reload。

### 13.2 用户主动停止服务

如果事务开始前用户已经手动停止 sing-box：

- 候选配置仍必须通过 sing-box check；
- 不要求进程和监听端口存在；
- 不得擅自启动 sing-box；
- 提交后继续保持停止状态；
- 重新启动服务时再执行完整协议传输健康检查。

### 13.3 健康检查

对所有启用节点验证：

- 服务状态正确；
- 唯一 sing-box 主进程存在；
- 当前配置可被官方 parser 读取；
- SS 节点预期 TCP 和 UDP listener 存在且属于该进程；
- VLESS 节点预期 TCP listener 存在且属于该进程；
- 原有节点的监听没有意外消失；
- tc 规则和 action 仍与候选节点集合一致。

仅判断 systemctl restart 返回 0 不算健康检查通过。

VLESS 还应使用至少一个实际兼容客户端进行端到端握手测试；仅有监听端口不能证明 Reality 参数正确。

失败时：

~~~
恢复旧配置
↓
恢复旧节点、流量和历史状态
↓
恢复旧 tc 规则和基线
↓
恢复服务原运行状态
↓
再次健康检查
~~~

---

## 十四、旧数据迁移和备份恢复

### 14.1 旧节点迁移

现有 schema_version: 1 的 SS 节点必须自动迁移为 schema 2：

~~~
protocol = shadowsocks
~~~

必须保留：

- Node ID；
- 名称；
- 端口；
- 地址和地址类型；
- method；
- password；
- 当前和累计流量；
- 历史；
- 配额；
- 重置日；
- 上传/下载限速；
- 状态和状态原因；
- 所有时间字段。

不得要求删除旧节点、重新创建节点、重新生成密码或重置流量。

### 14.2 迁移事务顺序

旧 schema 校验必须允许已知的旧格式，但不能把任意损坏 JSON 当成可迁移。

正确顺序：

~~~
识别旧 schema
↓
建立安装/更新事务快照
↓
保存 nodes、traffic、history、manager、sing-box 配置
↓
生成 schema 2 候选文件
↓
校验节点和流量交叉引用
↓
校验完整候选 sing-box 配置
↓
原子提交
~~~

迁移发生在事务快照之后。迁移失败、进程中断、断电或回滚时，必须恢复旧 schema 文件。

### 14.3 备份兼容

常规备份和安装事务快照必须能够保存：

- schema 2 的 SS/VLESS 节点；
- VLESS UUID；
- Reality private/public key；
- Short ID；
- SNI；
- handshake；
- flow；
- traffic/history；
- sing-box config；
- 必要的 manager 状态。

恢复旧 schema 1 备份时，先在候选文件中迁移为 schema 2，再通过正常状态事务应用；原备份不得被改写。

恢复 VLESS 节点时不得重新生成 UUID、KeyPair 或 Short ID，确保原客户端配置继续有效。

包含 private key 的文件和目录继续使用 root 所有、目录 700、敏感文件 600。

---

## 十五、sing-box 和 manager 更新

sing-box 只从 SagerNet/sing-box 官方 GitHub Release 获取：

- HTTPS；
- 官方地址校验；
- SHA256 校验；
- 临时文件下载；
- 完整归档检查；
- 配置检查；
- 健康检查；
- 失败自动恢复旧二进制和配置。

manager 只从 Rem-nm/Codex 官方 Release 获取，并继续使用当前项目的归档校验和持久更新事务。

manager 新程序切换后、更新事务提交前，必须使用新程序对当前 schema 1/2 节点执行不迁移、不提交状态的预检：生成完整候选配置并调用当前受管 sing-box 检查。预检只允许在受保护的运行目录创建候选文件，不得创建、改权或迁移永久配置/数据目录；检测到仍需完整安装事务迁移的旧 traffic 状态时拒绝 manager-only 更新。已有 VLESS 节点时还必须验证 UUID、Reality KeyPair 和 Short ID 的实际生成/校验能力；预检失败恢复旧 manager。

更新后必须重新验证：

- SS 配置仍可加载；
- VLESS Reality 配置字段仍被目标 sing-box 支持；
- UUID 和 Reality KeyPair 生成命令仍可用；
- SS 和 VLESS 混合配置可同时运行。

如果用户锁定的 sing-box 版本不支持 VLESS 所需能力：

- 不得自动解除版本锁；
- 不得修改现有 SS 节点；
- 创建/修改 VLESS 时给出明确提示；
- 用户升级到支持版本后才允许 VLESS 操作。

---

## 十六、主菜单和首次安装

主菜单保持统一，不增加“SS 管理”和“VLESS 管理”两个大菜单：

~~~
================================
       REM Proxy Manager
================================
Sing-box：运行中
节点数量：5
本周期总流量：328.6 GB

1. 添加节点
2. 删除节点
3. 修改节点
4. 查看节点
5. 节点详细信息
6. 显示节点链接 / 二维码
7. 启用 / 停用节点
8. 流量统计
9. 流量限额
10. 流量重置
11. 上传 / 下载限速
12. Sing-box 管理
13. 更新管理
14. 备份与恢复
15. 系统设置
16. 卸载
0. 退出
~~~

首次安装：

~~~
检查 root
↓
识别系统和架构
↓
补齐依赖
↓
安装/验证 sing-box
↓
创建程序、配置、数据和备份目录
↓
安装服务和 rem
↓
直接进入首节点创建
~~~

不得询问“是否创建节点”。首节点创建失败时，不得把不完整节点提交为成功；安装后可以重新从首节点流程继续。

重复运行安装脚本必须幂等：

- 不覆盖节点；
- 不重置密码；
- 不清空流量或历史；
- 不重复创建第二个 sing-box 进程；
- 不静默接管外部配置或外部服务；
- 已有 VLESS 节点时，用安装选择的 sing-box 和本机安全随机源复核 UUID、Reality KeyPair、Short ID 生成/校验能力；
- 失败后保留事务证据并自动恢复。

---

## 十七、权限、输入和日志安全

所有输入必须校验：

- shell 命令注入；
- 路径注入；
- JSON 注入；
- 控制字符；
- 非法端口；
- 非法 IPv4/IPv6；
- 非法域名；
- URL 编码破坏；
- 不安全的 handshake 格式。

构造 JSON 必须使用 jq 或等价结构化工具，不得直接拼接未经转义的用户输入。

Reality private key 不得出现在：

- 普通节点列表；
- 普通节点详情；
- VLESS URI；
- Base64；
- 二维码；
- 普通成功提示；
- 普通错误日志；
- 外部命令参数；
- GitHub 或测试 fixture。

只有用户明确请求显示链接/二维码时，才显示该节点的客户端公开凭据。VLESS private key 永远不作为客户端分享凭据显示。

项目不开发访问日志、目标网站日志、来源 IP 历史或连接历史。systemd/journald 和 OpenRC 系统日志只用于必要的服务故障排查。

---

## 十八、卸载

继续提供三种模式：

1. 仅删除程序，保留节点、流量、历史、配置和备份；
2. 删除程序和运行配置，保留备份；
3. 完全卸载项目创建的程序、服务、sing-box、rem、节点、流量、历史和备份。

所有模式：

- 只清理本项目可证明归属的 tc 规则；
- 不删除用户已有防火墙规则；
- 不删除外部 sing-box 配置或服务；
- 无法证明所有权时停止并提示。

---

## 十九、测试和验收

实现完成后必须执行自动测试、离线 fixture 测试和至少一个真实 Linux 环境测试。

### 19.1 SS 回归

- 旧 schema 1 SS 数据迁移；
- Node ID、password、流量、历史、配额、限速、状态全部不变；
- SS TCP+UDP listener 健康检查；
- SS URI、Base64、二维码；
- 名称最小后缀；
- 端口冲突和地址选择；
- 增删改、启停、限额、重置日和限速；
- 备份恢复；
- sing-box 更新和失败回滚；
- 用户主动停止服务后的事务行为。

### 19.2 VLESS 创建和混合运行

- 首节点选择 VLESS；
- 已有 SS 后添加 VLESS；
- 多个 VLESS 和多个 SS 同时运行在一个 sing-box 服务；
- VLESS 使用随机端口；
- VLESS 使用手动端口；
- VLESS 与 SS 端口冲突拒绝；
- UDP 被其他程序占用但 TCP 空闲时，VLESS 按 TCP 传输规则处理；
- VLESS 地址选择复用 SS；
- SNI、handshake 格式和注入校验；
- UUID、KeyPair、Short ID 每节点独立；
- 重启后凭据不变；
- VLESS TCP listener 健康检查；
- SS UDP listener 不因 VLESS 缺失而被错误要求。

### 19.3 分享和端到端

- VLESS URI 包含 type=tcp、encryption=none、security=reality、flow、sni、fp、pbk、sid；
- IPv4、IPv6、域名 URI 都正确编码；
- Base64 解码后等于标准 URI；
- 二维码编码标准 URI；
- 使用至少一个 Xray/V2Ray 兼容客户端和一个 sing-box 客户端测试真实握手；
- Reality private key 不出现在所有客户端分享输出。

### 19.4 流量、限额和限速

- SS/VLESS 均按 Node ID 统计；
- VLESS TCP 上承载的 XUDP 流量计入该节点；
- 上传、下载、合计显示正确；
- 默认仅下载触发限额；
- 开启全局上传计费后，SS/VLESS 都按上传+下载；
- 不得出现按协议不同的配额规则；
- 达限额只停对应节点；
- 重置日自动归档和恢复；
- VLESS 上传/下载限速不影响 SS；
- SS 上传/下载限速不影响 VLESS。

### 19.5 事务、恢复和升级

- 非法 VLESS 配置在 sing-box check 阶段拒绝；
- 旧 SS 在非法 VLESS 候选失败后保持运行；
- 模拟应用后启动失败时自动回滚；
- tc 规则部分失败时自动回滚；
- 断电/SIGKILL 后持久事务恢复；
- VLESS 创建、修改 UUID/KeyPair、备份、恢复后旧凭据可用；
- schema 1 → schema 2 迁移失败恢复旧文件；
- 更新到不支持 VLESS 的锁定 sing-box 时不改动 SS。

### 19.6 平台

- Debian 11；
- Debian 12；
- Ubuntu；
- CentOS/AlmaLinux；
- Alpine OpenRC；
- amd64；
- arm64；
- IPv4-only；
- IPv6-capable；
- 用户手动停止 sing-box；
- /run 空间较小；
- 已存在外部 sing-box 配置或服务。

---

## 二十、实现边界和推荐模块划分

这是对现有模块的增量扩展，不得把项目重写为无法审计的单体脚本。

公共逻辑继续放在现有模块：

- 节点名称、Node ID、端口、地址；
- 状态、流量、限额、重置日和限速；
- 事务、备份、恢复；
- 服务管理；
- 更新和卸载。

协议专属逻辑建议集中封装：

- SS：method、password、SIP002；
- VLESS：UUID、Reality KeyPair、Short ID、SNI、handshake、VLESS URI。

配置生成器根据 protocol 选择 inbound 生成器，但最终输出仍是一个完整配置和一个 sing-box 服务。

建议增加或拆分的公共抽象：

- node_protocol()
- node_transport_protocols()
- node_expected_listeners()
- node_share_uri()
- validate_node_protocol_fields()
- migrate_nodes_schema_v1_to_v2()

所有新函数必须继续使用现有：

- root 权限检查；
- manager lock；
- 原子 JSON 写入；
- 持久事务日志；
- 备份和回滚；
- fail closed；
- secret 不进入命令参数。

---

## 二十一、GitHub 与服务器数据隔离

GitHub 只保存：

- 源代码；
- 安装脚本；
- 默认配置；
- VERSION；
- README；
- 文档；
- 测试；
- Release 文件。

严禁提交：

- 服务器真实 IP；
- 用户域名；
- SS password；
- VLESS UUID；
- Reality private/public key；
- 实际 sing-box 配置；
- traffic.json；
- 流量历史；
- 私有备份；
- 安装事务或运行日志。

测试 fixture 只能使用文档保留地址、假 UUID、假密钥和假域名。

---

## 二十二、最终验收标准

以下条件全部满足才算完成：

1. 原有 SS2022 用户升级后无需删除节点或重新生成密码；
2. 旧 Node ID、流量、历史、限额、限速和状态全部保持；
3. SS 和 VLESS 在同一个 sing-box 进程中混合运行；
4. VLESS 只实现 TCP + REALITY + XTLS Vision；
5. SS 继续要求 TCP+UDP，VLESS 只要求 TCP；
6. 两种协议共用节点数据库、流量数据库、配额策略和事务系统；
7. 默认配额仍只按下载触发；
8. 上传、下载、合计始终统计、展示和归档；
9. VLESS private key 永不进入普通分享输出；
10. 配置、tc、服务、备份和恢复失败均能自动回滚；
11. 用户主动停止的 sing-box 不被事务擅自启动；
12. 更新、卸载、幂等安装和外部服务所有权保护不回退；
13. 只修改 Rem-nm/Codex/Ss2022/；
14. 测试覆盖旧数据迁移、混合运行、分享、流量、限额、限速、回滚和多平台。
