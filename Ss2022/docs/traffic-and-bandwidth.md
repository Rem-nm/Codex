# 流量统计与限速

## 方向与统计边界

客户端视角为准：

```text
上传 = 客户端 → Shadowsocks 服务器
下载 = Internet → Shadowsocks 服务器 → 客户端
```

服务器外部接口上的上传包以节点端口为目标端口，下载包以节点端口为源端口，因此规则分别匹配 ingress `dst_port` 和 egress `src_port`。这是端口层计数：上传包含链路/传输层开销，也包含到达公开端口但未通过 Shadowsocks 认证的流量；它不是用户认证后的精确业务用量。

## 持久化和规则修复

`ss-manager-traffic.timer` 每分钟读取每个节点、每个方向的共享 tc action bytes，与 `traffic.json` 基线做差，再把周期累计、总累计和新基线作为一个 JSON 原子提交。任一 action 查询失败、JSON 异常或计数超出 `9007199254740991`，整次采样都不写入。

同一启动周期内若 flower filter 损坏但共享 action 尚在，维护器先采样 action 计数，再重建规则；系统重启导致 action 一并消失时重建并重置基线。这样既避免丢弃仍可证明所有权的流量，也不会把内核归零误算为新增流量。

timer 使用 `OnBootSec=1min` 和 `OnUnitActiveSec=60s`，没有对单调 timer 无效的 `Persistent=true` 声明。周期结算本身通过 `last_reset_at`/`next_reset_at` 循环补齐所有错过周期，因此关机跨月后仍会结算。

## 配额

每个节点重置日为 1-28。0 表示不限额。由于端口 ingress 无法区分认证成功与未认证探测，自动停用默认只按下载 egress 判断；上传仍完整显示和归档。这能降低 ingress 洪泛的直接影响，但 egress 仍可能包含 TCP 握手回复等未认证响应，不能视为认证级账单或抗攻击保证。达到限额只把节点设为 `disabled_quota`，不删除凭据或历史。取消/提高限额会在已用计费量低于新限额时立即恢复节点，降低限额到已用量以下会立即停用；新周期也会自动恢复 `disabled_quota`。

## tc 能力、限速和所有权

安装先在临时 dummy 接口上探测 `clsact`、flower、当前启用地址族的 TCP/UDP、共享 gact/police action、cookie、action `bind` 数、精确规则 JSON 语义和统计字段。地址族以主路由表实际存在的默认出口为准：IPv4-only 只探测并安装 IPv4 规则，不会因 IPv6 loopback 误建 IPv6 规则；IPv6-only 也不强制 IPv4 规则。内核版本、iproute2 版本、默认出口地址族或探测契约变化会使能力签名失效并重新探测。

每个节点上传、下载各有一个共享 action；所有接口、实际启用的地址族和 TCP/UDP filter 都绑定到它，所以限速是节点方向的聚合速率。0 使用 `gact pass` 只计数，非零使用 police。

清理前必须同时证明 action cookie/index、每条只有一个预期 action 的精确 filter handle，以及 action 的全部内核 `bind` 都落在保存的计划范围内。qdisc/filter/action 查询失败、JSON 异常、额外绑定、重复规则或混合 action/所有权都会停止删除。只有 ingress 与 egress 查询都成功且确认无任何规则时，才会删除项目创建的空 clsact。

统计和限速依赖保存的主路由表默认出口。默认出口在同一次启动期间变化时，下一次维护会先原子保存仍可读取的共享 action 计数，再在持久安装事务中重新探测接口、应用规则并重置基线；路由查询失败会保持原状态且不写流量增量。主路由表多出口会聚合统计；非主路由表的策略路由不在自动发现范围内，部署前应单独核对。
