# 发布与更新

## 固定安装入口

公开 root 安装不跟随分支。命令必须同时提供完整 40 位 Git commit 和该 commit 的 GitHub 归档 SHA256。`bootstrap.sh` 只下载这个不可变 commit，验证完整归档摘要、拒绝绝对路径、`..`、符号链接和硬链接，再以不继承归档所有者/特殊权限的方式解压。README 中的两项固定值必须在每次发布后同步更新。

## Manager

`VERSION` 是独立 manager 版本。正式 Release 应包含 `ss2022-manager.tar.gz` 和 `SHA256SUMS`，或由 GitHub 资产元数据提供 `sha256:` digest。归档包含 `Ss2022/ss-manager.sh`、`VERSION`、`lib/`、`config/`、`systemd/`、`openrc/` 和只读订阅服务程序。port-hop 与 subscription 是全局附加服务，不为节点创建独立进程；系统时间同步 Provider（chrony 或 systemd-timesyncd）属于主机基础组件，不作为新的 sing-box/manager 节点服务打包。

更新只接受 `https://github.com/Rem-nm/Codex/releases/download/...`。下载后校验 SHA256、Release 标签与 VERSION、一致且唯一的入口、仅含目录/普通文件的归档、所有 shell 语法、服务模板和持久恢复能力，并把程序目录/文件权限规范化为受保护值。切换前建立包含旧程序完整副本的安装事务；新入口使用不争用现有 manager 锁的 `--self-test`，并在检测到 `manager_update` 事务时执行新版本兼容性预检：旧 schema 节点只复制到 `/run/ss-manager/` 候选文件中升级，随后生成完整 sing-box 配置并由当前受管二进制检查；存在 VLESS 时实际验证 UUID、Reality KeyPair 和 Short ID 生成/校验，存在 TUIC 时验证 UUID/Password 生成能力，存在 HY2/TUIC 时验证证书、私钥、SNI 和 pin；存在端口跳跃或订阅设置时同时预检派生计划、服务定义和私密快照权限，并验证 `manager.json.time_sync` 默认迁移和 NTP 配置字段。预检不迁移或提交永久数据；需要旧 traffic 迁移时拒绝 manager-only 更新，保留给完整安装事务处理。服务定义、manager 状态、证书根、port-hop 规则、订阅派生目录和 `rem` 任一步失败都会恢复。系统 NTP Provider 只选择并启用一套，状态异常只显示辅助警告，不自动停止其他协议。旧切换目录删除及其父目录同步发生在持久 `committed` 标记之前，因此此阶段中断仍由事务副本恢复；提交后的下载临时文件清理失败不会误报为回滚。

成功更新后当前菜单子进程以状态 75 退出，外层菜单立即 `exec` 新入口，避免继续执行旧版已加载函数。

## sing-box

sing-box 版本来自 `SagerNet/sing-box` 官方 Release API。资产按 `sing-box-<version>-linux-amd64.tar.gz` 或 `sing-box-<version>-linux-arm64.tar.gz` 解析，并要求 GitHub 资产 digest 或同一 Release 的 SHA256 校验资产。归档路径和链接类型校验后，候选二进制在最终可执行文件系统上运行版本/config check；这样不会受 `/run` 的 `noexec` 挂载影响。

替换前创建常规备份和持久安装事务。现有 VLESS/TUIC 节点存在时，新二进制除检查当前配置外，还必须通过对应身份生成/校验能力检查；现有 HY2/TUIC 节点还必须通过共享 TLS 证书状态检查；同时必须检查完整配置中的 sing-box `ntp` 模块。原服务运行时会 restart 并按协议做 PID/端口健康检查，原本停止时保持停止并再次执行官方配置检查；普通失败、崩溃或断电都会恢复旧二进制、配置、证书、版本状态和全部受管服务原有运行状态。port-hop 与订阅服务独立恢复：它们失败时保持明确不可用，不阻断 sing-box；系统 Provider 不属于这些附加服务，失败只保留警告；成功更新后从 nodes 和 subscription.json 重建派生计划与无私钥订阅快照。

## 附加服务

`ss-manager-porthop.service`（systemd）或 `ss-manager-porthop`（OpenRC）只负责 Hysteria2 跳跃 NAT/tc 的网络可用性恢复；`ss-manager-subscription.service` 或 `ss-manager-subscription` 以专用低权限账号提供只读订阅路由。两个服务都是全局单实例，默认不开放公网监听，不读取服务端私钥，且不属于 sing-box 启动依赖。覆盖安装、备份恢复、重启和卸载必须分别保存、重建或删除它们的 desired state。

## 时间同步兼容

安装和更新会检测并复用当前唯一的系统时间同步 Provider。Debian/Ubuntu 无 Provider 时优先 `systemd-timesyncd`，CentOS/AlmaLinux 优先 `chrony`，Alpine 使用 OpenRC `chrony`；不会同时启用两个 daemon，也不以 `ntpdate` 作为核心实现。`manager.json.time_sync` 默认启用系统同步检查和 sing-box NTP（服务器默认 `time.apple.com`、端口 123、周期 `30m`），配置由完整候选文件生成并通过官方 `sing-box check`。

卸载 REM 不删除或停止原有 chrony、chronyd 或 systemd-timesyncd；即便 Provider 软件包由 REM 补装，也默认保留。系统 Provider 未同步时只给出辅助警告，sing-box、VLESS、Hysteria2 和 TUIC 不因该状态被粗暴停止。
