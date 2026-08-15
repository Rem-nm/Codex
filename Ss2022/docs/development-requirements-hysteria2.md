# Ss2022 增量开发需求：新增 Hysteria2 支持（整合定稿版）

## 〇、文档定位

本文是现有项目：

```text
Rem-nm/Codex/Ss2022/
```

新增 Hysteria2 支持的完整增量开发要求。

本文以当前最终版本的 Shadowsocks 2022 与 VLESS + REALITY + XTLS Vision 实现为基础，不是重写项目，也不得破坏已经稳定的功能。

本文确定以下不可擅自改变的设计：

1. 所有协议继续由一个 sing-box 进程统一运行。
2. Hysteria2 只是统一节点模型新增的一种协议，不建立第二套管理系统。
3. 三种协议共用全局配额策略，默认只按下载流量触发限额。
4. 所有节点的数字端口在节点数据库中全局唯一。
5. `nodes.json` 升级为 `schema_version: 3`。
6. Hysteria2 证书目录必须纳入状态事务、安装事务、备份、恢复和删除流程。
7. Hysteria2 `pinSHA256` 固定为叶子证书 DER 数据的 SHA-256，保存为 64 位小写、无分隔符十六进制字符串。
8. 未完成多系统实机测试并得到明确授权前，不提交或合并到 GitHub。

---

## 一、开发目标

当前支持：

```text
1. Shadowsocks 2022
2. VLESS + REALITY + XTLS Vision
```

新增后支持：

```text
1. Shadowsocks 2022
2. VLESS + REALITY + XTLS Vision
3. Hysteria2
```

必须保证现有以下能力继续正常工作：

- Shadowsocks 2022 节点管理；
- VLESS + REALITY + Vision 节点管理；
- 永久 Node ID；
- 节点名称自动去重；
- 流量统计和历史；
- 月流量限额；
- 每节点独立流量重置日；
- 上传和下载独立限速；
- 节点启用、停用与错误状态；
- 配置检查；
- 配置变更事务；
- 自动回滚；
- 配置备份与恢复；
- sing-box 安装、更新和修复；
- systemd 与 OpenRC；
- `rem` 统一管理菜单。

不得因为新增 Hysteria2 擅自重构已经稳定且无关的功能。

---

## 二、协议范围

Hysteria2 第一版只实现：

```text
单 UDP 端口
+ 自动生成认证密码
+ 自动生成每节点独立自签 TLS 证书
+ Certificate SHA-256 Pin
```

第一版不得新增：

- Hysteria 1；
- TUIC；
- Hysteria Realm；
- 端口跳跃；
- UDP 多端口；
- ACME；
- Let's Encrypt；
- Cloudflare DNS；
- 用户上传证书；
- 正式域名证书申请；
- Obfs；
- Masquerade；
- 自定义拥塞控制界面；
- 设备数量限制；
- 连接数量限制；
- 来源 IP 限制；
- 访问日志；
- 连接日志；
- 防火墙自动管理。

---

## 三、统一进程架构

继续使用：

```text
一个 sing-box 进程
```

统一管理全部启用节点：

```text
sing-box
├── Shadowsocks 2022
├── Shadowsocks 2022
├── VLESS REALITY Vision
├── VLESS REALITY Vision
├── Hysteria2
└── Hysteria2
```

不得创建：

```text
sing-box-hy2-1.service
sing-box-hy2-2.service
```

systemd 与 OpenRC 都必须继续只管理一个 sing-box 服务和一个 sing-box 主进程。

---

## 四、统一节点模型

现有协议判别值：

```text
protocol = shadowsocks
protocol = vless
```

新增：

```text
protocol = hysteria2
```

不得建立：

```text
hysteria2_nodes.json
hy2_traffic.json
hy2_history.json
```

继续使用：

- 统一 `nodes.json`；
- 统一 `traffic.json`；
- 统一 `traffic-history.json`；
- 统一状态系统；
- 统一备份系统；
- 统一回滚系统；
- 统一 tc 统计与限速系统。

---

## 五、永久 Node ID

继续沿用现有永久 Node ID。

以下操作不得改变 Node ID：

- 修改名称；
- 修改地址；
- 修改端口；
- 修改认证密码；
- 修改流量限额；
- 修改流量重置日；
- 修改上传或下载限速；
- 重新生成认证密码；
- 重新生成 TLS 证书；
- sing-box 重启；
- 服务器重启；
- manager 更新；
- 覆盖安装。

Hysteria2 inbound tag 继续基于 Node ID 生成：

```text
hy2-<node-id>
```

在按地址族生成多个 inbound 时，可以追加现有风格的地址族后缀：

```text
hy2-<node-id>-ipv4
hy2-<node-id>-ipv6
```

不得使用节点名称、端口或证书指纹作为永久身份。

---

## 六、公共字段

Hysteria2 复用现有公共节点字段：

```text
node_id
name
protocol
port
address
address_type
status
status_reason
quota_bytes
reset_day
upload_limit_mbps
download_limit_mbps
created_at
updated_at
last_reset_at
next_reset_at
```

流量数据继续按 Node ID 保存在统一流量文件中：

```text
current_upload_bytes
current_download_bytes
total_upload_bytes
total_download_bytes
upload_kernel_bytes
download_kernel_bytes
```

公共字段只能维护一份，不能在 Hysteria2 专属对象中复制。

---

## 七、协议公共元数据

三种协议必须通过一个公共协议元数据层描述：

```text
shadowsocks
├── label = SS2022
├── transports = [tcp, udp]
└── firewall_hint = TCP + UDP

vless
├── label = VLESS
├── transports = [tcp]
└── firewall_hint = TCP

hysteria2
├── label = HY2
├── transports = [udp]
└── firewall_hint = UDP
```

该元数据至少用于：

- 协议名称显示；
- 系统端口占用检查；
- sing-box 监听健康检查；
- tc filter 生成；
- bandwidth plan 校验；
- 防火墙提示；
- 节点详情中的网络类型。

不得在多个文件中散落互不一致的协议判断。

---

## 八、nodes.json Schema 3

新增 Hysteria2 后，节点数据库升级为：

```json
{
  "schema_version": 3,
  "nodes": []
}
```

Schema 3 继续使用严格的协议判别联合：

- `shadowsocks` 只允许公共字段、`method`、`password` 和 `protocol`；
- `vless` 只允许公共字段、UUID、Flow 和完整 Reality 字段；
- `hysteria2` 只允许公共字段、`password`、`tls_server_name`、`certificate_sha256` 和 `protocol`。

Hysteria2 节点示例：

```json
{
  "node_id": "a83fd82c4db84ba89a1f88f818723f52",
  "name": "Tokyo-HY2",
  "protocol": "hysteria2",
  "password": "URL-safe secure random password",
  "tls_server_name": "hy2-a83fd82c4db84ba89a1f88f818723f52.invalid",
  "certificate_sha256": "8bd2766ed3f3c82d59ec038657257a0d261198125027afe4c009c27c4b6e2a81",
  "port": 42851,
  "address": "198.51.100.10",
  "address_type": "ipv4",
  "status": "enabled",
  "status_reason": "",
  "quota_bytes": 0,
  "reset_day": 1,
  "upload_limit_mbps": 0,
  "download_limit_mbps": 0,
  "created_at": "UTC ISO-8601",
  "updated_at": "UTC ISO-8601",
  "last_reset_at": "UTC ISO-8601",
  "next_reset_at": "UTC ISO-8601"
}
```

以下固定事实不需要在节点数据库重复保存：

```text
tls_enabled = true
tls_type = self_signed
transport = udp
```

它们由 `protocol = hysteria2` 唯一决定。

---

## 九、证书路径

不允许节点数据库保存任意证书路径。

证书路径必须由 Node ID 固定推导：

```text
/etc/ss-manager/certs/<node-id>/cert.pem
/etc/ss-manager/certs/<node-id>/key.pem
```

例如：

```text
/etc/ss-manager/certs/a83fd82c4db84ba89a1f88f818723f52/
├── cert.pem
└── key.pem
```

这样可以防止：

- 路径穿越；
- JSON 中注入任意系统路径；
- 多节点误用同一私钥；
- 恢复时路径与 Node ID 不一致；
- 删除一个节点时误删其他节点文件。

---

## 十、旧数据迁移

必须支持：

```text
schema 1 → schema 3
schema 2 → schema 3
schema 3 → 直接使用
```

迁移规则：

### schema 1 → schema 3

旧 schema 1 只包含 SS2022 节点。

迁移时：

```text
schema_version = 3
每个旧节点增加 protocol = shadowsocks
```

不得改变其他任何节点字段。

### schema 2 → schema 3

旧 schema 2 已包含 SS2022 与 VLESS。

迁移时只修改：

```text
schema_version: 2 → 3
```

不得重写、补发或重新生成：

- Node ID；
- SS2022 密钥；
- VLESS UUID；
- Reality Private Key；
- Reality Public Key；
- Reality Short ID；
- Reality SNI；
- Reality 握手目标；
- 流量；
- 历史；
- 配额；
- 重置日；
- 限速；
- 状态。

### 迁移事务

迁移前必须自动保存：

- nodes；
- traffic；
- traffic history；
- manager state；
- 当前 sing-box 配置；
- 当前证书根目录存在/不存在状态。

迁移候选必须先通过：

- JSON 语义校验；
- 节点与流量关联校验；
- 完整 sing-box 配置检查。

迁移失败必须恢复原文件，不得留下半迁移状态。

---

## 十一、添加节点入口

执行：

```bash
rem
```

选择：

```text
添加节点
```

创建节点的第一项始终是：

```text
请输入节点名称：
>
```

然后显示：

```text
请选择协议：

1. Shadowsocks 2022
2. VLESS + REALITY + Vision
3. Hysteria2
>
```

选择 `1` 或 `2` 后，现有 SS2022/VLESS 用户体验必须保持不变。

---

## 十二、节点名称

Hysteria2 完全复用现有名称逻辑：

- 名称不能为空；
- 不允许控制字符；
- 不允许路径字符；
- 长度不得超过现有限制；
- 名称不区分大小写保持唯一；
- 重复名称自动选择最小可用编号。

例如已有：

```text
Tokyo
Tokyo-3
```

再次输入 `Tokyo` 时必须使用：

```text
Tokyo-2
```

---

## 十三、Hysteria2 创建流程

完整流程：

```text
输入节点名称
↓
选择 Hysteria2
↓
输入端口（回车随机）
↓
选择节点地址
↓
生成永久 Node ID
↓
自动生成独立认证密码
↓
根据 Node ID 生成稳定 TLS Server Name
↓
自动生成每节点独立自签证书和私钥
↓
验证证书、私钥、SAN、有效期
↓
计算叶子证书 DER SHA-256
↓
生成节点、流量和证书候选状态
↓
生成完整临时 sing-box 配置
↓
sing-box check
↓
建立持久事务和备份
↓
发布证书与配置
↓
重启并执行健康检查
↓
应用/检查 tc 规则
↓
提交节点数据库和流量状态
↓
显示 Hysteria2 URI、Base64 和二维码
```

创建过程不询问：

- 认证密码；
- 域名；
- TLS Server Name；
- 证书；
- TLS 私钥；
- Certificate Pin；
- 协议带宽；
- Obfs；
- Masquerade。

---

## 十四、端口交互

必须和现有协议保持一致：

```text
请输入端口（回车随机，范围 10000-60000）：
>
```

直接回车：

```text
[INFO] 已自动选择 UDP 端口：42851
```

手动输入：

```text
> 44321
```

则使用指定端口。

不得增加：

```text
1. 随机
2. 手动
```

这种二级选择。

---

## 十五、端口唯一性和系统占用检查

节点数据库中的数字端口必须在所有协议之间全局唯一。

例如已有：

```text
VLESS Tokyo → TCP 30001
```

即使 Hysteria2 使用 UDP，也不得再创建：

```text
Hysteria2 Osaka → UDP 30001
```

全局唯一用于保证：

- 节点身份与端口映射清晰；
- tc 统计和限速不会歧义；
- 备份恢复不会发生协议间端口复用；
- 列表、健康检查和故障报告容易定位。

系统外部 socket 占用检查按照协议传输类型执行：

```text
SS2022     → TCP 和 UDP 都必须可用
VLESS      → TCP 必须可用
Hysteria2  → UDP 必须可用
```

因此，一个不属于节点数据库的外部 TCP-only 服务占用某数字端口时，只要 UDP 空闲，Hysteria2 可以使用该数字端口；反之亦然。

还必须检查：

- 端口是整数；
- 范围为 `1-65535`；
- 随机端口位于现有全局随机范围；
- 未与任何现有节点冲突；
- 系统 UDP 监听查询成功；
- UDP 端口未被其他系统进程占用。

系统监听查询失败时必须停止操作，不能把查询失败视为端口空闲。

修改已启用节点且端口未变化时，必须确认该 UDP 监听由唯一的 sing-box 主进程持有。

---

## 十六、节点地址

Hysteria2 完全复用现有地址选择和校验逻辑：

```text
请输入节点地址（回车自动检测公网 IPv4，失败后尝试 IPv6；输入 ipv6 可自动检测公网 IPv6；也可直接输入 IP/域名）：
>
```

必须支持：

- 自动检测公网 IPv4；
- 自动检测公网 IPv6；
- 手动 IPv4；
- 手动 IPv6；
- 手动域名；
- 默认值处理；
- 输入规范化；
- 错误重试；
- IPv6 URI 方括号；
- 客户端地址与监听地址分离。

不得复制开发另一套 Hysteria2 地址交互。

---

## 十七、Hysteria2 认证密码

每个 Hysteria2 节点自动生成独立密码。

密码要求：

- 使用密码学安全随机源；
- 默认使用 32 个随机字节；
- 编码为 Base64URL；
- 移除 `=` padding；
- 不包含冒号；
- 不包含空格、控制字符、路径字符；
- 适合安全写入 JSON 和 URI userinfo；
- 不得出现在外部进程参数和普通日志中。

禁止使用：

- 固定默认密码；
- 时间戳；
- Node ID 直接充当密码；
- 简单数字；
- shell `RANDOM`；
- 可预测伪随机字符串。

数据库语义校验应防止多个 Hysteria2 节点静默共用同一密码。发生极低概率随机碰撞时必须重新生成。

---

## 十八、自签 TLS 证书

Hysteria2 第一版固定：

```text
TLS = enabled
证书类型 = self-signed
```

每个 Hysteria2 节点必须拥有独立：

- 认证密码；
- TLS Certificate；
- TLS Private Key；
- TLS Server Name；
- Certificate SHA-256 Pin。

不得默认让多个 Hysteria2 节点共用同一 TLS 私钥或证书。

证书必须包含：

- 与节点保存值一致的 Subject Alternative Name；
- 能被项目支持的 OpenSSL 与 sing-box 正确解析的密钥；
- SHA-256 签名；
- 合理的长期有效期。

固定使用兼容性稳定的 ECDSA P-256 自签证书，有效期为 3650 天。节点详情必须显示证书起止时间；距离过期不足 30 天时可以提示管理员，但不得自动轮换证书。

---

## 十九、TLS Server Name

用户不输入 TLS Server Name。

固定生成规则：

```text
hy2-<完整node-id>.invalid
```

例如：

```text
hy2-a83fd82c4db84ba89a1f88f818723f52.invalid
```

要求：

- 创建后保存在节点数据库；
- 在所有节点之间唯一；
- 写入自签证书 SAN；
- 服务端 TLS 配置使用同一个值；
- 客户端 URI 的 `sni` 使用同一个值；
- restart、update、改名、改端口时不得改变；
- 不需要 DNS 解析；
- 不使用用户真实域名。

---

## 二十、证书目录与权限

固定权限：

```text
/etc/ss-manager/                       700
/etc/ss-manager/certs/                 700
/etc/ss-manager/certs/<node-id>/       700
cert.pem                               600
key.pem                                600
```

证书和私钥必须：

- 由 root 所有；
- 是常规文件；
- 不能是符号链接；
- 不能是硬链接到目录外的敏感文件；
- 不能由普通用户写入；
- 在配置生成、备份和恢复前重新检查类型、所有权和权限。

TLS Private Key 不得出现在：

- 普通节点列表；
- 普通节点详情；
- Hysteria2 URI；
- Base64；
- 二维码；
- 状态页；
- 普通成功信息；
- GitHub；
- 普通诊断日志。

---

## 二十一、Certificate Pin

`certificate_sha256` 固定表示：

```text
叶子证书 DER 编码内容的 SHA-256
```

数据库保存格式：

```text
64 个字符
小写
十六进制
无冒号
无短横线
```

示例：

```text
8bd2766ed3f3c82d59ec038657257a0d261198125027afe4c009c27c4b6e2a81
```

计算过程：

```text
cert.pem
↓ 解析证书
DER leaf certificate
↓ SHA-256
64 位小写十六进制
```

不得使用：

- PEM 文本文件本身的 SHA-256；
- TLS Private Key 的 SHA-256；
- SPKI 公钥摘要；
- sing-box 客户端字段 `certificate_public_key_sha256` 的 Base64 值；
- CA 证书摘要；
- 证书链中非叶子证书摘要。

以下操作必须重新计算实际证书 Pin，并与数据库字段交叉校验：

- 配置生成；
- 节点详情；
- 分享链接生成；
- 备份；
- 恢复；
- 覆盖安装；
- manager 启动状态校验；
- 重新生成证书。

不一致时必须停止操作，不得静默覆盖数据库或重新生成证书。

---

## 二十二、证书生命周期

证书和密码属于节点长期身份数据。

以下操作不得重新生成证书、私钥、密码或 Pin：

- sing-box restart；
- 服务器 restart；
- manager restart；
- manager update；
- sing-box update；
- 覆盖安装；
- 修改名称；
- 修改端口；
- 修改节点地址；
- 修改限额；
- 修改重置日；
- 修改限速；
- 启用或停用节点；
- 备份；
- 恢复。

证书接近过期时可以在节点详情和系统检查中提示，但不得自动轮换。

---

## 二十三、手动重新生成密码与证书

修改 Hysteria2 节点时提供：

```text
重新生成认证密码
重新生成 TLS 证书
```

重新生成密码前必须提示：

```text
重新生成认证密码后，现有客户端节点配置将立即失效，
需要重新获取分享链接或重新扫描二维码。

是否继续？
```

重新生成证书前必须提示：

```text
重新生成 TLS 证书后，证书 SHA-256 Pin 将改变，
现有客户端保存的证书指纹将失效，
需要重新获取分享链接或重新扫描二维码。

是否继续？
```

用户明确确认后才能继续。

重新生成证书必须一次性更新：

- TLS Private Key；
- TLS Certificate；
- Certificate SHA-256；
- 证书有效期信息。

TLS Server Name 和 Node ID 保持不变。

---

## 二十四、sing-box Hysteria2 Inbound

配置生成器根据：

```text
protocol = hysteria2
```

生成 Hysteria2 inbound。

基础结构：

```json
{
  "type": "hysteria2",
  "tag": "hy2-<node-id>",
  "listen": "::",
  "listen_port": 42851,
  "users": [
    {
      "name": "<node-id>",
      "password": "<password>"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "hy2-<node-id>.invalid",
    "certificate_path": "/etc/ss-manager/certs/<node-id>/cert.pem",
    "key_path": "/etc/ss-manager/certs/<node-id>/key.pem"
  }
}
```

实际字段必须按照项目当前受管 sing-box 版本的官方配置格式生成，并通过该二进制的 `sing-box check`。

第一版不得写入：

- `obfs`；
- `masquerade`；
- `realm`；
- 端口跳跃；
- 自定义 QUIC 参数；
- `tcp_fast_open`。

---

## 二十五、协议带宽参数

Hysteria2 自身存在协议带宽与拥塞控制相关参数，但本项目已经有统一 tc 限速系统。

第一版 Hysteria2 inbound：

- 不提供协议带宽输入界面；
- 不写入用户可调 `up_mbps`；
- 不写入用户可调 `down_mbps`；
- 不写入 `ignore_client_bandwidth`；
- 不建立第二套 Hysteria2 限速配置。

用户只通过：

```text
rem
→ 上传 / 下载限速
```

管理节点限速。

---

## 二十六、一个配置管理全部节点

最终配置必须由统一生成器遍历所有启用节点：

```text
for 每个 enabled 节点：
    shadowsocks → Shadowsocks inbound
    vless       → VLESS REALITY Vision inbound
    hysteria2   → Hysteria2 TLS inbound
```

最终只生成：

```text
/etc/sing-box/config.json
```

节点停用时，只从配置中移除该 Node ID 对应 inbound，不停止其他节点。

现有 IPv4、IPv6、双栈和 `bindv6only` 监听逻辑必须继续复用。

---

## 二十七、配置变更事务

Hysteria2 的添加、修改、删除、启停、密码轮换和证书轮换必须遵守现有安全事务原则。

候选阶段：

```text
准备候选节点数据
↓
准备候选流量和历史
↓
准备候选证书状态
↓
校验证书、私钥、SAN 和 Pin
↓
生成完整临时 sing-box 配置
↓
sing-box check
```

检查失败：

```text
不修改正式证书
不修改正式配置
不提交节点数据库
不修改流量数据库
不影响现有节点
```

检查成功后：

```text
创建完整备份
↓
建立持久状态事务
↓
原子发布证书变更
↓
再次生成/检查最终路径配置
↓
应用正式配置
↓
快速 restart
↓
健康检查
↓
应用和检查 tc
↓
提交 nodes / traffic / history
↓
验证证书状态和运行状态
↓
标记 committed
```

失败时：

```text
恢复证书目录
↓
恢复旧 sing-box 配置
↓
恢复 nodes / traffic / history
↓
恢复 tc 规则和计数基线
↓
恢复 sing-box 原运行状态
↓
验证旧节点全部恢复
```

---

## 二十八、证书状态事务

状态事务必须记录：

- 操作涉及的 Hysteria2 Node ID；
- 操作前证书目录存在或不存在；
- 操作前证书和私钥副本；
- 操作前证书文件摘要；
- 操作前 Certificate Pin；
- 候选证书目录；
- 事务阶段；
- sing-box 原运行状态。

新建或轮换证书时：

- 在 `/etc/ss-manager/` 同一文件系统内创建受保护的临时目录；
- 禁止在不受保护的共享 `/tmp` 中保存私钥；
- 发布时使用同文件系统原子目录移动或等价安全方式；
- 候选目录和最终目录都必须验证不是符号链接。

删除节点时：

- 先备份并建立事务；
- 先应用不包含该 inbound 的配置并验证其他节点；
- 再删除对应 Node ID 的证书目录；
- 删除失败时事务必须回滚；
- 不得使用未校验通配符删除证书目录。

状态事务日志格式需要扩展，同时继续能够识别没有证书字段的旧事务日志。

---

## 二十九、安装与覆盖安装事务

安装、修复、覆盖安装和 manager 更新事务必须把：

```text
/etc/ss-manager/certs/
```

作为完整受保护目标。

安装前记录：

- 证书根目录存在或不存在；
- 完整目录树；
- 所有权；
- 文件权限；
- 文件类型；
- 证书和私钥内容；
- 目录持久化状态。

安装失败时恢复原证书目录，不能只恢复 `nodes.json`。

覆盖安装成功后必须验证：

- 所有 Hysteria2 密码不变；
- 所有证书字节不变；
- 所有私钥字节不变；
- 所有 Pin 不变；
- 所有 TLS Server Name 不变；
- 原客户端仍可连接。

---

## 三十、健康检查

应用 Hysteria2 配置后至少检查：

- sing-box 服务状态正常；
- 唯一 sing-box 主进程存在；
- 运行配置可通过 `sing-box check`；
- 每个 SS2022 节点所需 TCP/UDP 监听仍存在；
- 每个 VLESS 节点所需 TCP 监听仍存在；
- 每个 Hysteria2 节点所需 UDP 监听仍存在；
- 监听 socket 由唯一 sing-box 主进程持有；
- 新节点所需地址族监听存在；
- 原有节点监听没有异常消失；
- tc 规则与节点 transport 一致；
- 证书文件与数据库 Pin 一致。

Hysteria2 不得使用 TCP `connect()` 作为监听健康检查。

UDP socket 存在只证明服务已监听，不证明完整客户端握手成功。因此实机验收必须额外使用兼容客户端完成 Hysteria2 握手和代理流量测试。

---

## 三十一、分享 URI

主要输出标准：

```text
hysteria2://
```

允许兼容解析：

```text
hy2://
```

标准输出格式：

```text
hysteria2://<url-encoded-password>@<host>:<port>/?sni=<url-encoded-sni>&insecure=1&pinSHA256=<64-lowercase-hex>#<url-encoded-name>
```

要求：

- 密码作为 userinfo 并正确 URL 编码；
- 密码生成时不包含冒号，避免被解释为 `username:password`；
- IPv6 地址使用方括号；
- `sni` 使用节点保存的稳定 TLS Server Name；
- `insecure=1`；
- `pinSHA256` 使用节点实际叶子证书摘要；
- 节点名称正确 URL 编码；
- 不增加带宽、客户端模式或其他非标准参数。

---

## 三十二、Base64 与二维码

Hysteria2 继续提供：

```text
1. 标准 Hysteria2 URI
2. 标准 URI 的 Base64
3. 终端二维码
```

Base64 只是完整标准 URI 的编码形式，不替代原始 URI。

二维码直接编码标准 Hysteria2 URI。

二维码生成必须通过标准输入传递 URI，不得把认证密码放入其他用户可观察的进程命令行。

---

## 三十三、创建成功显示

创建成功后显示：

```text
Hysteria2 节点创建成功

名称：Tokyo-HY2
Node ID：xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
协议：Hysteria2

地址：1.2.3.4
端口：42851 / UDP

认证密码：xxxxxxxxxxxxxxxx

TLS：Self-Signed
SNI：hy2-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.invalid
Certificate SHA256：xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
证书有效期：...

网络：QUIC / UDP
```

然后显示 URI、Base64 和二维码。

不得显示 TLS Private Key。

---

## 三十四、统一节点列表

不得拆分协议列表。

统一显示：

```text
名称            协议       端口     上传       下载       合计       限额       状态
Tokyo-SS        SS2022     58227    12 GB      106 GB     118 GB     500 GB     运行中
Tokyo-VLESS     VLESS      35128    10 GB       72 GB      82 GB     500 GB     运行中
Tokyo-HY2       HY2        42851    18 GB      144 GB     162 GB     500 GB     运行中
```

协议只是节点的一项属性。

---

## 三十五、节点详情

Hysteria2 节点详情显示：

- 名称；
- Node ID；
- 协议；
- 状态；
- 服务器地址；
- UDP 端口；
- 认证密码；
- TLS 类型：Self-Signed；
- TLS Server Name；
- Certificate SHA-256；
- 证书有效期；
- 本周期上传；
- 本周期下载；
- 本周期合计；
- 当前配额计费值；
- 累计上传；
- 累计下载；
- 累计合计；
- 月流量限额；
- 流量重置日；
- 上传限速；
- 下载限速；
- 下次重置时间。

不得显示：

- TLS Private Key；
- 私钥内容摘要；
- 非必要内部证书路径。

---

## 三十六、修改 Hysteria2 节点

支持修改：

```text
1. 名称
2. 端口
3. 节点地址
4. 月流量限额
5. 流量重置日
6. 上传 / 下载限速
7. 重新生成认证密码
8. 重新生成 TLS 证书
0. 返回
```

修改名称、端口、地址、配额、重置日或限速时：

- Node ID 不变；
- 密码不变；
- TLS Server Name 不变；
- 证书不变；
- 私钥不变；
- Certificate Pin 不变。

身份变更完成后自动显示新的链接和二维码；显示失败不得回滚已经健康提交的节点，但必须给出重新查看入口。

---

## 三十七、删除节点

Hysteria2 与其他协议共用删除入口。

删除前显示：

```text
节点名称
协议
UDP 端口
Node ID
```

并要求确认。

删除某个 Hysteria2 Node ID 时只移除：

- 该 Node ID 的 inbound；
- 该节点数据库记录；
- 该节点当前流量状态；
- 根据用户选择处理该节点历史；
- 该 Node ID 的证书目录。

不得影响：

- 其他 Hysteria2；
- SS2022；
- VLESS；
- 其他节点证书；
- 其他节点流量；
- 其他节点限速。

删除前创建的安全备份必须包含该节点证书，以便回滚和人工恢复。

---

## 三十八、节点启用与停用

继续使用统一状态：

```text
enabled
disabled_manual
disabled_quota
disabled_error
```

Hysteria2 不新增专属状态字段。

停用节点：

- 从生成配置中移除对应 inbound；
- 保留节点数据；
- 保留密码；
- 保留证书和私钥；
- 保留流量和历史；
- 保留限额和限速。

重新启用时不得重新生成任何身份数据。

---

## 三十九、流量统计

Hysteria2 必须纳入现有 Node ID 流量系统。

客户端视角：

```text
上传：
客户端 → Hysteria2 服务器 → Internet

下载：
Internet → Hysteria2 服务器 → 客户端
```

tc 规则使用 UDP：

```text
上传 = ingress dst_port=node.port
下载 = egress  src_port=node.port
```

继续统一显示和保存：

- 本周期上传；
- 本周期下载；
- 本周期合计；
- 累计上传；
- 累计下载；
- 累计合计；
- 内核计数基线；
- 周期历史。

不得建立第二套 Hysteria2 流量数据库。

端口层计数包含 UDP/QUIC 和链路开销，也可能包含未通过认证的数据包，不得描述为认证用户的精确账单。

---

## 四十、全局配额策略

SS2022、VLESS 与 Hysteria2 共用同一个 manager 全局配额策略。

默认：

```text
billable_bytes = current_download_bytes
```

因此：

- 上传、下载、合计全部统计；
- 上传、下载、合计全部显示；
- 上传、下载、合计全部归档；
- 默认只有下载流量用于自动判断限额。

管理员明确启用现有全局上传计费开关后，三种协议统一改为：

```text
billable_bytes =
current_upload_bytes
+
current_download_bytes
```

不得：

- 为 Hysteria2 单独固定上传加下载；
- 为单个节点建立独立计费方向；
- 修改 SS2022/VLESS 的默认策略；
- 把端口统计描述为认证账单。

达到限额时：

```text
status = disabled_quota
```

只停用对应 Node ID 的 inbound，不停止整个 sing-box。

---

## 四十一、独立流量重置日

Hysteria2 完全复用现有规则：

```text
每节点独立设置 1-28 日
默认 1 日
```

到重置日：

```text
归档上一周期
↓
本周期上传归零
↓
本周期下载归零
↓
更新 last_reset_at
↓
更新 next_reset_at
```

状态恢复：

```text
disabled_quota  → 自动恢复 enabled
disabled_manual → 保持停用
disabled_error  → 保持停用
```

服务器离线跨过多个周期时继续使用现有补结算逻辑。

---

## 四十二、上传与下载限速

Hysteria2 复用：

```text
upload_limit_mbps
download_limit_mbps
```

`0` 表示不限速。

tc transport 映射：

```text
SS2022     → [tcp, udp]
VLESS      → [tcp]
Hysteria2  → [udp]
```

现有 bandwidth plan 校验必须允许：

```json
["udp"]
```

不能继续假设每个协议 transport 列表的第一项一定是 TCP。

修改一个 Hysteria2 节点限速不得影响其他协议或节点。

---

## 四十三、备份

新备份必须包含：

- `nodes.json`；
- `traffic.json`；
- `traffic-history.json`；
- `manager.json`；
- 当前 sing-box 配置；
- 受管 sing-box 二进制（按现有规则）；
- 完整 Hysteria2 证书目录；
- 证书清单和文件摘要。

备份格式需要扩展，但必须继续识别不包含 Hysteria2 的旧备份。

如果备份的节点数据包含 Hysteria2，则备份必须具备：

```text
certs/<node-id>/cert.pem
certs/<node-id>/key.pem
```

并验证：

- 节点与证书目录一一对应；
- 没有额外不属于 Hysteria2 节点的私钥目录；
- 证书与私钥匹配；
- SAN 与 TLS Server Name 一致；
- 实际 Pin 与节点字段一致；
- 文件不是符号链接；
- 权限和所有权安全。

缺少任一必要证书或私钥时拒绝发布备份。

---

## 四十四、恢复

恢复顺序：

```text
验证备份
↓
升级旧 nodes schema 候选
↓
验证节点、流量、历史和证书关联
↓
建立当前状态恢复事务
↓
恢复证书目录
↓
生成并检查完整 sing-box 配置
↓
恢复 nodes / traffic / history
↓
恢复配置
↓
恢复 tc
↓
恢复 sing-box 运行状态
↓
健康检查
```

恢复 Hysteria2 时禁止重新生成：

- 认证密码；
- TLS Server Name；
- TLS Certificate；
- TLS Private Key；
- Certificate Pin。

恢复后原客户端配置必须继续可用。

---

## 四十五、rem 主菜单

主菜单继续统一：

```text
REM Proxy Manager

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
13. 更新
14. 备份与恢复
15. 系统设置
16. 卸载

0. 退出
```

不得新增：

```text
SS 管理
VLESS 管理
HY2 管理
```

三个独立顶级菜单。

---

## 四十六、防火墙

继续保持：

```text
本项目不修改服务器防火墙、云安全组或现有安全策略。
```

不得自动修改：

- iptables；
- nftables；
- UFW；
- firewalld；
- ipset；
- 云厂商安全组。

Hysteria2 创建完成后提示：

```text
请确认服务器防火墙及云厂商安全组已经放行：

UDP <端口>
```

---

## 四十七、安全要求

必须保证：

- 所有私钥和密码文件默认权限为 600；
- 所有私密目录默认权限为 700；
- 敏感值不出现在外部命令参数；
- 敏感值不写入普通日志；
- JSON 通过结构化生成，不通过字符串拼接；
- URI 所有用户输入字段正确编码；
- 证书路径由 Node ID 推导；
- 操作前拒绝符号链接和特殊文件；
- 删除目标经过绝对路径和 Node ID 校验；
- 事务候选文件只存放在受保护目录；
- GitHub 不包含真实密码、证书私钥、真实节点配置、服务器 IP、域名、流量或备份。

---

## 四十八、项目范围

所有代码和文档修改只能发生在：

```text
Rem-nm/Codex/Ss2022/
```

不得修改同仓库的其他项目。

不得上传：

- 真实 Hysteria2 密码；
- 真实 TLS Private Key；
- 真实节点证书；
- 真实节点 IP；
- 用户域名；
- VPS 登录信息；
- 流量数据；
- 服务器备份；
- 实机测试产生的运行配置。

---

## 四十九、开发原则

公共功能优先复用：

```text
公共节点层
├── Node ID
├── 名称
├── 地址
├── 端口
├── 状态
├── 流量
├── 配额
├── 重置
├── 限速
├── 备份
└── 回滚

协议层
├── Shadowsocks 2022
│   ├── method
│   └── password
│
├── VLESS REALITY Vision
│   ├── UUID
│   ├── Reality KeyPair
│   ├── Short ID
│   ├── SNI
│   └── Handshake
│
└── Hysteria2
    ├── password
    ├── TLS Server Name
    ├── certificate
    ├── private key
    └── certificate pin
```

不得复制三份公共逻辑。

不得为了抽象而大规模重写已经稳定的事务、流量、限速或平台兼容模块；应以小步增量方式扩展现有边界。

---

## 五十、开发前复核

开始修改前必须重新完整读取：

- 当前 `nodes.json` 数据模型；
- schema 1/2 迁移逻辑；
- 节点语义校验；
- 协议选择和创建流程；
- sing-box 配置生成；
- IPv4/IPv6 监听生成；
- 端口占用检查；
- sing-box PID 与 socket 所有权检查；
- 流量采样；
- bandwidth plan；
- 状态事务；
- 安装事务；
- 备份和恢复；
- 更新和覆盖安装；
- SS2022/VLESS 分享链接；
- systemd/OpenRC 服务逻辑；
- 全部现有测试。

不得在未理解现有完整事务边界时直接加入证书文件写入。

---

## 五十一、必须完成的测试

### 测试 1：schema 1 迁移

使用旧 SS2022-only 数据升级。

验证：

- Node ID 不变；
- 名称不变；
- 端口不变；
- 密钥不变；
- 流量不变；
- 历史不变；
- 限额不变；
- 限速不变；
- 状态不变。

### 测试 2：schema 2 迁移

使用已有 SS2022 + VLESS 数据升级。

验证全部 SS/VLESS 凭据和运行状态不变。

### 测试 3：创建 Hysteria2 随机端口

直接回车，生成有效且全局唯一 UDP 端口。

### 测试 4：创建 Hysteria2 手动端口

输入指定端口，正确创建。

### 测试 5：节点数据库端口冲突

尝试使用已有 SS2022 或 VLESS 数字端口创建 Hysteria2，必须拒绝，即使另一传输层 socket 当前空闲。

### 测试 6：系统 UDP 端口冲突

已有外部 UDP 服务占用时必须拒绝。

### 测试 7：外部 TCP-only 同号端口

外部服务只占 TCP、UDP 空闲且节点数据库没有该端口时，Hysteria2 可以使用对应 UDP 端口。

### 测试 8：节点地址

验证 IPv4、IPv6、域名、自动检测和默认行为与 SS2022 完全一致。

### 测试 9：多协议混合运行

同一个 sing-box 同时运行多个：

```text
SS2022
VLESS REALITY Vision
Hysteria2
```

### 测试 10：标准分享

验证 URI、Base64 和二维码能够被明确支持 Hysteria2 的客户端正确导入。

### 测试 11：正确 Certificate Pin

`insecure=1 + pinSHA256` 能够连接。

### 测试 12：错误 Certificate Pin

修改 Pin 后必须无法通过证书验证。

### 测试 13：Pin 算法

验证保存值严格等于叶子证书 DER SHA-256，且不是 PEM 或 SPKI 摘要。

### 测试 14：restart 稳定性

重启 sing-box 和服务器后：

- 密码不变；
- 证书不变；
- 私钥不变；
- Pin 不变；
- TLS Server Name 不变。

### 测试 15：修改端口

端口改变，但 Node ID、密码、证书、私钥、Pin 和 SNI 不变。

### 测试 16：重新生成密码

旧客户端失效，新链接可用，证书和 Pin 不变。

### 测试 17：重新生成证书

新证书、私钥和 Pin 生效；旧链接失效；Node ID、密码和 SNI 不变。

### 测试 18：流量统计

分别验证上传、下载、合计和重启后持久化。

### 测试 19：默认配额

默认只按下载触发限额；上传仍统计但不单独导致停用。

### 测试 20：全局上传计费开关

打开后 SS2022、VLESS、Hysteria2 全部统一按上传加下载触发限额。

### 测试 21：配额停用

达到限额只停对应 Hysteria2 inbound，其他节点继续运行。

### 测试 22：自动恢复

到节点结算日后，`disabled_quota` 自动恢复；手动/错误停用不恢复。

### 测试 23：上传和下载限速

Hysteria2 UDP-only tc 规则正确，且不影响其他节点。

### 测试 24：节点停用与启用

停用后证书和密码保留；重新启用不重新生成身份。

### 测试 25：备份恢复

创建节点并备份，然后重新生成密码和证书，再恢复旧备份。

验证原密码、证书、私钥、Pin 和旧客户端连接全部恢复。

### 测试 26：删除隔离

删除一个 Hysteria2 节点只删除该 Node ID 的证书目录，不影响其他节点。

### 测试 27：非法配置

故意生成非法 Hysteria2 参数，`sing-box check` 失败时正式状态不变。

### 测试 28：证书发布后启动失败

模拟证书已发布但 sing-box 启动失败，必须自动恢复旧证书、配置、数据库和服务。

### 测试 29：崩溃恢复

在证书发布、配置切换、服务重启、数据库提交等阶段模拟进程退出或断电，下一次启动必须根据持久日志恢复一致状态。

### 测试 30：覆盖安装

覆盖安装后所有现有 SS2022、VLESS、Hysteria2 数据与连接保持不变。

### 测试 31：sing-box 更新

更新前后验证当前配置兼容；不兼容时停止更新并保持旧二进制和全部节点。

### 测试 32：权限与路径攻击

验证符号链接、特殊文件、错误所有权、错误权限、路径穿越和额外证书目录都会被拒绝。

### 测试 33：防火墙行为

确认项目只提示 UDP 端口，不主动修改任何防火墙。

### 测试 34：多系统实机

至少测试：

- Debian 11；
- Debian 12；
- Ubuntu；
- Alpine/OpenRC；
- IPv4-only；
- IPv6/双栈；
- systemd；
- OpenRC；
- 全新安装；
- 已安装覆盖修复。

---

## 五十二、提交前要求

完成开发后必须：

1. 运行全部既有 SS2022 测试；
2. 运行全部既有 VLESS 测试；
3. 运行新增 Hysteria2 自动化测试；
4. 在多系统 VPS 上进行真实客户端连接测试；
5. 测试覆盖安装；
6. 测试备份恢复；
7. 测试故障和崩溃恢复；
8. 复核没有真实服务器数据进入仓库；
9. 复核所有修改都位于 `Ss2022/`；
10. 获得用户明确授权后才能提交、推送或合并 GitHub。

---

## 五十三、最终创建体验

```text
请输入节点名称：
> Tokyo

请选择协议：

1. Shadowsocks 2022
2. VLESS + REALITY + Vision
3. Hysteria2
> 3

请输入端口（回车随机，范围 10000-60000）：
>

[INFO] 已自动选择 UDP 端口：42851

请输入节点地址（回车自动检测公网 IPv4，失败后尝试 IPv6；输入 ipv6 可自动检测公网 IPv6；也可直接输入 IP/域名）：
>

[INFO] 正在生成 Hysteria2 认证密码……
[OK] 已生成。

[INFO] 正在生成每节点独立自签 TLS 证书……
[OK] 已生成。

[INFO] 正在验证证书、私钥和 Certificate Pin……
[OK] 验证通过。

[INFO] 正在检查完整 sing-box 配置……
[OK] 配置有效。

[INFO] 正在应用配置并执行健康检查……
[OK] Hysteria2 UDP 监听正常。
```

成功后显示节点信息、标准 URI、Base64、二维码和 UDP 防火墙提示。

---

## 五十四、最终架构

```text
                         rem
                          │
                    统一节点系统
                          │
       ┌──────────────────┼──────────────────┐
       │                  │                  │
 Shadowsocks 2022    VLESS REALITY       Hysteria2
   TCP + UDP          Vision / TCP        QUIC / UDP
       │                  │                  │
       └──────────────────┼──────────────────┘
                          │
                     一个 sing-box
                          │
             ┌────────────┼────────────┐
             │            │            │
           流量         全局配额       tc 限速
             │            │            │
             └────────────┼────────────┘
                          │
                     永久 Node ID
                          │
                  nodes schema 3
                          │
                统一备份 / 持久事务
                          │
                Hysteria2 证书目录
```

核心要求：

> Hysteria2 只是现有统一节点系统新增的一种协议。

> 三种协议继续使用一个 sing-box、一个节点数据库、一套流量、配额、限速、备份和回滚系统。

> 配额默认只按下载触发；上传、下载、合计仍全部统计、展示和归档。

> 节点端口全局唯一，但系统 socket 占用检查按协议实际 transport 执行。

> Hysteria2 使用 UDP / QUIC，端口检查、健康检查、流量和 tc 规则必须按 UDP 处理。

> 密码、证书和私钥每节点独立，创建后保持稳定。

> Certificate Pin 使用叶子证书 DER SHA-256 的 64 位小写无分隔符十六进制格式。

> 证书文件是事务状态的一部分，任何失败都必须与配置、数据库和服务一起恢复。

> 第一版只实现稳定的单端口 Hysteria2，不擅自加入端口跳跃、Obfs、Masquerade、Realm、ACME 或其他扩展。
