# Ss2022 增量开发进度记录

## 1. 用途

这份文件是端口跳跃和订阅服务开发的持续进度记录，也是记忆压缩或重新进入任务后恢复上下文的首要入口。

每次开始工作前必须先阅读：

~~~text
docs/development-requirements-port-hopping-and-subscription.md
docs/development-progress.md
docs/development-requirements-time-sync-and-ntp.md
~~~

每完成一个可验证阶段，必须更新本文件的状态、验证结果、失败点、回滚结果和下一步。不得把 VPS 密码、真实 token、完整订阅 URL、真实节点 URI、Reality Private Key、TLS Private Key 或真实备份写入本文件。

## 2. 基线

| 项目 | 当前值 |
|---|---|
| 仓库 | Rem-nm/Codex |
| 目录范围 | Ss2022/ |
| 基线提交 | 9b3ca7a2e1c7739ff2c59361d38ad0258c3aeeba |
| 基线提交说明 | feat(ss2022): add TUIC unified node support |
| Manager 版本 | 1.3.0-dev.1 |
| nodes schema | 5 |
| 当前分支 | agent/tuic-support |
| GitHub 提交状态 | 本阶段禁止提交，待全部测试通过 |
| 需求文档 | development-requirements-port-hopping-and-subscription.md |

## 3. 用户指定执行顺序

必须严格按以下顺序，不得跳到订阅阶段：

1. 完成 Hysteria2 UDP 端口跳跃开发；
2. 完成端口跳跃本地代码验证；
3. 在用户提供的两台 VPS 上完成端口跳跃测试；
4. 端口跳跃测试通过后，开发订阅链接与远程订阅服务；
5. 完成订阅服务本地代码验证；
6. 在两台 VPS 上完成订阅服务测试；
7. 上述测试通过后，执行脚本全功能回归测试；
8. 全部通过后，使用 GitHub 插件完成提交、推送、创建 PR 并合并。

任何阶段失败时先修复并重复该阶段验证，不得用后续阶段掩盖前一阶段失败。

## 4. 当前阶段状态

### 阶段 A：需求和开发文档

状态：已完成

已完成：

- 读取 Hysteria2 UDP Port Hopping 原始需求；
- 读取订阅链接与远程订阅服务原始需求；
- 对照当前 SS2022、VLESS、Hysteria2、TUIC 代码结构；
- 明确 nodes schema 5 同时加入 subscription_enabled 和 HY2 跳跃字段；
- 明确 bandwidth-plan schema 3 必须支持 tc 端口范围；
- 明确端口跳跃使用 manager 自有 NAT 命名空间；
- 明确订阅服务不能直接读取含服务端私钥的 nodes.json；
- 明确 root 管理器生成无服务端私钥的订阅派生快照；
- 明确现有 certificate_sha256 与 sing-box SPKI Base64 Pin 不同；
- 已写入开发规范 Markdown。

验证：

- Markdown 代码围栏成对；
- 文档关键字段、路由、事务、回滚和测试矩阵已复核；
- 未执行代码修改、VPS 修改或 GitHub 提交。

### 阶段 B：Hysteria2 UDP 端口跳跃

状态：已完成（代码验证与两台 VPS 实机验证通过）

目标：

- nodes schema 5 迁移和严格校验；
- Hysteria2 跳跃菜单和范围校验；
- nftables 优先、iptables/ip6tables fallback；
- manager 规则所有权和幂等 reconcile；
- tc flower 范围统计、配额和限速；
- 状态、删除、备份、恢复、安装、重启和卸载联动；
- HY2 URI 和 sing-box client server_ports 输出；
- systemd/OpenRC 全局恢复服务；
- 本地单元/集成验证；
- 两台用户 VPS 实机验证。

已完成的实现与修复：

- nodes schema 5 迁移、订阅默认字段和 Hysteria2 跳跃字段严格校验；
- nftables 优先、iptables/ip6tables fallback、manager 专属命名空间与幂等清理；
- tc flower 连续端口范围匹配，保留实际监听端口的兼容精确规则；
- Hysteria2 跳跃菜单、范围冲突检查、URI 范围输出、OpenRC/systemd 恢复服务；
- 跳跃元数据事务复用持久状态回滚，不重启 sing-box；
- 修复候选文件未从现有状态初始化导致零字节数据库的问题；
- 修复空 JSON 被 jq 当作成功、`ss` UDP 本地端口列解析错误、nft comment 引号错误、nft 所有权校验 jq 语法错误，以及实际端口位于范围外时范围被错误扩大；
- 修复 OpenRC 首轮端口跳跃循环与安装锁的竞态，安装完成后返回码稳定为 0。

阶段 B 验证证据：

- 本地/远端 Debian Bash 验证：全部 shell 语法检查、port-hopping、Hysteria2、VLESS、TUIC、JSON、validation、regressions、platform-support、deep-audit、smoke 测试通过；
- Alpine Bash 验证：同一测试矩阵全部通过；
- Debian 12 systemd VPS：schema 4→5 覆盖安装通过；端口跳跃开启、范围修改、关闭、重启恢复通过；nft 规则、tc 范围与实际端口规则、URI 和健康检查通过；开启/修改/关闭均保持 sing-box 主进程 PID 不变；
- Alpine 3.21 OpenRC VPS：schema 4→5 覆盖安装返回码 0；补装 nftables 后开启、关闭、重启恢复通过；OpenRC porthop/traffic 服务启用并运行；nft 规则、tc 范围与健康检查通过；开启/关闭均保持 sing-box 主进程 PID 不变；
- 两台 VPS 的端口跳跃测试均验证了实际监听端口位于外部范围之外时，NAT 与 tc 仍只使用用户声明的连续范围，并额外保留实际端口精确统计规则。

回滚与异常证据：

- Debian 一次故意失败的跳跃事务曾产生空候选文件，已使用持久事务备份恢复 nodes、traffic、history 和配置；随后重建 tc，健康检查恢复通过；
- nftables 不可用的 Alpine 初始环境按设计失败关闭，未修改节点状态；安装 nftables 后才执行成功路径；
- 所有失败路径均未向 GitHub 写入任何 VPS 数据。

阶段 B 未实现订阅 HTTP 服务，当前可进入阶段 C。

### 阶段 C：订阅链接与远程订阅服务

状态：已完成（本地验证与两台 VPS 实机验证通过）

前置条件：

- 阶段 B 的代码验证全部通过；
- 阶段 B 的两台 VPS 测试全部通过；
- 端口跳跃不会绕过统计、配额和限速；
- 现有四协议回归没有新增失败。

目标：

- subscription_enabled 和订阅设置 schema；
- 统一四协议 URI 导出；
- Raw、Base64、完整 sing-box Remote Profile；
- 低权限订阅服务；
- token 轮换、HTTP 路由、HEAD/GET、404/405；
- 订阅派生快照自动更新；
- VLESS/HY2/TUIC 不泄露服务端私钥；
- 与 HY2 跳跃范围联动；
- systemd/OpenRC、备份、恢复、卸载；
- 本地验证和两台 VPS 实机验证。

已完成的实现与修复：

- 统一四协议订阅导出：Raw、整体标准 Base64、完整 sing-box Profile；Hysteria2 跳跃范围使用 `server_ports` 与固定 `30s`；VLESS Reality outbound 补齐客户端 uTLS Chrome 指纹；Profile 使用 sing-box 1.13 的本地 DNS schema；
- subscription.json schema 1、256-bit 无填充 Base64URL Token、127.0.0.1 默认监听、严格公网 URL/端口校验、派生 export/runtime 原子发布与失败关闭；
- 订阅 HTTP 支持 GET/HEAD、四路由、安全响应头、统一 404/405、恒时 Token 比较、无请求日志；服务使用专用低权限账号且不能读取 nodes、证书和服务端私钥；
- 节点订阅开关、全部加入/移出、Token 轮换、服务启停、端口修改、备份恢复均为 metadata-only 操作，不重启 sing-box 或修改 tc/NAT；
- 修复订阅派生目录的 711/750 权限与原子写入父目录模式；修复 systemd/OpenRC 服务定义模式差异，OpenRC 服务模板不再把低权限 stdout/stderr 写入 root-only 日志；修复 `false` 布尔值被 jq `-e`/`//` 误判导致节点无法重新加入订阅。

阶段 C 本地验证：

- Shell/Python 语法、订阅模型、HTTP 安全、深度审计测试通过；真实 sing-box 1.13.18 对四协议 Profile 检查通过；
- Raw 字节规范、整体 Base64 解码一致、四协议顺序、VLESS uTLS、HY2 跳跃 outbound、SPKI Pin 和服务端私钥不泄露检查通过。

阶段 C VPS 验证：

- Debian 12 systemd：覆盖安装、四协议订阅 HTTP、GET/HEAD/404/405、安全头、Token 轮换、节点开关双向、服务启停/端口恢复、备份恢复、低权限读取拒绝、sing-box PID 不变均通过；
- Alpine 3.21 OpenRC：覆盖安装、修复 OpenRC 服务可执行权限与低权限日志问题后，四协议订阅 HTTP、Profile 检查、Token 轮换、节点开关双向、服务停用/启用、端口恢复、备份恢复、低权限读取拒绝、sing-box PID 不变均通过；traffic、porthop、subscription 服务最终均恢复运行；
- 两台 VPS 节点的真实协议集合均包含 Shadowsocks、VLESS、Hysteria2、TUIC；跳跃 Hysteria2 订阅范围与原配置一致。

结果：

通过。阶段 C 前置条件满足，可以进入阶段 D 全功能回归。

失败与修复：

- Alpine 首次启用订阅时发现 OpenRC 模板以低权限用户打开 root-only 日志，服务 crashed；改为默认安全输出并验证启动；
- 节点订阅开关从 false 恢复 true 时发现 jq 对 false 的退出码/空值语义误判，修复为显式布尔类型校验并在两台 VPS 双向验证；
- 一次诊断 shell 漏载 links/certs 模块造成派生快照不可用，补齐完整 manager 上下文后重新验证，确认不是产品路径失败；
- Alpine 端口变更的首次即时探针早于 OpenRC 监听建立，后续等待后验证成功并恢复默认端口。

回滚/恢复证据：

- Debian 与 Alpine 均完成 Token 轮换后旧地址失效、新地址恢复；备份恢复后原 Token 重新可用；
- 订阅停用时 HTTP 服务停止并返回不可用，重新启用后恢复；全部元数据操作均保持 sing-box 主进程 PID 不变；
- 覆盖安装失败时持久安装事务保持 fail-closed，清理 crashed OpenRC 服务状态后重新安装成功；未向仓库写入任何真实运行数据。

### 2026-08-16 阶段 C 实机验证完成

范围：

订阅链接与远程订阅服务；Debian 12 systemd 与 Alpine 3.21 OpenRC；覆盖安装、低权限服务、四协议导出、Token、节点筛选、服务启停、端口变更、备份恢复。

修改：

修复 OpenRC 服务可执行权限和低权限日志重定向；修复 false 订阅字段切换；补齐真实 sing-box 1.13 Profile 的 DNS/uTLS 兼容；修复派生目录与原子写入权限。

本地验证：

订阅模型、HTTP、安全、深度审计、Shell/Python 语法和真实 Profile 检查通过。

VPS 验证：

两台 VPS 均验证四协议 Raw/Base64/Profile、GET/HEAD/404/405、安全头、Token 轮换、节点开关双向、服务启停、端口恢复、备份恢复、低权限拒绝和 sing-box PID 不变；最终服务状态正常。

结果：

通过。进入阶段 D 全功能回归，尚未提交 GitHub。

失败与修复：

Alpine OpenRC 初始服务因 root-only 日志 crashed；节点 false 切换因 jq 语义误判失败；均已修复并在两台 VPS 重测通过。

回滚/恢复证据：

Token 备份恢复、订阅停用/启用和安装事务恢复通过；VPS 真实凭据、Token、URI 和私钥未写入仓库或进度文档。

下一步：

执行阶段 D 全功能回归。

### 阶段 D：全功能回归

状态：已完成（本地代码验证、两台 VPS 全量回归、覆盖安装与重启恢复通过）

前置条件：

- 阶段 B、C 均通过；
- 两台 VPS 的覆盖安装、重启、恢复和卸载测试均通过。

范围：

- SS2022；
- VLESS + REALITY + Vision；
- 普通 Hysteria2；
- Hysteria2 Port Hopping；
- TUIC；
- 节点增删改、启停、配额、重置、限速、备份恢复；
- URI、Base64、二维码；
- schema 迁移；
- sing-box 更新；
- Debian/Ubuntu systemd；
- Alpine OpenRC；
- 安装失败和事务回滚；
- 订阅服务故障不影响 sing-box；
- 端口跳跃服务故障不影响 sing-box。

阶段 D 验证记录：

- Debian 12 systemd 与 Alpine 3.21 OpenRC 均执行完整测试套件：`bash -n`、Python 编译、JSON/model、validation、端口跳跃、四协议模型、订阅模型与 HTTP 安全、regressions、platform-support、deep-audit、smoke；最终返回码均为 0。
- 两台 VPS 均保留 SS2022、VLESS、普通/跳跃 Hysteria2 和 TUIC 的混合 sing-box 配置；官方 `sing-box check` 通过，服务、进程、端口、tc、NAT 所有权和订阅派生快照检查通过。
- 两台 VPS 均完成覆盖安装和重启恢复：systemd/OpenRC 的 sing-box、traffic、port-hop、subscription desired state 正确恢复；订阅服务仍按低权限账户运行，不能读取 nodes、证书或服务端私钥。
- 覆盖安装的并发锁、安装事务和 fail-closed 路径已验证：维护任务占锁时安装停止并保留状态；释放锁后重试成功。Alpine 磁盘空间不足时安装在写入 sing-box 前停止并保留恢复证据；仅删除本轮明确创建的测试备份以释放空间，其他用户备份与节点数据未触碰，随后覆盖安装成功。
- 订阅端点故障与 port-hop 服务故障隔离已验证：派生快照失败不发布陈旧内容，附加服务停止/重启不改变 sing-box 主进程；低权限读取拒绝、Token 轮换、备份恢复和节点订阅开关双向操作均通过。

阶段 D 结果：

通过。阶段 B、C、D 的代码和两台用户 VPS 实机验证均满足，进入发布前审计；当前仍未提交 GitHub。

### 2026-08-16 阶段 D 全功能回归完成

范围：

端口跳跃、订阅服务、SS2022、VLESS、Hysteria2、TUIC；Debian 12 systemd 与 Alpine OpenRC；全量脚本、覆盖安装、锁冲突、事务恢复、低权限、重启和附加服务故障隔离。

本地/远端验证：

两台 VPS 最终完整套件均返回 0，包含 Shell/Python 语法、所有协议模型、订阅 HTTP、安全审计、深度审计、平台支持和 smoke；两台实际 sing-box Profile 均通过官方配置检查。

实机验证：

两台均完成覆盖安装并重启，混合协议仍在一个 sing-box 进程；端口跳跃规则/统计/限速、订阅 Raw/Base64/Profile、Token、节点筛选、服务启停、备份恢复、低权限拒绝均通过。安装锁和磁盘空间不足路径按设计 fail-closed，恢复后重试成功。

结果：

通过。没有把 VPS 密码、真实 token、订阅 URL、节点 URI、证书私钥或备份上传到仓库。仅保留项目源代码、测试、服务模板、文档和不含真实运行数据的进度记录。

下一步：

执行发布前最终 diff、敏感信息和目录范围审计；审计通过后按 GitHub 插件流程提交、推送、创建 PR 并合并。

### 阶段 E：GitHub 发布与合并

状态：已完成

只有阶段 B、C、D 的代码验证和实机验证全部通过后才能开始。

发布前必须：

- 检查 git status 和完整 diff；
- 只包含 Ss2022/ 范围内有意修改；
- 确认没有 VPS 密码、真实 token、真实节点数据或私钥；
- 检查 GitHub 远程和插件连接权限；本机未安装 `gh`，因此使用已连接的 GitHub 插件完成 PR 操作；
- 使用 GitHub 插件规定的提交、推送、Draft PR、冲突解决和合并流程；
- 在 PR 描述中记录实现内容、测试环境、测试结果和已知限制。

### 2026-08-16 阶段 E GitHub 发布完成

范围：

将端口跳跃、订阅服务、schema 5 生命周期、测试、服务模板和同步文档发布到 `Rem-nm/Codex` 的 `Ss2022/` 目录。

发布：

- 发布分支：`agent/tuic-support`；本地提交 `b55d432`，与已合并的 TUIC 基线冲突通过只保留等价实现解决，最终分支提交 `b8d5129`。
- Pull Request：[#25](https://github.com/Rem-nm/Codex/pull/25)，先创建 Draft，随后转为 Ready，并在确认无 CI 阻塞后以 squash 方式合并。
- main 合并提交：`cccd93a`。

发布前检查：

- `git diff --check` 通过；最终变更仅位于 `Ss2022/`；VPS 凭据模式、真实 token、节点 URI、订阅 URL、证书私钥和备份扫描均为 0 命中。
- PR 合并前重新解决了 origin/main 的 TUIC 基线冲突，并复核 `node_new_tuic_record` 只有一个实现，避免自动合并重复函数。

结果：

通过。端口跳跃与订阅阶段已提交并合并；后续如需发布新安装入口，应以 main 合并后的正式 Release commit 和归档 SHA256 更新 README 固定值。

### 阶段 F：系统时间同步与 sing-box NTP

状态：代码已接入，Ubuntu/Alpine 非破坏性验证已完成；PR #27 已提交并合并。真实覆盖安装、重启、时间跳变、备份恢复和卸载验证仍作为合并后的后续工作项。

前置基线：

- 阶段 B、C、D 的端口跳跃、订阅和四协议回归已经完成并合并；
- 当前节点数据库为 schema 5，配额继续使用全局策略，默认只按下载触发限额；
- 当前项目保持一个 sing-box 服务和一个 sing-box 进程；
- 当前系统设置、安装、健康检查和配置生成已接入时间同步功能，仍需完成实机覆盖安装、重启、时间跳变、备份恢复和卸载验证。

本阶段文档修改：

- 新增 `docs/development-requirements-time-sync-and-ntp.md`，整理系统 Provider、sing-box NTP、`manager.json.time_sync`、安装/迁移、菜单、健康检查、事务、备份、卸载和测试矩阵；
- 更新 `docs/data-model.md`，定义 `manager.json.time_sync` 默认结构、合法值和迁移规则；
- 更新 `docs/architecture.md`，加入系统 NTP 主机制与 sing-box NTP fallback 的两层路径；
- 更新 `docs/transaction-and-recovery.md`，明确时间设置进入候选配置、检查、提交和回滚边界，且不接管系统 Provider 的卸载；
- 更新 `docs/release-and-update.md`，明确 Provider 复用、旧 manager 迁移、NTP 配置检查和卸载保留策略；
- 更新 `README.md`，补充安装提示、系统设置入口、健康警告和支持范围。

已确认的实现原则：

- 先检测并复用已运行的 chrony/chronyd 或 systemd-timesyncd，不同时启动两套 daemon；
- Debian/Ubuntu 无 Provider 时优先 systemd-timesyncd，CentOS/AlmaLinux 优先 chrony，Alpine 使用 chrony/OpenRC；
- 默认启用 sing-box NTP：`time.apple.com:123`，周期 `30m`；配置必须由完整候选配置生成并通过官方 `sing-box check`；
- 不自动修改时区、RTC、防火墙或云安全组；
- 系统时间同步异常只显示辅助警告，不停止 SS2022、VLESS、Hysteria2、TUIC 或整个 sing-box；
- 卸载 REM 不删除或停止系统原有、或本次补装的时间同步软件；
- SS2022 创建前只做时间状态提示，sing-box NTP 已开启时不因系统状态暂时未知而拒绝创建。

已完成的代码接入：

- 新增 `lib/time_sync.sh`，实现 Provider 检测/复用、chrony/timesyncd 原生同步、冲突拒绝、状态展示和 sing-box NTP 设置事务；
- 安装与 manager 启动/更新路径补齐 `manager.json.time_sync` 迁移、状态记录和候选配置生成；
- `generate_singbox_config` 增加顶层 NTP 模块，系统设置菜单增加时间同步入口，健康检查增加辅助状态和 SS2022 创建前提示；
- 新增 `tests/test-time-sync-model.sh`，覆盖旧状态迁移、NTP 参数校验、Provider 选择/冲突和配置生成。

当前未完成：

- CentOS/AlmaLinux 以及无 Provider 主机的安装实机验证；
- 覆盖安装、重启、时间跳变、备份恢复和卸载验证；
- 完整脚本回归与四协议/端口跳跃/订阅组合实机验证；
- 合并后的发布分支现场复核。

### 2026-08-16 阶段 F 非破坏性验证

范围：

Ubuntu（systemd）与 Alpine 3.21（OpenRC）临时源目录；未覆盖现有项目状态、节点、配置或 sing-box 服务。

本地/远端验证：

- Ubuntu：全部 shell 语法、时间同步模型、SS/VLESS/Hysteria2/TUIC、端口跳跃、订阅（含 HTTP）、JSON、校验、平台、回归和深度审计测试通过；现场检测到 `systemd-timesyncd` 且 `Synchronized`；从现有节点生成带 `ntp` 的完整配置并通过实际 sing-box `check`；
- Alpine：同一套模型、协议、端口跳跃、订阅（含 HTTP）、JSON、校验、平台、回归、深度审计和语法测试通过；现场原本无可确认 Provider，安装并启用 chrony 时因容器缺少 `CAP_SYS_TIME` 启动失败；修复后按设计只记录警告、保留 sing-box NTP fallback，SS2022 创建前检查仍可继续。
- 最后一轮仅修改了 Provider 无服务时的识别和状态展示；Ubuntu 最新语法/模型已复跑通过，Alpine SSH 随后返回 `Not allowed at this time`，未能复跑该微小差异；此前 Alpine 全套回归证据仍保留。

结果：

通过（模型/静态/只读现场验证）。Provider 启动失败不再阻断安装或其他协议，但真实覆盖安装、重启、时间跳变、备份恢复和卸载仍未执行。

修复与证据：

- 修正 Provider 成功状态码判定、无效 interval 测试引号和 manager 更新包 fixture；
- 对无法修改系统时钟的宿主机，Provider 安装/启用失败改为明确警告并继续使用 sing-box NTP fallback；不自动安装第二个 daemon；
- Ubuntu 现场 NTP 状态及实际 `sing-box check` 输出未包含任何真实凭据，未写入仓库。

下一步：

1. 合并后继续完成 Ubuntu 与 Alpine 的覆盖安装前置检查；
2. 按开发文档执行 Debian 11/12、Ubuntu、Alpine、CentOS、AlmaLinux 的 Provider/重启/时间跳变矩阵；
3. 完成备份恢复、卸载保留 Provider 和四协议回归；
4. 汇总所有通过/失败证据，修复后再次执行全套测试；
5. Web Panel 需求已进入阶段 G，开发前先完成本文件的兼容边界复核。

### 阶段 F 发布记录

- 发布分支：`agent/tuic-support`；PR：[#27](https://github.com/Rem-nm/Codex/pull/27)。
- 合并方式：squash；`main` 合并提交：`e84431d316aece8c69aad6d964ff69eb31d4b2c6`。
- 发布内容仅位于 `Ss2022/`；未包含 VPS 凭据、真实节点数据、Token、URI、证书私钥或备份。

### 阶段 G：REM Web Panel 需求静态核对与第一阶段只读基础

状态：需求已完整阅读并与当前 Ss2022 稳定实现静态核对；确认无硬冲突。第一阶段只读基础已实现并完成 Ubuntu/Debian 12 与 Alpine 3.21.7 隔离验证；写事务、远程 REM 和公网 HTTPS 仍未实现。

#### 核对结论

这份 Web Panel 需求可以作为现有 REM 的增量阶段，不会改变以下已经稳定的边界：

- SS2022、VLESS、Hysteria2、TUIC 仍使用统一 `nodes.json`、Node ID、流量/配额/限速和备份恢复；
- 所有协议仍由一个 sing-box 服务/进程管理，Web 只是新增管理入口；
- HY2 Port Hopping、订阅、时间同步和现有健康检查继续由当前 manager 负责；
- `rem` CLI 必须继续可用，Web/CLI 争用同一个 `/run/ss-manager/manager.lock`；
- Web 不得读取或直接改写 `nodes.json`、`config.json`、nftables/iptables/tc，必须走现有候选配置、`sing-box check`、备份、应用、健康检查和回滚路径；
- 现有低权限订阅服务仍只读取无服务端私钥的派生快照，不能改作 Web 写 API。

#### 当前实现缺口（不是现有功能冲突）

这些能力在当前代码中尚未存在，后续开发必须补齐，不能把“需求已记录”当作“功能已实现”：

1. 没有写事务 Manager Core API；当前新增的 Core 只提供只读业务方法。节点/流量/订阅/时间同步/备份写操作仍必须通过受限的本地特权边界调用公共事务函数，不能让非 root Web 进程直接执行 `ss-manager.sh` 或获得 `nodes.json` 读取权限。
2. 第一阶段已新增只读 Web 服务、`/api/v1/` 路由、管理员账号哈希、Session、登录限速、固定入口 Token 和面板服务模板；仍缺 `rem` 菜单接入、IP Allowlist 管理、审计日志和完整前端，面板默认必须关闭。
3. 当前 `manager.json` 没有 `instance_id`、机器密钥、面板认证、远程实例和 trusted instance 状态；应使用独立 root-only 状态或在受事务保护的 manager schema 中增量迁移，不能破坏旧状态。
4. 当前 `nodes.json` schema 5 对每个协议使用严格字段集合，节点没有 `core`/`direction` 字段。第一版应先以兼容方式把 `core=sing-box`、`direction=inbound` 作为适配层能力或单独元数据表达；不得未经 schema 迁移直接给现有节点添加字段，否则现有语义校验会拒绝。
5. 当前状态事务快照主要覆盖 nodes/traffic/history/config/certs，常规备份虽保存 `manager.json`，恢复流程并不把所有 manager 设置逐项恢复；面板 Token、管理员、远程信任和 IP 白名单必须定义独立的备份/恢复/回滚边界。
6. 现有订阅 Token 与面板入口 Token 必须使用不同命名空间和不同状态文件。订阅 Token 可轮换且服务只读；面板入口 Token 默认长期固定并保护管理 API，不能复用或混淆。
7. 没有 REM-to-REM Instance Identity、机器签名/短期机器 Session、Pairing、权限绑定、能力协商或直接远程实例列表；远程操作必须由目标 REM 获取自身 Manager Lock 并执行本地事务，不能通过 SSH 或复制远程数据库实现。
8. Web Panel 的 systemd/OpenRC 可选、低权限、默认 loopback 服务模板已加入源码，但尚未由安装流程创建账号、安装/启用服务；仍需明确与反向代理 HTTPS（模式 A）的信任边界。

#### 开发时必须保留的兼容决策

- 第一阶段只实现 sing-box Core Adapter，协议 UI 通过 Protocol Registry/Capabilities 选择；不实现 Xray、Mihomo、Routing、RuleSet、DNS、Chain、Telegram 或多管理员 RBAC。
- Manager Core 的业务操作必须覆盖节点增删改/启停、流量/配额/限速、Port Hopping、订阅、时间同步、备份恢复、sing-box 管理和更新，并统一返回成功、校验失败、BUSY、回滚失败等结构化结果。
- Web 写操作必须复用现有锁和事务；锁争用不能覆盖状态，返回 BUSY 或受控等待。Web 挂掉不得影响 CLI、sing-box、节点、流量维护或订阅服务。
- 管理员密码只保存可靠哈希；Cookie 只保存 HttpOnly/Secure/SameSite Session 标识；任何响应、日志、审计或错误都不得输出密码、Password Hash、Reality/HY2/TUIC 私钥或机器私钥。
- 固定入口 Token、IP Allowlist、TLS、Human Auth、Machine Auth、Authorization、Session/短期 Token 必须分层；错误 Token、根路径和不在白名单的请求统一 404，不泄露真实入口。
- 远程首次绑定可使用目标管理员账号/密码，但成功 Pairing 后必须清除，不得在本地长期保存远程管理员明文密码；后续只使用机器身份和短期访问令牌。
- 面板必须通过现有 Share Exporter 提供 URI/Base64/二维码；不得重新实现协议分享生成器，也不得显示服务端私钥。
- 开发顺序按需求文档执行：Manager Core 非交互化 → 内部业务 API → Web Auth/Secret Path/Session → Dashboard/节点 → 流量/配额/限速 → Port Hopping → Subscription → Time Sync → Backup/sing-box 管理 → Remote Pairing/Remote VPS → Allowlist/TOTP。

#### 需求范围记录

阶段 G 的后续开发必须先更新本文件，再进行本地模型/安全测试、Debian/Ubuntu/Alpine 等实机验证和完整四协议回归；未完成前不得把面板服务默认安装、监听公网或提交真实服务器数据。

#### 2026-08-16 G1/G2 实现记录

范围：

Manager Core 非交互只读边界、Web Auth/Secret Path/Session 基础、Dashboard/节点/流量/系统/订阅/时间同步只读 API、安装包结构接入；不启用现有 VPS 的面板服务，不修改现有节点或 sing-box 运行状态。

修改：

- 新增 `web/panel_core.py`：root-only Unix socket 服务；每个请求以非阻塞独占方式争用现有 `/run/ss-manager/manager.lock`，锁被 CLI/事务占用时结构化返回 `BUSY`；只允许固定业务方法，不提供 Shell、命令执行或原始配置写入。
- 新增 `web/panel_server.py`：默认仅监听 `127.0.0.1` 的低权限 HTTP 层；根路径、错误 Token、白名单外请求统一 404；登录后才允许 `/api/v1/` 只读业务 API；响应不记录访问日志，设置 no-store、安全响应头。
- 新增 `web/panel_init.py` / `web/panel_common.py`：PBKDF2-HMAC-SHA256 管理员密码哈希、43 字符 Base64URL 入口 Token、永久 `instance_id`、严格的 root-only 私有状态和低权限公共描述文件；密码只经 stdin 进入，不出现在命令参数或响应。
- 新增 systemd/OpenRC 的 `ss-manager-panel-core` 与 `ss-manager-panel` 模板；模板默认不启用，面板仍须显式初始化和启用，Core socket 使用专用运行目录和面板组权限。
- 安装包/manager 更新包结构校验与权限归一化已包含 `web/` 和上述服务模板；原有四协议、订阅、端口跳跃、时间同步、事务模块未改变。
- 新增 `tests/test-web-panel.py`，并更新 manager 包结构回归夹具；夹具包含 SS2022、VLESS、Hysteria2、TUIC 的服务端私有字段，用于验证 HTTP/API 不泄漏。

本地验证：

- Python 3 编译、`git diff --check`、Web/服务模板静态审计通过；当前 Windows 工作区没有 Bash，因此 Bash 语法和 Unix socket 测试转到两台 Linux VPS 执行。

VPS 验证：

- Alpine 实机：Alpine Linux 3.21.7，Python 3.12、Bash 5.2；Web Panel 两项端到端测试通过，Shell/OpenRC 语法通过，原有 smoke、deep-audit、四协议模型、端口跳跃、订阅、时间同步、TUIC/VLESS、validation、regression 全部通过；初始化器的 Token 长度、文件权限、重复初始化保护通过。
- 第二台实机：实际识别为 Debian GNU/Linux 12（不是 Ubuntu），Python 3.11、Bash 5.2；同一套 Web Panel、Shell/systemd/OpenRC 语法、初始化器和全部既有回归测试通过。
- 测试均使用 `/tmp/rem-panel-src` 隔离副本与临时数据；没有覆盖 `/opt/ss-manager`、`/etc/sing-box/config.json`、节点/流量数据库或现有服务。一次早期夹具环境变量错误在 Alpine 创建了精确的临时 Panel 状态文件，已核对并删除；节点、流量、sing-box 配置均未触碰。

结果：

通过（只读基础和回归）。已验证：固定入口 Token/404、PBKDF2 登录、登录失败限速、HttpOnly/Secure/SameSite Session、四协议统一节点模型、敏感字段过滤、Manager Lock 竞争返回 `BUSY`、Debian 12/Alpine 兼容。没有把只读基础误报为完整 Web Panel。

未实现/后续：

1. 节点增删改、启停、配额、限速、Port Hopping、备份/恢复、sing-box 管理和更新的 Web 写 API；这些必须先抽象为公共 Manager Core 事务并复用现有候选配置/`sing-box check`/健康检查/回滚。
2. CLI `rem` 菜单中的 Panel 初始化/启停/Token 轮换/密码修改入口；当前可用 `panel_init.py --password-stdin` 作为受控基础工具，服务模板未默认安装、未启用。
3. Panel 专属状态进入现有备份、安装事务和恢复事务；当前 `panel.json` 是独立 root-only 状态，尚未纳入恢复提交边界。
4. 反向代理 HTTPS 部署向导、证书管理、IP Allowlist UI、TOTP/Passkey、审计日志和完整前端页面。
5. REM-to-REM Pairing、机器密钥/短期令牌、直接绑定权限和能力协商；不实现 Master/Agent 分裂，也不复制远程节点数据库。

回滚/恢复证据：

- 本轮只写入隔离 `/tmp` 测试目录；VPS 现场状态检查未发现项目目录、节点库、sing-box 配置或服务被修改。面板初始化器和服务均未在现有安装上启用。

下一步：

1. 抽象现有 Bash 节点/流量/订阅/时间同步/备份操作为受限 Core 写事务，先完成单节点启停/配额/限速的候选配置与回滚验证；
2. 将 Panel 状态加入安装事务、常规备份/恢复和更新回滚，并通过 `rem` 提供显式启用/停用入口；
3. 在两台 VPS 上进行实际“启用后再停用”的服务生命周期测试，再实现完整 Web UI 和 HTTPS 反代文档；
4. 写 API、远程 Pairing 和多 VPS 管理完成并通过全协议回归后，才提交 GitHub。

## 5. 关键设计决策

### 5.1 端口跳跃

- 一个 Hysteria2 节点仍只有一个实际 sing-box UDP 监听端口；
- 外部连续 UDP 范围通过 manager 专属 NAT REDIRECT 指向实际端口；
- actual port 位于自身范围时必须排除，避免自重定向；
- 禁用节点移除运行 NAT 规则，但保留范围占用；
- tc 必须同时匹配跳跃范围和必要的 actual port；
- NAT、tc、nodes 和回滚必须属于同一可恢复事务；
- 开启或修改跳跃通常不重启 sing-box，但必须重新应用 tc；
- 默认 hop_interval 固定 30s；
- 不支持 tc 范围或所需地址族时失败关闭。

### 5.2 订阅

- 第一版只有一个 default subscription；
- 服务默认关闭并只监听 127.0.0.1；
- 默认服务端口 18080，可高级修改；
- token 至少 256-bit 随机熵，轮换后旧 URL 立即失效；
- 订阅服务使用专用低权限用户；
- HTTP 服务只读派生快照，不读取 nodes.json；
- 节点库仍是唯一真实数据源；
- 单节点 URI 必须复用现有 node_share_uri；
- 默认 URL 返回 Base64 URI Bundle；
- 同时提供 Raw 和完整 sing-box Profile；
- disabled 节点暂时不输出，恢复后自动出现；
- 从订阅移除不等于停用节点；
- 订阅失败不得重启或停止 sing-box；
- 不输出 Reality Private Key、TLS Private Key；
- 真实 token、节点数据和订阅 URL 永不进入 GitHub。

### 5.3 配额和统计

- 上传、下载、合计仍全部统计和展示；
- 全局配额策略默认只按下载触发；
- 端口跳跃不得改变 Node ID 级流量归属；
- 订阅不输出流量数字或 Subscription-Userinfo。

## 6. 阶段记录模板

每次测试或修复后追加以下内容，不覆盖历史证据：

~~~text
### YYYY-MM-DD HH:MM 阶段/操作

范围：

修改：

本地验证：

VPS 验证：

结果：

失败与修复：

回滚/恢复证据：

下一步：
~~~

记录结果时使用“通过/失败/阻塞/未执行”，不要使用没有证据的“应该正常”。

### 2026-08-16 阶段 B 实机验证完成

范围：

Hysteria2 UDP 端口跳跃；Debian 12 systemd 与 Alpine 3.21 OpenRC；schema 迁移、覆盖安装、开启、修改、关闭、重启恢复和健康检查。

修改：

补齐 schema 5、NAT/tc 规则层、统一跳跃事务和恢复服务；修复真实 `ss` 列解析、nft comment/所有权校验、范围边界、候选空文件和 OpenRC 安装锁竞态。

本地验证：

全部 shell 语法检查及 port-hopping、四协议模型、JSON、validation、regressions、platform-support、deep-audit、smoke 测试通过。

VPS 验证：

Debian 12 与 Alpine 3.21 均完成覆盖安装；两台均完成跳跃开启/修改/关闭、nft 规则与 tc 范围检查、URI 检查、sing-box PID 不变检查和重启恢复；健康检查通过。

结果：

通过。阶段 B 前置条件满足，可进入订阅阶段。

失败与修复：

一次 Debian 失败事务留下零字节候选状态，已从持久事务备份恢复并重建 tc；Alpine 未安装 NAT 后端时按设计失败关闭，安装 nftables 后成功。

回滚/恢复证据：

事务备份恢复、tc 重建、NAT 规则清理和两台 VPS 重启后的规则重建均通过；真实运行数据未写入仓库。

下一步：

开始阶段 C 订阅链接与远程订阅服务开发，不提前提交 GitHub。

## 7. 当前下一步

1. 记忆压缩或新阶段开始时先重新读取本进度文件，沿阶段 G 的兼容边界继续；
2. 将现有节点/流量/订阅/时间同步/备份操作逐项接入受限 Manager Core 写事务，先验证启停、配额和限速；
3. 把 `panel.json` 纳入安装事务、备份恢复和更新回滚，并补上 `rem` 的 Panel 显式启停/初始化入口；
4. 在 Ubuntu/Debian 12 与 Alpine 继续进行实际服务生命周期、反向代理 HTTPS 和四协议回归；
5. 完成 Web 写 API、远程 Pairing、多 VPS 管理并通过全套测试后，再通过 GitHub 插件提交并合并；
6. 不把任何真实运行数据、凭据、Session、Token 或私钥写入仓库。
