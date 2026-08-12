# 发布与更新

## 固定安装入口

公开 root 安装不跟随分支。命令必须同时提供完整 40 位 Git commit 和该 commit 的 GitHub 归档 SHA256。`bootstrap.sh` 只下载这个不可变 commit，验证完整归档摘要、拒绝绝对路径、`..`、符号链接和硬链接，再以不继承归档所有者/特殊权限的方式解压。README 中的两项固定值必须在每次发布后同步更新。

## Manager

`VERSION` 是独立 manager 版本。正式 Release 应包含 `ss2022-manager.tar.gz` 和 `SHA256SUMS`，或由 GitHub 资产元数据提供 `sha256:` digest。归档包含 `Ss2022/ss-manager.sh`、`VERSION`、`lib/`、`config/`、`systemd/` 和 `openrc/`。

更新只接受 `https://github.com/Rem-nm/Codex/releases/download/...`。下载后校验 SHA256、Release 标签与 VERSION、一致且唯一的入口、仅含目录/普通文件的归档、所有 shell 语法、服务模板和持久恢复能力，并把程序目录/文件权限规范化为受保护值。切换前建立包含旧程序完整副本的安装事务；新入口使用不争用现有 manager 锁的 `--self-test`，并在检测到 `manager_update` 事务时执行新版本兼容性预检：旧 schema 节点只复制到 `/run/ss-manager/` 候选文件中升级，随后生成完整 sing-box 配置并由当前受管二进制检查；存在 VLESS 时还实际验证 UUID、Reality KeyPair 和 Short ID 生成/校验。预检不迁移或提交永久数据；需要旧 traffic 迁移时拒绝 manager-only 更新，保留给完整安装事务处理。服务定义、manager 状态和 `rem` 任一步失败都会恢复。旧切换目录删除及其父目录同步发生在持久 `committed` 标记之前，因此此阶段中断仍由事务副本恢复；提交后的下载临时文件清理失败不会误报为回滚。

成功更新后当前菜单子进程以状态 75 退出，外层菜单立即 `exec` 新入口，避免继续执行旧版已加载函数。

## sing-box

sing-box 版本来自 `SagerNet/sing-box` 官方 Release API。资产按 `sing-box-<version>-linux-amd64.tar.gz` 或 `sing-box-<version>-linux-arm64.tar.gz` 解析，并要求 GitHub 资产 digest 或同一 Release 的 SHA256 校验资产。归档路径和链接类型校验后，候选二进制在最终可执行文件系统上运行版本/config check；这样不会受 `/run` 的 `noexec` 挂载影响。

替换前创建常规备份和持久安装事务。现有 VLESS 节点存在时，新二进制除检查当前配置外，还必须通过 VLESS 身份生成/校验能力检查。原服务运行时会 restart 并按协议做 PID/端口健康检查，原本停止时保持停止并再次执行官方配置检查；普通失败、崩溃或断电都会恢复旧二进制、配置、版本状态和全部受管服务原有运行状态。
