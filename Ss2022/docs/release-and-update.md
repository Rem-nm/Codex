# 发布与更新

## Manager

`VERSION` 是独立的 manager 版本。正式 Release 应包含 `ss2022-manager.tar.gz` 和 `SHA256SUMS`，归档内包含 `Ss2022/ss-manager.sh`、`VERSION`、`lib/`、`config/`、`systemd/` 和 `openrc/`。更新只接受 `https://github.com/Rem-nm/Codex/releases/download/...`，先校验 SHA256、VERSION 和所有 shell 文件语法，再切换 `/opt/ss-manager`。切换前会备份当前程序、manager 状态和服务定义；新入口自检、systemd/OpenRC 模板同步或状态提交任一步失败，都会恢复整组旧状态。成功后当前菜单进程立即重新执行新入口，不继续运行旧版已加载函数。

## sing-box

sing-box 版本来自 `SagerNet/sing-box` 官方 Release API。资产名称按 `sing-box-<version>-linux-amd64.tar.gz` 或 `sing-box-<version>-linux-arm64.tar.gz` 解析，并要求 GitHub 资产 SHA256 digest 或同一 Release 的 SHA256 校验资产。替换前备份当前二进制和配置并执行统一保留策略；新二进制检查当前配置，运行中的服务会重启并做健康检查，原本停止的服务保持停止，失败时恢复旧版。

公开的一键安装入口只从固定的 `raw.githubusercontent.com/Rem-nm/Codex` 地址取得小型 `bootstrap.sh`；该入口随后通过 HTTPS 下载完整仓库归档、检查归档路径并在临时目录运行安装器。更新流程不会执行来自随机下载站的脚本。manager 与 sing-box 的正式更新仍必须使用官方 Release 和 SHA256 校验；版本锁定只影响 sing-box 更新，不影响节点数据和 manager 更新。
