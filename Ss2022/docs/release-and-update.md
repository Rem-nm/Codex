# 发布与更新

## Manager

`VERSION` 是独立的 manager 版本。正式 Release 应包含 `ss2022-manager.tar.gz` 和 `SHA256SUMS`，归档内包含 `Ss2022/ss-manager.sh`、`VERSION`、`lib/`、`config/` 和 `systemd/`。更新只接受 `https://github.com/Rem-nm/Codex/releases/download/...`，先校验 SHA256、VERSION 和所有 shell 文件语法，再替换 `/opt/ss-manager`。

## sing-box

sing-box 版本来自 `SagerNet/sing-box` 官方 Release API。资产名称按 `sing-box-<version>-linux-amd64.tar.gz` 或 `sing-box-<version>-linux-arm64.tar.gz` 解析，并要求同一 Release 的 SHA256 资产。替换前备份当前二进制和配置；新二进制检查当前配置、启动并健康检查失败时恢复旧版。

项目不执行 `curl | bash`，不接受随机下载站，也不把 manager 版本和 sing-box 版本混在一起。版本锁定只影响 sing-box 更新，不影响节点数据和 manager 更新。
