# ctrlX / CODESYS MCP 产品化路线图

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

验收标准：

- 返回 `buildId`、工程路径/哈希、开始时间、耗时、error/warning 数和摘要来源；
- 错误与按需 warning 包含 code、对象、位置和原始文本；至少能完整返回类似 C0198 的诊断；
- `get_compile_messages(buildId)` 不会把旧工程或旧 Build 缓存冒充当前结果；
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
