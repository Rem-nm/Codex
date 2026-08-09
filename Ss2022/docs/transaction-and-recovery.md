# 配置事务和恢复

所有会改变运行 inbound 的操作都调用同一个事务入口：

1. 读取现有节点、流量、历史和有效配置。
2. 在 `/run/ss-manager/` 生成候选 JSON 和候选 sing-box 配置。
3. 校验 JSON、Node ID、名称、端口、地址、密钥和状态。
4. 调用 `sing-box check -c candidate.json`。
5. 在 `/etc/ss-manager/backups/YYYYMMDD-HHMMSS-reason/` 保存当前节点、流量、历史、配置、metadata 和 sing-box 二进制快照。
6. 安装候选配置；操作前服务正在运行时快速 restart，用户已停止服务时保持停止。
7. 运行状态下通过 systemd/OpenRC 检查服务状态、唯一主进程、配置 check 和每个启用节点 TCP/UDP 端口；停止状态下只做官方配置检查并确认服务没有被意外启动。
8. 应用并检查带 action cookie/精确 handle 所有权的 tc 规则，并在候选 `traffic.json` 中重置新规则基线。
9. 提交流量累计值与基线同文件的节点、流量和历史 JSON；多文件提交中任一步失败都会用事务前副本恢复。
10. 再次健康检查，成功后保留备份并清理旧备份。

任何一步失败都不提交候选数据库；切换后失败会恢复旧配置、旧 JSON 和旧 tc 规则，并恢复操作前的服务运行/停止状态。旧配置也失败时会输出严重错误，要求用户通过 `rem` 查看 systemd/OpenRC 服务状态。

备份默认保留最近 10 个配置变更，也可从菜单立即创建手动快照。删除节点时是否保留流量历史由用户确认；保留时会把当前快照放入 `traffic-history.json` 的 `deleted_nodes`，选择不保留则同时清除该 Node ID 的已结算周期。
