# Ss2022 增量开发需求：新增 TUIC 支持（按现有项目校准版）

## 1. 目标与边界

在现有 `Ss2022/` 中新增第四种协议 `tuic`，不重写项目，不建立第二套节点、流量、服务、证书或菜单体系。最终由一个 sing-box 进程同时管理：

1. Shadowsocks 2022（TCP + UDP）
2. VLESS + REALITY + Vision（TCP）
3. Hysteria2（QUIC/UDP）
4. TUIC v5（QUIC/UDP）

TUIC 第一版只实现单节点、单 UDP 端口、自签 TLS 模式，不实现 0-RTT 开关、端口跳跃、多用户共享端口、ACME、正式证书上传、自动防火墙、连接/设备限制或访问日志。

## 2. 与现有稳定策略的最终对齐

原始需求中以下内容必须按当前项目已经生效的全局约束执行：

- 配额：四种协议共用 manager 的全局配额策略。默认仅以本周期下载量触发限额；上传、下载和合计始终全部统计、展示和归档。只有管理员开启现有全局上传计费开关后，四种协议才统一按上传加下载触发，不为 TUIC 建立例外。
- 端口：Node ID 数据库中的数字端口跨协议全局唯一。即使一个协议只用 TCP、另一个只用 UDP，也不能让两个节点复用同一数字端口。系统外部监听占用检查则按实际传输执行，TUIC 只查 UDP。
- schema：新增 TUIC 后节点数据库为 schema 4。schema 1 增加 `protocol:"shadowsocks"` 后升到 4；schema 2/3 只提升顶层版本；迁移前必须备份，失败恢复原文件。
- TLS：HY2 与 TUIC 共用同一 TLS Manager 和 `/etc/ss-manager/certs/<node-id>/`，证书候选目录与节点候选配置在同一状态事务中发布或回滚。
- Pin：`certificate_sha256` 固定表示整张叶证书 DER 数据的 SHA-256，使用 64 位小写无分隔符十六进制；不是 SPKI/public-key digest。
- URI：通用 TUIC v5 URI 使用客户端已实现的 `uuid:password`、`congestion_control`、`alpn`、`sni`、`allow_insecure` 和 `udp_relay_mode`。当前没有跨客户端可移植的 TUIC certificate-pin URI 参数，因此不得把 HY2 的 `pinSHA256` 擅自复制成 TUIC 标准参数。Pin 必须在凭据页单独显示、在服务端状态和备份恢复中严格校验。

## 3. 统一节点模型

TUIC 继续使用公共字段：

- `node_id`、`name`、`protocol`
- `port`、`address`、`address_type`
- `status`、`status_reason`
- `quota_bytes`、`reset_day`
- `upload_limit_mbps`、`download_limit_mbps`
- 创建、修改和结算时间字段

TUIC 专属字段严格为：

```json
{
  "protocol": "tuic",
  "uuid": "UUID",
  "password": "base64url-safe random secret",
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls_server_name": "tuic-<node-id>.invalid",
  "certificate_sha256": "64 lowercase hex"
}
```

`certificate_path`、`private_key_path` 和 `tls_enabled` 不保存到节点 JSON：TLS 必须启用，路径由 Node ID 唯一推导。这样可避免路径注入，也不会把固定事实重复存储。

Node ID、名称和端口全局唯一；VLESS/TUIC UUID 跨两种协议唯一；TUIC password 在 TUIC 节点中唯一；所有 HY2/TUIC TLS SNI 和 pin 唯一。修改名称、地址、端口、流量、限速、服务或 manager/sing-box 更新都不得改变 Node ID、UUID、Password、证书或 Pin。

## 4. 创建与修改交互

添加节点仍以名称为第一项：

```text
请输入节点名称：
>
请选择协议：
1. Shadowsocks 2022
2. VLESS + REALITY + Vision
3. Hysteria2
4. TUIC
```

选择 TUIC 后：

```text
端口（留空随机）
→ 公共节点地址选择
→ 自动 UUID
→ 自动 Password
→ 自动独立自签证书/私钥
→ 计算叶证书 DER SHA-256
→ 完整候选配置检查
→ 状态事务、运行健康检查和提交
→ URI、Base64、二维码
```

端口和地址必须直接复用现有公共函数。TUIC 的系统端口冲突与健康检查只按 UDP/QUIC，不使用 TCP connect。

TUIC 修改菜单支持：

- 名称、端口、节点地址
- 月限额、重置日、上传/下载限速
- 一次性重新生成 UUID + Password
- 重新生成 TLS 证书

重置认证或证书前必须提示旧客户端立即失效并要求确认；Node ID 始终不变。

## 5. sing-box 配置

每个启用 TUIC 节点生成一个或按现有地址族策略生成两个 inbound，tag 基于永久 Node ID：

```text
tuic-<node-id>
tuic-<node-id>-ipv4
tuic-<node-id>-ipv6
```

TUIC inbound 必须包含官方字段：

```json
{
  "type": "tuic",
  "listen": "0.0.0.0",
  "listen_port": 20000,
  "users": [{"uuid": "...", "password": "..."}],
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": "tuic-<node-id>.invalid",
    "alpn": ["h3"],
    "certificate_path": "/etc/ss-manager/certs/<node-id>/cert.pem",
    "key_path": "/etc/ss-manager/certs/<node-id>/key.pem"
  }
}
```

配置必须与所有 SS/VLESS/HY2/TUIC 节点一起生成并通过当前受管 sing-box 的官方 `check`，不能只校验 TUIC 片段。

## 6. TLS Manager

公共 TLS Manager 负责：

- 按协议和 Node ID 推导稳定 SNI
- 生成 ECDSA P-256 自签叶证书和私钥
- 校验 root/目录/文件类型、root 所有权、700/600 权限和硬链接数
- 校验证书可解析、私钥可解析、证书与私钥公钥匹配、SAN 匹配、自签链成立
- 计算并比对叶证书 DER SHA-256
- 创建、发布、删除证书候选目录
- 在安装事务、状态事务、备份和恢复中保存完整证书树
- 拒绝符号链接、外来文件、额外证书目录和无节点关联的孤儿私钥

普通节点修改不得轮换证书；只有用户明确选择“重新生成 TLS 证书”时才允许改变 Pin。

## 7. 分享信息

TUIC v5 URI：

```text
tuic://<url-encoded-uuid>:<url-encoded-password>@<host>:<port>?congestion_control=bbr&alpn=h3&sni=<url-encoded-sni>&allow_insecure=1&udp_relay_mode=native#<url-encoded-name>
```

IPv6 host 必须加方括号。Base64 是上述完整 URI 的无换行 Base64，二维码直接编码上述 URI。凭据页还必须单独显示：

- UUID、Password
- UDP/QUIC 端口
- TLS SNI
- 叶证书 DER SHA-256 Pin
- congestion control、0-RTT 状态

任何普通列表、URI、Base64、二维码和日志都不得包含 TLS private key 或其内容。

## 8. 流量、配额、限速和状态

TUIC 通过永久 Node ID 进入现有 `traffic.json`、历史、结算和状态系统。tc action 传输列表固定为 `["udp"]`：

- 上传：ingress destination UDP port
- 下载：egress source UDP port

`congestion_control=bbr` 是 TUIC/QUIC 拥塞控制；`upload_limit_mbps`/`download_limit_mbps` 是项目 tc 速率上限，二者不能混为一谈。

状态继续仅使用 `enabled`、`disabled_manual`、`disabled_quota`、`disabled_error`。达到全局策略计算出的限额时只移除该 TUIC Node ID 的 inbound；新周期只自动恢复 `disabled_quota`。

## 9. 事务、备份与更新

TUIC 的添加、修改、删除、启停、认证轮换、证书轮换、限额和限速必须全部走现有状态事务：

```text
候选节点/流量/历史/证书
→ 语义校验
→ 完整 sing-box 配置生成与 check
→ 常规备份
→ 持久恢复日志
→ 证书与配置切换
→ restart（原服务已停止则保持停止）
→ PID/UDP 监听/tc/全部旧节点健康检查
→ 数据提交
→ 最终健康检查
→ committed
```

备份含 TUIC JSON 字段及对应 `cert.pem`/`key.pem`，恢复时不得重新生成任何凭据或证书。删除 TUIC 只删除指定 Node ID 的 inbound、证书目录和按用户选择处理的历史。

覆盖安装、manager 更新和 sing-box 更新必须：

- 识别 schema 1/2/3/4；
- 在只读候选中升级旧 schema 并检查完整配置；
- 现有 TUIC 节点存在时验证 UUID/Password 生成能力；
- 现有 HY2/TUIC 节点存在时验证共享 TLS 状态；
- 失败恢复旧程序、二进制、配置、证书、数据、服务运行状态和 tc 规则。

## 10. 验收矩阵

自动化和实机至少覆盖：

1. schema 1/2/3 → 4 的无损迁移和提交失败恢复。
2. SS + VLESS + HY2 + TUIC 同进程配置 check 与同时监听。
3. TUIC 随机/手动端口、UDP 外部占用、四协议数据库端口冲突。
4. IPv4、IPv6、域名和地址族监听策略。
5. UUID/Password 强随机、唯一和重启/普通修改稳定性。
6. 自签 TLS 权限、SAN、key pair、叶证书 Pin 和错误 Pin 拒绝。
7. TUIC URI、Base64、二维码及兼容客户端导入；Pin 单独核对。
8. UDP 监听 PID 所有权、原有节点不丢失。
9. 上传/下载/合计、默认下载配额、全局上传开关、周期自动恢复。
10. 上传/下载限速均为 UDP-only 且不影响其他节点。
11. 认证轮换、证书轮换、删除、备份恢复。
12. 非法配置 check 失败不提交；启动/健康/tc/提交失败均自动回滚。
13. Debian/Ubuntu systemd 与 Alpine OpenRC 的首次安装、覆盖安装、重启和卸载保留模式。

在以上自动化和多系统实机测试完成前，不发布正式版本，也不更新 README 中的固定安装 commit/SHA256。
