# 架构说明

## 进程模型

Ss2022 不为节点创建进程。启用节点被转换为同一 `config.json` 的多个 Shadowsocks inbound，由一个 sing-box 服务负责启动、停止和重启；Debian/Ubuntu/CentOS/AlmaLinux 使用 systemd，Alpine Linux 使用 OpenRC。

节点地址是客户端分享信息，监听地址由系统 IPv4/IPv6 能力单独决定。IPv6 可用且 `bindv6only=0` 时默认监听 `::`；IPv4-only 系统监听 `0.0.0.0`；`bindv6only=1` 时按地址家庭生成监听地址。

## 数据边界

`nodes.json` 保存节点身份、凭据、端口、地址、状态、限额和限速，是唯一节点源数据。`traffic.json` 保存当前周期和累计计数，`traffic-history.json` 保存已结算周期。sing-box 配置由节点源数据生成，不反向作为数据库。

`manager.json` 只保存 manager/sing-box 版本、能力探测、监听模式和更新锁，不保存节点密钥。

## 流量路径

每个节点的端口同时承载 TCP 和 UDP。tc 过滤器在默认路由接口上匹配：

```text
上传：ingress dst_port=node.port
下载：egress  src_port=node.port
```

每分钟读取过滤器 action 的 bytes 计数，和 `tc-counters.json` 上次基线做差后加到 `traffic.json`。服务器重启或规则缺失时会先重建规则并重置内核基线，避免把计数归零误判成新增流量。

## 系统范围

项目只使用 `tc` 进行统计和限速，不使用 iptables/nftables/UFW/firewalld/ipset。BBR/TFO 只写本项目标记的 sysctl 文件，且只在内核声明支持时开启；完全卸载会尝试恢复本项目记录的原值。
