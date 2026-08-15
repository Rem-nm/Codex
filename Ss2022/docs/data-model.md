# 数据模型

## nodes.json

```json
{
  "schema_version": 3,
  "nodes": [
    {
      "node_id": "32 个小写十六进制字符",
      "name": "Tokyo",
      "protocol": "shadowsocks",
      "method": "2022-blake3-aes-256-gcm",
      "password": "base64 密钥",
      "port": 20001,
      "address": "example.com",
      "address_type": "domain",
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
    },
    {
      "node_id": "另一个永久 Node ID",
      "name": "Osaka-VLESS",
      "protocol": "vless",
      "uuid": "UUID",
      "flow": "xtls-rprx-vision",
      "reality_private_key": "Reality X25519 Private Key",
      "reality_public_key": "Reality X25519 Public Key",
      "reality_short_id": "16 个十六进制字符",
      "reality_server_name": "www.example.com",
      "reality_handshake_server": "www.example.com",
      "reality_handshake_port": 443,
      "port": 20002,
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
  ]
}
```

schema 3 使用 `protocol` 判别联合：`shadowsocks` 必须且只能包含 method/password 协议字段；`vless` 必须且只能包含 UUID、固定 Flow 和完整 Reality 字段；`hysteria2` 必须且只能包含 password、TLS SNI 和 certificate pin。公共状态字段只维护一份。Node ID、名称和端口全局唯一；VLESS UUID、Reality private/public key、Short ID 以及 Hysteria2 password/pin 也分别保持节点间唯一，防止导入或恢复时悄悄共用身份。名称、端口只用于展示和监听；Node ID 是永久身份。允许名称重命名、端口重分配和协议凭据重生成，历史始终通过 Node ID 关联。第一版不支持在协议之间转换，候选事务也会拒绝既有 Node ID 改变协议。

Reality Private Key 只属于服务器端。`nodes.json`、备份和 sing-box 配置必须保持 root 所有、权限 600；节点列表、普通详情、VLESS URI、Base64、二维码和普通成功信息都不得输出 Private Key。恢复备份时直接恢复原 UUID、KeyPair 和 Short ID，不能重新生成。

旧 `schema_version: 1` 只表示 SS2022 节点。升级时先备份节点、流量、历史、manager 状态和当前 sing-box 配置，再原子写入 schema 3，并为每个旧节点增加 `protocol: "shadowsocks"`。旧 schema 2 只升级顶层版本。除判别字段与顶层 schema 版本外不改变旧节点内容；迁移不会生成证书或改变任何协议凭据。

## traffic.json

每个节点至少有：

```json
{
  "current_upload_bytes": 0,
  "current_download_bytes": 0,
  "total_upload_bytes": 0,
  "total_download_bytes": 0,
  "upload_kernel_bytes": 0,
  "download_kernel_bytes": 0,
  "quota_bytes": 0,
  "reset_day": 1,
  "last_reset_at": "UTC ISO-8601",
  "next_reset_at": "UTC ISO-8601",
  "updated_at": "UTC ISO-8601"
}
```

`upload_kernel_bytes` 和 `download_kernel_bytes` 是当前 tc action 的采样基线。它们与流量累计值在同一个文件中原子提交，避免一份文件已更新、另一份尚未更新的窗口。升级旧版 manager 时，安装事务会先保存旧文件，再把 1.0.4 以前缺少的两个基线字段从旧版 `tc-counters.json` 安全迁入；没有可用旧基线时只补零，不覆盖累计流量。首次成功采样后会清理旧版 `tc-counters.json`。

所有持久字节字段和 `quota_bytes` 都限制在 JSON/IEEE-754 可精确表达的 `0..9007199254740991`。SS2022、VLESS 与 Hysteria2 共用 manager 的全局配额策略，默认计费值为 `current_download_bytes`；端口层 `current_upload_bytes` 仍显示和归档，但不用于自动停用。若管理员启用既有全局上传计费选项，则全部协议统一按上传加下载触发，不能为单个协议单独切换。下载计数也可能包含未认证响应，因此该策略只降低未认证流量的影响，不提供认证级计费保证。

`traffic-history.json` 的每个结算条目包含 `period`、`period_start_at` 和 `period_end_at`。月份标签按结算边界前最后一秒计算，因此每月 1 日重置仍显示刚结束的月份，而非 1 日重置节点的首个短周期不会覆盖下一个完整周期。

## 状态

- `enabled`：包含在 sing-box 配置中
- `disabled_manual`：用户手动停用
- `disabled_quota`：达到本周期限额
- `disabled_error`：检测到节点配置/运行异常

只有 `disabled_quota` 在节点自己的新周期结算后自动恢复。

修改配额时也会立即重新计算状态：计费量低于新的限额或取消限额会恢复 `disabled_quota`，新限额不高于计费量会立即设为 `disabled_quota`。手动/错误停用不会被配额修改覆盖。

## 其他状态文件

- `manager.json`：manager/sing-box 版本、项目管理的 sing-box 二进制 SHA-256、init system、监听/TFO/BBR/tc 能力、全局配额策略和项目创建的 clsact 接口记录；不保存节点凭据。
- `interfaces.json`：检测到的默认路由接口，名称唯一且符合 Linux 接口长度约束。
- `bandwidth-plan.json`：boot ID、接口、实际启用地址族，以及每个启用节点/方向的 action kind、index、cookie、端口、速率和实际传输列表。SS2022 action 使用 `["tcp","udp"]`，VLESS action 使用 `["tcp"]`，Hysteria2 action 使用 `["udp"]`；启动校验会把它与节点协议和接口状态交叉核对。旧计划缺少传输字段时仅按旧 SS2022 的 TCP/UDP 语义读取。
- `/etc/ss-manager/certs/<node-id>/`：仅 Hysteria2 使用的自签 ECDSA P-256 叶子证书和私钥。目录权限 700，文件权限 600，证书 pin 是证书 DER 的 SHA-256 小写十六进制值；证书目录随状态事务、安装事务、备份与恢复一起原子处理。
- `state-transaction/journal.json` 与 `install-transaction/journal.json`：只在未清理事务存在，记录持久阶段、服务原状态和恢复所需元数据；`committed` 是不可回滚的提交点。
