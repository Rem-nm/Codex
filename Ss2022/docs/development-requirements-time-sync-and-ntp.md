# Ss2022 增量开发规范：系统时间同步与 sing-box NTP

## 1. 文档定位

本文是 `Rem-nm/Codex/Ss2022/` 在现有四协议统一节点管理、Hysteria2 UDP 端口跳跃和订阅服务基础上的下一阶段增量开发规范。

本阶段只增加“系统时间同步 / Time Synchronization”能力，不重写节点、流量、限速、证书、订阅或事务系统。Shadowsocks 2022、VLESS、Hysteria2、TUIC 继续共用一个节点数据库、一个 sing-box 服务和一个 sing-box 进程。

当前基线：

| 项目 | 基线 |
|---|---|
| 节点协议 | Shadowsocks 2022、VLESS + REALITY + Vision、Hysteria2、TUIC v5 |
| `nodes.json` | schema 5 |
| 配额 | 全局策略；上传、下载、合计全部统计和展示；默认只按下载触发限额 |
| 服务 | Debian/Ubuntu/CentOS/AlmaLinux 使用 systemd；Alpine 使用 OpenRC |
| 时间层 | 新增系统 NTP Provider 与 sing-box 内置 NTP 两层机制 |
| GitHub 范围 | 只能修改 `Ss2022/`；本阶段测试完成前不得发布 |

## 2. 目标与不可破坏项

目标是让服务器 Unix 时间保持可靠，并在系统时间同步受限时由 sing-box 内置 NTP 为 TLS、Shadowsocks、VLESS、Hysteria2 和 TUIC 提供协议层时间保障。

现有功能必须继续正常：

- 永久唯一 Node ID、名称去重和全局唯一实际端口；
- 四协议统一节点增删改、启停、详情、链接、Base64 和二维码；
- 上传、下载、合计流量统计与历史归档；
- 全局月流量限额、独立重置日、自动恢复和现有 `disabled_*` 状态；
- 上传/下载独立限速、tc 规则、Hysteria2 端口跳跃和订阅派生服务；
- sing-box 候选配置检查、运行健康检查、状态事务、安装事务、备份、恢复、更新和卸载；
- 一个 sing-box systemd/OpenRC 服务和一个 sing-box 主进程。

时间同步异常只能产生辅助警告，不得直接停止 VLESS、Hysteria2、TUIC 或整个 sing-box。系统同步暂时无法确认时，若 sing-box NTP 已启用，仍允许创建和应用 SS2022 节点。

## 3. 两层时间同步架构

```text
Linux System Time Sync Provider
        │ 主机制：校准操作系统 Unix 时间
        ▼
系统时间 / Unix Timestamp
        │
        ├── Shadowsocks 2022 时间戳与重放保护
        └── sing-box 内置 NTP 保险层
                ├── TLS / VLESS
                ├── Hysteria2 / TUIC
                └── Shadowsocks 2022
```

Shadowsocks 2022 比较的是 Unix Timestamp，不是显示时区。服务器使用 UTC、Asia/Tokyo 或 Asia/Shanghai 都可以；只要绝对时间一致，不得因为 Local Time 与 UTC 显示不同而判定异常。安装和修复不得自动修改时区、RTC 或用户现有时区配置。

## 4. 系统 NTP Provider 策略

### 4.1 支持的系统

至少支持：

- Debian 11、Debian 12；
- Ubuntu；
- CentOS；
- AlmaLinux；
- 当前项目已经支持的 Alpine Linux/OpenRC。

### 4.2 检测与复用

Provider 检测必须先于安装和启用：

1. 检测 `chronyd/chrony` 及其 `chronyc` 状态；
2. 检测 `systemd-timesyncd` 与 `timedatectl` 状态；
3. 选择当前已运行且可确认同步的 Provider；
4. 如果只有一个 Provider 已安装但暂未同步，复用它并尝试恢复；
5. 只有没有可用 Provider 时才安装一个合适的实现。

不得同时启用 `chronyd/chrony` 和 `systemd-timesyncd`。Provider 选择和服务状态必须通过 systemd/OpenRC 适配层执行，不能无条件调用固定的 `ntpdate`。

默认选择：

| 系统 | 无可用 Provider 时的优先实现 |
|---|---|
| Debian/Ubuntu | `systemd-timesyncd`；不可用时使用 `chrony` |
| CentOS/AlmaLinux | `chrony/chronyd` |
| Alpine/OpenRC | `chrony` |

包管理器只安装最终选择的一套 Provider。已存在的 Provider 不重复安装，不因本项目卸载而删除或停止。Provider 包属于系统基础依赖，安装失败时不反向卸载已经存在的软件包。

如果宿主机不允许容器或 VPS 修改系统时钟、Provider 启动失败或状态查询暂时不可用，安装/修复不得因此停止 sing-box 或其他协议；必须记录明确警告、把系统状态记为 `unknown`，并继续使用已生成的 sing-box NTP fallback。只有在用户主动执行“立即同步”时，才把 Provider 操作失败作为本次同步动作失败返回。

### 4.3 Provider 状态

系统状态至少区分：

- `chrony`；
- `systemd-timesyncd`；
- `unknown`。

同时记录：

- Provider 服务名；
- 是否由 REM 本次安装；
- 最近检查时间；
- 最近检查结果；
- 是否已确认同步。

状态未知或未同步时必须 fail-closed 地报告警告，不能把查询错误当成“已同步”。

## 5. `manager.json` 时间设置

在现有 `manager.json` 顶层增加 `time_sync` 对象。旧版本没有该对象时，必须在安装、更新或 manager 启动的迁移阶段原子补齐默认值：

```json
{
  "time_sync": {
    "system_sync_enabled": true,
    "singbox_ntp_enabled": true,
    "ntp_server": "time.apple.com",
    "ntp_port": 123,
    "ntp_interval": "30m",
    "provider": "unknown",
    "service_name": "",
    "installed_by_rem": false,
    "last_status": "unknown",
    "last_checked_at": null,
    "last_sync_at": null
  }
}
```

实现要求：

- `system_sync_enabled` 默认 `true`，表示 REM 管理/检查系统 Provider；禁用时只停止 REM 的检查和修复，不得擅自停止系统服务；
- `singbox_ntp_enabled` 默认 `true`；
- `ntp_server` 只接受合法主机名或 IP，不允许 shell/JSON 注入；
- `ntp_port` 为 1-65535 的整数，默认 123；
- `ntp_interval` 第一版固定默认为 `30m`，普通菜单不开放任意 duration 输入；
- `provider` 只能是 `chrony`、`systemd-timesyncd` 或 `unknown`；
- 时间字段使用 UTC ISO-8601，尚未检查时使用 `null`；
- `manager.json` 仍由 root 持有、权限 600，所有修改必须通过现有原子 JSON 写入和事务边界。

时间设置属于 manager 配置，不属于节点协议字段，不得新增第二套时间数据库。

## 6. sing-box NTP 配置

配置生成器必须在生成完整候选配置时从 `manager.json.time_sync` 生成顶层 `ntp` 模块，不得手工修改正在运行的 `config.json`：

```json
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  }
}
```

字段格式以 [sing-box 官方 NTP 配置](https://sing-box.sagernet.org/configuration/ntp/) 为准。每次设置变更仍必须执行：

```text
manager state candidate
        ↓
生成完整 sing-box candidate
        ↓
sing-box check
        ↓
应用配置 / restart
        ↓
完整健康检查
        ↓
提交 manager.json
```

sing-box NTP 失败不能覆盖或停止其他协议。若当前 sing-box 版本不接受该模块，配置检查必须失败并恢复原 manager/config；不能静默写入未知字段。

## 7. 安装、修复、更新和启动

首次安装顺序调整为：

```text
识别发行版与 init system
        ↓
检测现有时间同步 Provider
        ↓
补齐且只启用一套 Provider
        ↓
检查/尝试同步系统时间
        ↓
迁移 manager.json.time_sync 默认值
        ↓
生成并检查带 ntp 的 sing-box 配置
        ↓
安装/启动 sing-box
        ↓
继续现有首节点流程
```

覆盖安装、manager 更新和重启启动必须：

- 保留现有 Provider 和 `time_sync` 设置；
- 不因旧版本缺少 `time_sync` 而覆盖节点、密码、UUID、Reality KeyPair、证书、流量或限速；
- Provider 已经正常运行时跳过重复安装和不必要的 APT/DNF/APK 更新；
- 在服务启动后重新检查 sing-box NTP 配置和时间状态；
- 不能要求用户每次执行 `rem` 才能保持系统同步。

## 8. 安装提示与健康检查

安装和系统设置至少显示：

```text
[Time] 检查服务器时间...
本地时间：2026-08-16 14:08:32 JST
UTC：2026-08-16 05:08:32 UTC
时区：Asia/Tokyo
系统同步服务：chronyd
系统 NTP：✓ Synchronized
sing-box NTP：✓ Enabled
```

健康检查增加辅助状态：

- `Sing-box: Running`；
- `System Time: Synchronized / Unknown / Unsynchronized`；
- `System NTP: chronyd / systemd-timesyncd / unknown`；
- `sing-box NTP: Enabled / Disabled`。

系统 NTP 查询失败不能让原本健康的 sing-box 健康检查返回失败，但必须在终端或状态摘要中给出警告。若系统 NTP 未同步且 sing-box NTP 也禁用，`rem` 显示明显警告，指出 SS2022 可能因时间偏差无法连接。

## 9. SS2022 创建前检查

SS2022 节点在真正应用候选配置前调用统一时间状态检查：

- 已同步：显示“时间同步正常”，继续原创建流程；
- 未同步或无法确认：显示警告、当前 Provider 和 sing-box NTP 状态；
- sing-box NTP 已启用时允许继续创建；
- 系统同步和 sing-box NTP 都关闭时仍不强制删除节点，但必须要求用户明确确认并保留警告。

VLESS、Hysteria2、TUIC 也可在详情/健康检查中显示同一状态，但不得复制另一套时间输入或校验逻辑。

## 10. “系统设置 → 时间同步”

不新增顶级菜单，加入现有“系统设置”：

```text
系统设置
1. 查看系统能力
2. 检查/启用 BBR
3. 检查/启用 TCP Fast Open
4. 刷新流量接口
5. 查看 tc 流控规则
6. 时间同步
```

时间同步子菜单：

```text
时间同步
系统时间：...
UTC：...
时区：...
系统 NTP：...
同步服务：...
sing-box NTP：...
NTP Server：...

1. 立即检查时间
2. 立即同步时间
3. 修改 NTP Server
4. 启用 / 禁用 sing-box NTP
5. 查看时间同步状态
0. 返回
```

“立即同步”必须调用当前 Provider 的原生方式：

- chrony：使用 `chronyc` 的同步/校时能力；
- systemd-timesyncd：使用 `timedatectl`/`systemd-timesyncd`；
- OpenRC：使用当前启用的 chrony 服务及其客户端命令。

第一版不得以 `ntpdate` 作为核心实现，也不得为了立即同步同时启动第二个 daemon。

## 11. 时间跳变和 sing-box 重启

执行立即同步前后记录 Unix epoch。若校正幅度达到约 30 秒或更大：

1. 重新检查 Provider 和 sing-box NTP；
2. 若 sing-box 原本运行，通过现有 restart/健康检查路径重新建立协议状态；
3. 若 restart 或健康检查失败，按现有状态/安装事务恢复旧配置和服务状态；
4. 不因为时间同步失败而删除节点或停止其他协议；
5. 记录警告和失败证据，不静默继续。

普通“立即检查”不重启 sing-box。时区变化不属于本阶段功能。

## 12. 事务、备份、恢复和卸载

### 12.1 事务

`manager.json.time_sync`、生成的 sing-box NTP 配置和原有节点/流量/证书必须进入现有候选、检查、提交和回滚边界。配置检查失败、restart 失败、健康检查失败或提交前中断时，恢复旧 manager、旧 config、旧节点、旧流量、旧证书和旧服务状态。

系统 Provider 属于系统基础服务，不是 sing-box 节点服务。项目不得把 chrony/timesyncd 的 unit 文件伪装成项目服务，也不得把它们加入 sing-box 启动依赖。

### 12.2 备份与恢复

常规备份自动保存 `manager.json` 中完整的 `time_sync` 对象。恢复时保持用户原有 NTP Server、端口、周期、Provider 记录和 sing-box NTP 开关；恢复后重新生成带 ntp 的候选配置，不重新生成节点身份。

### 12.3 卸载

卸载 REM 时：

- 不删除系统原有 chrony、chronyd 或 systemd-timesyncd；
- 不停止原本就存在的时间同步服务；
- 即使 Provider 包由 REM 本次补装，也默认保留，不在卸载时擅自删除；
- 只清理项目自身的程序、节点、流量、sing-box、tc、端口跳跃和订阅服务；
- 若时间同步状态无法确认，不阻断其他安全卸载检查，也不得把未知状态当成项目服务所有权。

## 13. 安全与输入校验

- NTP Server 只接受合法域名/IP，拒绝控制字符、路径、引号、换行、空值和 shell 元字符；
- 端口必须为 1-65535 的十进制整数；
- `ntp_interval` 只接受项目固定的 `30m`，不把用户输入直接拼接到 shell 或 JSON；
- 不输出 NTP 认证密钥或系统私密信息；
- 不修改防火墙、安全组、时区、RTC、用户现有 NTP 配置文件（除 Provider 原生启用所需的最小动作）；
- 所有状态文件 root-only、常规文件、禁止符号链接替换；
- Provider 查询错误、服务状态未知、时间解析失败均按未知处理，不得误报同步成功。

## 14. 测试矩阵

本地代码验证和 VPS 实机验证必须覆盖：

1. Debian 11：失效旧 APT 源、已有 Provider、无 Provider；
2. Debian 12；
3. Ubuntu；
4. CentOS；
5. AlmaLinux；
6. Alpine OpenRC；
7. 已有 chrony：不得安装或启用 timesyncd；
8. 已有 systemd-timesyncd：不得安装或启用 chrony；
9. 无 Provider：只安装并启用一个合适实现；
10. UTC 与 Asia/Shanghai 时区差异不被误报；
11. 系统 NTP 未同步、sing-box NTP 开启：SS2022 创建和其他协议继续可用；
12. 系统 NTP 与 sing-box NTP 同时关闭：`rem` 显示明确警告；
13. 修改 NTP Server：候选配置检查、应用、健康检查和回滚；
14. 故意制造非法 NTP Server/端口/interval：拒绝提交；
15. 时间校正超过 30 秒：按设计检查/重启 sing-box 并验证所有协议；
16. reboot：Provider、sing-box NTP、sing-box、traffic/port-hop/subscription 服务恢复；
17. 覆盖安装和 manager 更新：旧节点、流量、限速、证书、Provider 状态不变；
18. 备份恢复：恢复原 `time_sync` 设置和原节点身份；
19. 卸载：原有时间同步服务仍在运行，其他协议/防火墙规则不被清理；
20. 完整四协议回归：SS2022、VLESS、Hysteria2、TUIC 仍在一个 sing-box 进程中。

所有失败场景必须保留可审计的事务证据；测试文档和仓库中不得写入 VPS 密码、真实 token、节点 URI、真实域名、私钥或流量数据。

## 15. 明确不做

第一版不加入 GPS、PTP、硬件时钟高级管理、自建 NTP Server、多 NTP Pool UI、时区自动定位、自动修改 RTC、NTP 认证密钥管理、ntpdate 单次校时、TLS 证书申请或防火墙管理。

## 16. 实现验收标准

完成后必须同时满足：

- `manager.json` 旧数据可无损迁移并通过严格语义校验；
- 生成的完整 sing-box 配置包含合法 `ntp` 模块并通过官方 `sing-box check`；
- 系统只运行一个实际 Provider；
- 系统同步异常不会停止其他协议或整个 sing-box；
- 时间设置通过现有事务、备份、恢复和更新路径；
- 菜单、安装提示、健康检查和 SS2022 创建前检查均可见；
- 本地测试和目标 VPS 测试全部通过后，才允许按 GitHub 发布流程提交。
