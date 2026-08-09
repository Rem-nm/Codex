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
  "next_reset_at": "UTC ISO-8601"
}
```

`upload_kernel_bytes` 和 `download_kernel_bytes` 是当前 tc action 的采样基线。它们与流量累计值在同一个文件中原子提交，避免一份文件已更新、另一份尚未更新的窗口。1.0.4 首次成功采样会兼容读取并删除旧版 `tc-counters.json`。

`traffic-history.json` 的每个结算条目包含 `period`、`period_start_at` 和 `period_end_at`。月份标签按结算边界前最后一秒计算，因此每月 1 日重置仍显示刚结束的月份，而非 1 日重置节点的首个短周期不会覆盖下一个完整周期。

## 状态

- `enabled`：包含在 sing-box 配置中
- `disabled_manual`：用户手动停用
- `disabled_quota`：达到本周期限额
- `disabled_error`：检测到节点配置/运行异常

只有 `disabled_quota` 在节点自己的新周期结算后自动恢复。
