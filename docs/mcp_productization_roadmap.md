# ctrlX / CODESYS MCP 产品化路线图

## 0. 与产品主路线的关系

产品执行顺序以项目仓库的 `docs/productization_roadmap.md` 为准：

1. 稳定受控 Runner；
2. 项目目录与流程生成；
3. HMI 产品化；
4. 商业交付。

本文只展开 **Phase 1 Runner** 所依赖的 MCP/core/ctrlX adapter 技术任务，不与其他阶段并行扩张。P1.1 Runner 控制面和 P1.2 工程 action 执行器已经完成；Station010 的正式 warning/semantic baseline、Build 前本机内容寻址 checkpoint 与全新 immutable action 均已复验，结果为 0 errors / 4 warnings、456 mapping，Symbol 和工程/结构哈希稳定。当前进入 P1.3：P1.3a current-user interactive Host 已实现，自动 action 消费和产品级发行仍未完成。

`codesys-persistent` 是 stdio MCP，独立 CLI 不能复用另一个进程已经持有的会话。因此 P1.2b 由交互用户会话中的唯一 Broker 持有 stdio 与 PLE，再通过本地 IPC 服务 Runner Core；不得用“每次 action 都启动一个 MCP/PLE”代替 Broker。Windows Service 也不得从 Session 0 直接启动可见 PLE。

### P1.2 已完成切片（2026-08-28）

- **P1.2a 已实现**：.NET 8 Runner Core/CLI、immutable action 与权威 operation
  ledger 绑定、hash/fingerprint 门禁、client/action-run 租约、不可变 claim/result、
  终态重放完整性复核和 release-bound evidence producer SHA；初始化器会把相同
  Runner 源码放入新项目的 `tools/runner/`。
- **P1.2b Broker 与真实 PLE 技术通道已实现**：显式启动的 interactive Broker 独占
  profile/project，并实现一个 `codesys-persistent` stdio child 与 persistent PLE 的
  owner 生命周期。受控 adapter 已提供 ownership、same-call fresh Build、fixed-category
  typed warnings 与 recursive mapping/Symbol snapshot。Named Pipe protocol v2 采用
  durable submit/query，客户端超时不抹掉已接受执行。
- Broker 在 `%LOCALAPPDATA%` 发布 current-user validated registration；客户端验证
  心跳、SID、Broker PID/start time、可执行路径/SHA、Windows session 及完整项目
  identity，调用者不能传入 Pipe/PID。Pipe 使用 `CurrentUserOnly`，Broker 同时反查
  client PID/session。
- 这些校验防止误连和跨会话混用，但不防御同一 Windows 用户下的恶意进程；同一
  Windows 用户是本阶段明确的本地信任边界。受控安装、签名与 release-bound Broker
  identity 留到商业化安全阶段。
- durable operation journal 持久化 actionId/action SHA/idempotency/state/history；
  exact replay 不重复执行。store 层区分 pre-dispatch cancel 与 engineering call 开始后
  继续完成，但当前公开 Pipe contract 仅开放 submit/query；进程中断则进入
  `UNKNOWN_REVIEW_REQUIRED`，不自动重放 Build。
- 当前 typed allowlist 仅有 `inspect_and_build` 与 `verify_after_export_2`；固定序列为
  persistent session + exact project 核验 → 前指纹 → Build 前本机内容寻址 checkpoint 创建及
  回读 → 单次 `clean_compile_project` 的同次结构化
  summary（含 correlation token、时间与 preflight）→ session/project 再核验 → 后指纹
  稳定性检查 → terminal observation。缓存型 `get_compile_messages` 不参与 fresh 成功
  判定。缺少经用户一次明确确认的 warning/semantic baseline 时返回对应 bootstrap `BLOCKED`；
  检测到 PLE 告警输出截断时以 `PLE_WARNING_OUTPUT_TRUNCATED` 失败关闭。
  无 generic MCP surface，也无在线命令。
- 提交前确认链加固已完成：一次明确用户确认即可，不采集姓名、工号或增加重复审批；AI
  candidate/triage 及改名副本不得自动作为 confirmation；confirmation/scope/baseline 均用同一有界
  bytes 完成校验、SHA 与解析；semantic adapter 在最多 4 次 Symbol 有界收敛后执行三组
  Mapping/Symbol 交叉权威读取，mapping 只比较最终封存的语义投影，并在全部 REST 读取后
  执行最终 Mapping/dirty guard；REST body 使用 30 s 全程 timeout + 8 MiB streaming cap。
  畸形请求和 evidence/candidate 敏感扫描不会持久化或回显凭据；patcher 语法失败会回滚。
- `apply_change_set_and_build` 继续返回 `BLOCKED_UNSUPPORTED_ACTION`。2026-08-28
  Broker/evidence 的显式 Clean Build、本机内容寻址 checkpoint 与正式 warning/semantic baseline
  已完成。checkpoint 位于当前用户的 Broker identity 根下，以 PLC SHA-256 寻址；同 SHA 复用，
  损坏或源漂移在 Build 前失败关闭，不提交 `.project`，也不宣称跨机器恢复。
  request `839ff68c-6ac8-4764-8258-7cef4aa10406` 的全新 Station010 action 已取得
  0 errors / 4 条完整 `OPC.UA.DA` warning，456 mapping、Symbol、baseline、checkpoint 与
  工程/结构哈希全部验证通过。P1.2 离线 action 验收已关闭；这不表示仿真、下载或真机已验收。
- Runner 的 protocol v2 timeout fixture 通过 submit/query 明确握手并由客户端 3 秒
  deadline 决定 pending，不再依赖 250 ms 调度窗口。Broker atomic JSON 仅对 Windows
  access/sharing/lock violation 做 6 次、总计约 230 ms 的有界短重试；耗尽后仍抛出，
  immutable 创建竞态继续映射为 `BROKER_IMMUTABLE_STATE_EXISTS`，临时文件照常清理。

### P1.3a current-user Runner Host（2026-08-28）

- 已实现 current-user interactive Host：单项目 owner、心跳/状态、受控停止、限定目录的
  JSONL 日志保留，以及可选的当前用户 AtLogOn Scheduled Task。
- Host 只观察同一 Windows 会话中已存在且通过身份校验的 Agent/Broker；它永不启动
  Broker、MCP、PLE、Node，也没有连接、下载、启停、变量写入或 FORCE 等在线能力。
- 同会话 Agent 不存在时状态为 `WAITING_FOR_AGENT`，不会自动启动工程工具或执行 action。
- P1.3a 只完成后台 Host 的最小生命周期。自动 action 消费、完整崩溃恢复、稳定安装目录、
  升级/回滚和团队发行仍属于 P1.3/P1.4 后续，因此整个 P1.3 仍未完成。

显式启动与只读状态/客户端命令：

```powershell
dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
  start --engineering-root '<ai-root>' --station-root '<station-root>' `
  --plc-project '<absolute-plc-project>' --profile 'ctrlX PLC 2.6.8'

dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
  status --engineering-root '<ai-root>'

dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  doctor --engineering-root '<ai-root>' --json

dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
  execute-action --engineering-root '<ai-root>' --action-path '<action.json>' `
  --expected-sha256 '<64-hex-sha256>' --broker-action-timeout-ms 1800000 --json
```

这些 `start` 命令只用于受控交互式 acceptance；Broker 是唯一可显式持有 MCP/PLE 的
执行者。真实 PLE 技术通道已验证，但没有正式 baseline 的 action 仍会失败关闭；
`status`、`doctor` 和 SelfTest 不会启动工程工具。详细的 run `status`/`verify` 命令见
`src/runner/README.md`。

## 1. 目标

把当前已验证的 `codesys-mcp-persistent` ctrlX 兼容能力，从“单机补丁 + 项目脚本”升级为可版本化、可测试、可在多个 OpCon/ctrlX 项目复用的工程工具链。

本路线图只定义通用机制，不包含任何工站 BMK、事件号、对象路径或工艺步骤。默认范围为离线工程；连接、下载、启停、运行时写值和 FORCE 始终使用独立授权边界。

## 2. 产品分层

```text
OpCon / CpStudio workflow
  Skill、项目模板、specs/ownership/hooks、导出审计、Git 与验收报告
                         |
ctrlX engineering adapter
  PLE REST/native、Symbol Configuration、connector I/O、IOE、缓存诊断
                         |
CODESYS persistent core
  进程与会话、IPC operation、工程上下文、文本对象、编译、在线基础能力
```

### CODESYS persistent core

只承载与具体机器和 OpCon 无关的能力：

- PLE/CODESYS 进程生命周期、跨进程独占租约和 watcher IPC；
- 明确的活动工程上下文、对象读写、哈希前置条件和单次保存；
- Build/Clean Build、结构化诊断和编译结果标识；
- 通用在线原语及 FORCE 账本、查询和解除能力；
- 不理解 CpStudio、BMK、Unit、Chain 或项目 Git 结构。

### ctrlX engineering adapter

封装 ctrlX PLC/IO Engineering 的 OEM 接口差异：

- PLE 2.6 REST 对象读写及 native export/import；
- Symbol Configuration 的 Select/UnSelect/读取与读回；
- `connector.host_parameters` I/O 通道枚举和批量映射；
- IOE 独立进程、EtherCAT 配置导入导出和版本门禁；
- `.precompilecache`、工程锁、REST 序列化异常等 ctrlX 专项诊断；
- 不包含 OpCon `_retVal`、`OnChainFinish`、事件文本或工艺联锁规则。

### OpCon / CpStudio workflow

由 Codex Skill、共享脚本和项目侧车模板共同承担：

- CpStudio Post-export 请求消费、Git diff 和对象归属审计；
- `specs/`、`ai/ownership.yaml`、`ai/hooks.yaml`、Catalog 和质量门禁；
- OpCon Chain 约定、Unit 调用模式、SetEvent 限制及取消清理；
- 从声明式 Chain 规格生成通用 SFC 图请求，再交给 adapter 写入；
- 项目初始化、离线验收、交接和报告。

Skill 负责选择流程和组合工具，不替代 MCP 的确定性接口，也不保存项目专属事实。

## 3. 依赖顺序与优先级

### P0：可靠性与安全基础

#### 1. 建立受控 fork 和固定发行版

将已验证的 CRLF、connector mapping、有界编译消息、PID 身份校验和 watcher 握手合并进源码，发布受控版本；停止把修改全局 npm 安装目录作为日常部署方式。

验收标准：

- 源码、构建产物和版本号可追溯，团队安装锁定精确版本及完整性校验；
- 全新工作站无需执行 post-install 源码改写即可通过 ctrlX 离线冒烟；
- CI 覆盖 CRLF、编译摘要解析、PID 复用拒绝、connector 通道发现和映射回滚；
- 旧补丁脚本仅用于迁移检查，升级不会静默丢失 ctrlX 能力。

#### 2. 跨进程独占租约

在现有单进程 mutex 之上增加 OS 级租约，绑定可执行文件完整路径、profile、workspace、工程路径、owner ID 和心跳。扩展重启只能在旧 owner 失效后接管，不得启动第二个 PLE 争抢 profile。

P1.2b 已实现 Broker 范围的 current interactive session owner lease（named mutex +
exclusive file + owner metadata）和 current-user validated registration heartbeat；推广为所有 MCP
写工具共用的通用租约、TTL 接管与 watcher 恢复仍属于本节后续工作。

验收标准：

- 两个 MCP 进程同时启动时只有一个获得写租约；另一个在有界时间内返回 owner、profile 和工程信息；
- 存活 owner 不可被强行接管；owner 异常退出后可按 TTL + watcher 握手恢复；
- shutdown 只作用于租约绑定且身份一致的 PLE，不会结束同名无关进程；
- 所有写工具在无有效租约时拒绝执行。

#### 3. 异步 operation 与幂等重试

把长耗时命令从“等待到超时”升级为持久 operation：

```text
queued -> running -> succeeded | failed | unknown
```

提供 `get_operation_status`、`wait_operation` 和仅针对未开始任务的取消；每个变更支持 caller 提供幂等键。

P1.2b 已实现 Broker action 的 durable submit/query journal、幂等冲突检测，以及
store 层的 pre-dispatch cancel、non-cancelable completion 和 crash-to-unknown 规则；
当前 Pipe 仍只有 submit/query，通用 MCP operation/cancel API 与可配置保留/清理策略
仍未完成。

验收标准：

- 超时不删除执行证据，结果至少保留一个可配置 TTL；
- 相同幂等键不会重复执行 mutation；
- 客户端能区分“未开始”“仍运行”“已成功但响应丢失”和“结果未知”；
- watcher/PLE 重启后仍能读取已落盘的最终结果；
- UI 主线程中已经开始的操作明确标记为不可取消，不伪报取消成功。

#### 4. `project_health`

提供一次调用的只读健康快照，组合 Node/OS、watcher、ScriptEngine 和 ctrlX REST 信息。

至少返回：

- PLE 完整路径、PID、profile、session、租约 owner 和 watcher 心跳；
- 当前工程规范化路径、dirty 状态、活动 Application 和库后台加载状态；
- REST 健康、工程锁和同目录 cache 状态；
- 最近 operation/build ID 及其结果是否可能过期；
- UI 主线程无响应、工程不匹配或疑似模态阻塞的明确状态。

验收标准：正常会话快速返回；UI 无响应时在固定超时内降级报告，不能让调用无限挂住；不得为体检打开、切换、保存或修改工程。

#### 5. `compile_project_v2`

接口支持：

```text
mode = build | clean_build | additional_checks
diagnostics = summary | errors | all
```

保留当前快速 Build 路径；Clean Build 只执行一次 Clean + 一次 Build，不恢复 `clean/clean_all/build/generate_code` 的重复组合。

2026-08-28 已先以独立 `clean_compile_project` 落地可选 Clean Build 技术通道：共享补丁
producer/handler 严格一次 `application.clean()` + 一次 `application.build()`，不保存工程，
并复用 fixed-category 清空、数字摘要、typed warning、工程 identity 与前后 dirty 门禁。
`semanticRebuildVerified` 表示重建调用及数字证据可信，不与 `errorCount=0` 混为一谈；
warning 文本全集另由 `warningDetailsComplete` 表示。隔离 npm fixture、全局安装、真实
PLE 隔离副本双 Clean Build 与 Broker/evidence 离线合同均已通过；这仍不等于完成下述
多模式 `compile_project_v2` 产品接口。

P1.2b Broker 已固定使用一次 `clean_compile_project`，只接受该次调用直接返回的结构化
summary，并校验 Clean/Build 各一次、correlation、preflight/postflight、session/project、
完整 typed warning 与前后指纹；缓存型 `get_compile_messages` 只可作人工补充显示，不能
证明 fresh Build。这里定义的通用 `compile_project_v2` 多模式产品接口仍未完成；当前
Clean Build 合同、正式 baseline、Build 前 checkpoint 与新的 immutable Station010 action
复验均已完成。

验收标准：

- 返回 `buildId`、工程路径/哈希、开始时间、耗时、error/warning 数和摘要来源；
- 错误与按需 warning 包含 code、对象、位置和原始文本；至少能完整返回类似 C0198 的诊断；
- 任何补充消息查询都不会把旧工程或旧 Build 缓存冒充当前结果；
- 拿不到可靠 Build summary 时失败关闭，绝不报告假 0 error；
- fast summary 与 detailed 模式均有有界调用次数，不按“全部类别 x 全部 severity”扫描。

#### 6. FORCE 生命周期闭环

把当前 FORCE 写入补齐为显式能力：`force_variable`、`list_forced_variables`、`unforce_variable`、`unforce_session_variables`。

验收标准：

- 默认离线/开发配置禁止在线 mutation；启用时仍要求短时 commissioning 授权；
- 每次 FORCE 记录工程、设备、变量、原值、目标值、owner、时间和状态；
- FORCE 后必须可读回确认，解除后也必须读回确认；
- 会话结束前能列出未解除 FORCE，不能静默遗留；
- 解除 FORCE 与施加 FORCE 使用相同的显式授权级别。

#### 7. `apply_change_set`

在稳定的租约、operation 和工程上下文之上，提供跨对象变更集：dry-run、`expectedHash`、单次保存、逐对象读回和失败恢复。

验收标准：

- 工程未明确打开、路径不匹配、dirty 策略不满足或哈希不符时零写入失败；
- 计划阶段完整验证所有目标后才开始 mutation；
- 多个文本对象成功时只保存一次；
- 任一对象失败时不保存，并恢复已变更的内存对象，或明确返回必须重新打开工程的恢复状态；
- 重试同一 operation 不重复创建对象；
- 返回 planned/created/updated/unchanged/readback-failed 的逐对象结果。

### P1：ctrlX 工程高层能力

#### 8. 正式 Symbol Configuration 工具

提供 `get_symbol_config`、`plan_symbol_sync`、`select_symbols`、`unselect_symbols` 和 `sync_symbol_config`，通过最小请求维护类型、成员和访问权限。

验收标准：

- 默认 dry-run，输出选择、取消和无法判定三类；
- 已知旧成员可以精确 UnSelect，新成员可以按预期权限 Select；
- 明确记录 REST GET 看不到失效成员的接口边界，不使用 `UpdateAll` 掩盖差异；
- 写后使用 REST 与可用的底层选择状态双重读回；
- 不覆盖无关数据类型或成员。

#### 9. 正式 I/O Mapping 工具

用结构化参数替换 `channelPath=@batch-json` 约定，提供 `list_io_channels`、`get_io_mappings`、`plan_io_mapping` 和 `batch_map_io_channels`。

验收标准：

- 能枚举 project-tree channel 和 ctrlX `connector.host_parameters` 两种通道；
- 映射项包含稳定通道 ID/名称、描述符指纹、`expectedBefore` 和目标变量；
- 支持批量绑定、清除、dry-run、逐项读回、尽力回滚和一次保存；
- 大 PDO 返回 operation 进度，表面超时后可继续查询且不会重复执行；
- 至少用数百通道 fixture 验证顺序、重复项、越界、回滚和幂等行为。

#### 10. 正式 SFC / native object 工具

提供通用 `get_plc_object`、`validate_sfc`、`apply_sfc_graph`、`export_native_object` 和受保护的 `import_native_object`。

验收标准：

- 校验 Transition 内部名称、唯一 localId、连接引用、Step/Action 引用和分支结构；
- PUT 前检查完整对象哈希，写后处理 REST GET 的规范化差异并比较读回；
- native export/import 必须限定单个目标对象并验证对象类型和预期路径；
- 线性、选择和同步分支 fixture 均能重复 round-trip，第二次执行为 unchanged；
- OpCon 返回值通道、取消清理和 Unit 命令语义由 workflow 生成/校验，不写入通用 adapter。

### P2：团队化与完整工程体验

#### 11. IOE adapter 与统一工程 facade

把现有 IOE 文件 IPC 产品化为独立 adapter，并由统一 facade 协调 PLE/IOE 的版本、租约和工程类型。PLE 永不打开 IO 工程，IOE 永不承担 PLC Application 操作。

验收标准：错误 IDE/工程组合在打开前被拒绝；IOE 关闭使用优雅路径；EtherCAT export/import、库加载等待和模态故障均有 operation 状态及恢复说明。

#### 12. 声明式项目快照与差异

建立可组合的只读 fingerprint，覆盖文本对象、图形/native 元数据、库、Task、设备、I/O Mapping 和 Symbol Configuration。输出稳定 JSON/文本，不依赖二进制 `.project` diff。

验收标准：同一工程连续快照零 diff；单一对象修改只产生预期域差异；大型设备树采用作用域和分页，不再从工程根无限递归。

#### 13. 工作流发行与兼容矩阵

独立版本化 core、ctrlX adapter、OpCon workflow/Skill 和项目模板；维护 PLE/IOE/profile/OpCon 兼容矩阵及离线 fixture。

验收标准：新工作站可由固定版本清单完成只读体检；Skill 能调用安装后的工具执行“初始化、CpStudio 导出审计、离线开发、故障诊断、离线验收”，且所有项目事实仍来自当前项目配置。

## 4. 不进入 MCP 的内容

- 任一工站的 BMK、事件号、Unit 实例名、对象绝对路径和工艺顺序；
- CpStudio 模型所有权、OpCon 层级选择及设备安全联锁决策；
- 项目 warning baseline、代码风格和业务验收策略；
- Git commit/push、GitHub 账号、HTML 展示、HANDOVER/TODO 内容；
- CpStudio GUI 鼠标自动化或直接修改 `Engineering_Data.xml`；
- 闭源 Unit/Peripheral 实现、完整手册或供应商资产副本；
- “用户是否已经批准真机操作”的推断。MCP 只能执行硬门禁，授权必须来自外层交互；
- OpCon 专用 Chain 模板。MCP/adapter 只验证和写入通用 SFC 图，模板规则留在 workflow；
- 自动删除/移动 cache 的启发式决定。adapter 可以诊断并生成明确计划，恢复动作必须显式调用且满足工程已安全关闭等前置条件。

## 5. 发行门禁

每个版本至少通过：

1. TypeScript/Python 语法、协议和纯函数单元测试；
2. 不启动 IDE 的 IPC、租约、幂等、消息解析和变更计划测试；
3. 固定 ctrlX 离线 fixture 的打开、读回、Build/Clean Build 和对象 round-trip；
4. 双 MCP 进程租约竞争、PID 复用、watcher 重启和迟到结果故障注入；
5. 明确证明测试期间没有连接、下载、启停、运行时写值或 FORCE 实体 PLC；
6. 版本升级和回滚说明，以及与前一受控版本的兼容性报告。

完成 P0 后，工具链才具备跨项目稳定复用的基础；完成 P1 后，当前项目中的 Symbol/I/O/SFC 专用脚本可逐步缩减为声明式输入；P2 用于团队部署和完整使用体验，不应阻塞 P0 的可靠性改造。
