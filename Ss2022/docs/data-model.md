# 数据模型

## nodes.json

```json
{
  "schema_version": 1,
  "nodes": [
    {
      "node_id": "32 个小写十六进制字符",
      "name": "Tokyo",
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
    }
  ]
}
```

名称、端口只用于展示和监听；Node ID 是永久身份。允许名称重命名、端口重分配和密钥重生成，历史通过 Node ID 关联。

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

`upload_kernel_bytes` 和 `download_kernel_bytes` 是当前 tc action 的采样基线。它们与流量累计值在同一个文件中原子提交，避免一份文件已更新、另一份尚未更新的窗口。自 1.0.4 起，首次成功采样会兼容读取并删除旧版 `tc-counters.json`。

所有持久字节字段和 `quota_bytes` 都限制在 JSON/IEEE-754 可精确表达的 `0..9007199254740991`。默认配额计费值为 `current_download_bytes`；端口层 `current_upload_bytes` 仍显示和归档，但不用于自动停用，除非管理员明确迁移 manager 状态策略。下载计数也可能包含 TCP 握手回复等未认证响应，因此该策略只降低未认证流量的影响，不提供认证级计费保证。

`traffic-history.json` 的每个结算条目包含 `period`、`period_start_at` 和 `period_end_at`。月份标签按结算边界前最后一秒计算，因此每月 1 日重置仍显示刚结束的月份，而非 1 日重置节点的首个短周期不会覆盖下一个完整周期。

## 状态

- `enabled`：包含在 sing-box 配置中
- `disabled_manual`：用户手动停用
- `disabled_quota`：达到本周期限额
- `disabled_error`：检测到节点配置/运行异常

只有 `disabled_quota` 在节点自己的新周期结算后自动恢复。

修改配额时也会立即重新计算状态：计费量低于新的限额或取消限额会恢复 `disabled_quota`，新限额不高于计费量会立即设为 `disabled_quota`。手动/错误停用不会被配额修改覆盖。

## 其他状态文件

- `manager.json`：manager/sing-box 版本、项目管理的 sing-box 二进制 SHA-256、init system、监听/TFO/BBR/tc 能力和项目创建的 clsact 接口记录；不保存节点密钥。
- `interfaces.json`：检测到的默认路由接口，名称唯一且符合 Linux 接口长度约束。
- `bandwidth-plan.json`：boot ID、接口、实际启用地址族，以及每个启用节点/方向的 action kind、index、cookie、端口和速率。启动校验会把它与节点和接口状态交叉核对。
- `state-transaction/journal.json` 与 `install-transaction/journal.json`：只在未清理事务存在，记录持久阶段、服务原状态和恢复所需元数据；`committed` 是不可回滚的提交点。
