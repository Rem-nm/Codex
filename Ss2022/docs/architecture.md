# 架构说明

## 进程模型

Ss2022 不为节点创建进程。启用节点被转换为同一 `config.json` 的多个 Shadowsocks inbound，由一个 sing-box 服务负责启动、停止和重启；Debian/Ubuntu/CentOS/AlmaLinux 使用 systemd，Alpine Linux 使用 OpenRC。

节点地址是客户端分享信息，监听地址由系统 IPv4/IPv6 能力单独决定。IPv6 可用且 `bindv6only=0` 时默认监听 `::`；IPv4-only 系统监听 `0.0.0.0`；`bindv6only=1` 时 IPv4/IPv6 地址按各自家庭监听，域名节点生成两个同端口 inbound，并使用 `-ipv4`/`-ipv6` tag 后缀。

## 数据边界

`nodes.json` 保存节点身份、凭据、端口、地址、状态、限额和限速，是唯一节点源数据。`traffic.json` 保存当前周期、累计计数及对应的 tc 内核计数基线，`traffic-history.json` 保存已结算周期。sing-box 配置由节点源数据生成，不反向作为数据库。

`manager.json` 只保存 manager/sing-box 版本、能力探测、监听模式和更新锁，不保存节点密钥。

## 流量路径

每个节点的端口同时承载 TCP 和 UDP。tc 过滤器在默认路由接口上匹配：

```text
上传：ingress dst_port=node.port
下载：egress  src_port=node.port
```

每个节点、每个方向建立一个带确定性 index 和 128-bit 所有权 cookie 的共享 tc action；当前实际启用的地址族、TCP/UDP 及多个默认路由接口的 flower filter 都绑定到该 action。IPv4-only 主机不会创建 IPv6 filter。每分钟读取 action 聚合 bytes，与 `traffic.json` 基线做差，并把增量、累计和新基线作为一个 JSON 原子提交。任一计数读取失败则整次采样不写入；同一启动周期的 filter 损坏会先采样仍在的 action，再重建规则。

端口 ingress 计数无法证明 Shadowsocks 认证成功，因此原始上传统计可能含未认证探测。自动配额停用默认只使用下载 egress，以降低 ingress 洪泛直接耗尽配额的风险；但 egress 也可能包含 TCP 握手回复等未认证响应，所以端口计数不是认证用户的精确业务账单，也不能替代抗流量攻击措施。

## 系统范围

项目只使用 `tc` 进行统计和限速，不使用 iptables/nftables/UFW/firewalld/ipset。tc 清理必须同时匹配 action cookie、index、精确 filter handle 和全部 action 绑定；任何查询失败或范围外绑定都拒绝删除。服务存在性、启用状态与运行状态采用“存在/不存在/查询失败”三态判断，systemd/OpenRC 查询失败不会被当作已停止或不存在。BBR/TFO 只更新本项目标记的 sysctl 文件并保留其中其他项目设置，且只在能力通过时开启；设置、安装和更新都由持久事务保护，删除运行配置或完全卸载时恢复记录的原值。
