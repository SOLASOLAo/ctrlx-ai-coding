# ctrlX AI Coding — 讨论与决策记录(SESSION LOG)

> 记录人:AI + AGZ1WX · 2026-08-04 ~ 2026-08-27
> 本文是过程流水账;结论性内容以 `ctrlX_AI_project_baseline.md` 为准。

## 背景

用户用 ctrlX 做工程,原 Nexeed Control plus Studio(CpStudio)低代码平台过于冗余:
- 真正需要的只是它提供的 OpCon 库与一键导出能力;
- 平台本身不好用、库数量不完善;
- 初始目标曾是让 CpStudio 退化为一次性骨架/HMI 生成器；Station010 实战后于 2026-08-20 修正为
  **CpStudio 持续维护供应商模型，AI 经 MCP/REST 维护声明归属的 PLC 应用逻辑**。

## 时间线

### 2026-08-04 ~ 08-05 · 探索起步
- 安装 `@codesys/mcp-toolkit`(headless 模式),对接 ctrlX PLC Engineering;
- config.toml 初版(`config.toml.bak_ctrlx`、`bak_20260805`);
- 确认 `.project` 为加密容器(共享 15 字节头),手改文件路线放弃,只能走 IDE 脚本引擎。

### 2026-08-06 ~ 08-11 · headless 验证与路线切换
- 完成 10 项 headless 实测:打开加密工程、create_pou/set_pou_code、读回校验、全工程编译(0 errors)、
  create_project 新建工程(自带 OpCon 骨架 + 34 库占位符)、resource 读取、库管理等;
- 关键结论 ①:**PLC 侧可完全绕开 CpStudio**(库已在本地托管仓库,占位符编译时自动解析);
- 关键结论 ②:**headless 模式在 ctrlX 品牌 IDE 不可用**(脚本末尾无退出补丁,进程挂死)→ 切换 persistent;
- 08-11:config.toml 切换为 `codesys-persistent`(旧块注释保留),产出基线文档 MD + HTML。

### 2026-08-11 · 分工确定
- **用户**:CpStudio 搭骨架(Station/Module/Command 层级、HMI、handler/变量、库导出、骨架模板制作);
- **AI**:PLC 代码细节(SqM_Auto/Manual、SqS 序列、工艺逻辑、编译-修复闭环、下载调试辅助);
- 干净的 OpCon 骨架模板:AI 不代做,归用户。

### 2026-08-12 上午 · persistent 上线排障
- **IDE 自行退出(code 0)**:3 个并行 node MCP server 抢同一 profile 竞态 → 规则:同一时间只开一个 Codex 窗口;
- **CRLF 缺陷**:`get_compile_messages` 报 `SyntaxError: unexpected token '\r'` → 修补 watcher.py(行尾归一化)+ `_message_utils.py` CRLF→LF;
- **eval_python 陷阱**:对已打开工程裸调 `se.projects.open()` 卡死 UI 线程;恢复 = shutdown_codesys;正确姿势 `se.projects.primary`;
- 冒烟:compile **0 errors / 35 warnings**(培训样板固有符号警告),构建日志 Ready for download。

### 2026-08-12 下午 · 文档归档与仓库建立
- 08-12 验证过程写入基线 MD 第 7 章;
- 归档 GitHub 过程中发现:**昨日补丁脚本误吞 watcher.py 首行 docstring 引号**(`"""`→`""`),
  文件带语法错误仍在被引用 → 立即以 orig + 补丁重建规范文件(LF、无 BOM),py_compile 通过,
  MCP 实测仍正常(session ready,get_compile_messages 0.7s 返回);
- 建立本仓库:docs / config / patches / scripts / mcp_test,补丁产品化(一键脚本 + diff + 说明)。

### 2026-08-12 深夜 · 路线④开发机盘点与 FreePLCDemo 立项
- 开发机(i7-8700/8G,Ubuntu 22.04.5)实测:内核 6.12.100-rt20 PREEMPT_RT 激活;隔离核 5,11 生效;
  既有 PreemptRt 系统健康(io_master 核5 SCHED_FIFO 98 1kHz,lat_us≈65µs);从站柜未上电(link=false);
- cyclictest 基线 v1:max 182µs(T0@普通核,-i200 -l1M,无 -q,loadavg 4.4);教训:基线测试必须 -q;
- 发现 OpenPLC v3 service failed 新根因(.venv 内 20 个符号链接被 Windows 转成 reparse point,Linux 不可读),
  与既有 §4.1 runbook 不同,reset-failed 无效 → 决策弃 v3(D13);
- 修订 templates/(补 Linux 派生命令、显式会话循环、data/ 约定、衍生项目登记);
- 从模板派生 FreePLCDemo(D14),四文档写入实测事实;route4 HANDOVER §7 / TODO 全面更新。

### 2026-08-12 晚 · FreePLCDemo 设计定案 + v4 上线
- 设计讨论全部定案(存档 FreePLCDemo/docs/design-discussions-2026-08-12.md):
  P4=路线 A(igh_shm 插件);周期=总线 1ms×扫描 10ms;cycle 线程绑核 11;
  seq 咬合+双拷防撕裂;喂狗协议(manual_mode+heartbeat 2s);HMI=Avalonia(D10)+OPC UA;
- OpenPLC v4 安装完成并运行(:8443+JWT);安装坑:cmake≥3.28(pip 清华源)、tarball 非 git 仓库(跳过原生插件);
- HMI Web 原型上线 :8091(代理网关规避 dashboard 无 CORS);SOEM 原生插件未构建=物理防误用。

### 2026-08-12 深夜 · 路线④ P4 全链路闭环 🏆
- 网络定案:eno1 静态 .77(通 Windows .88),USB 移动 WiFi metric 500 分流;
- OpenPLC v4 安装(:8443+JWT);Editor v4.2.11(Windows)editor-driven 全流程跑通(task=10ms);
- **igh_shm 插件上线并闭环**:ST 程序 → runtime(核11 FIFO)→ shm → io_master → EL2008 物理输出,
  从站柜 20 站全 OP(wc=27/27);输入 %IX 已通(柜内 DI 实测进镜像表);
- Editor 兼容补丁:plcapp_management.py 保护插件(igh_shm 恒开/SOEM 恒关;升级 runtime 需重打);
- 详见 FreePLCDemo/{HANDOVER,docs/p4-integration-design}.md;剩余:P5 抖动报告 + P6 HMI(Avalonia)。


### 2026-08-13 · OpenPLC v4 调研与 Editor 安装(支撑 D13 editor-driven 模式)
- **OpenPLC Editor v4.2.11**(Autonomy-Logic,Electron+React)静默安装到 Windows 机 `PLC_Generate\FreePlc\`,启动验证通过;
- 查明 Runtime v4 连接机制:**HTTPS 8443 + JWT**(create-user 首个=admin)、**无 Web UI**;Editor 本地 STruC++ 编译 → zip 上传 → Runtime Make 编 .so;WebSocket 调试;UDP LAN 发现;协议内置 EtherCAT API(D13 自定义层不受影响,仅作参照);
- 踩坑:Electron 应用终端继承 `ELECTRON_RUN_AS_NODE=1` 致 Editor 变 Node 静默退出(exit 9),桌面启动正常;
- 公司代理拦截 release CDN → `gh release download`(走 api.github.com)绕过;
- 与另一会话(abff186 开发机盘点)合并:本条目为增量,不覆盖 FreePLCDemo 执行线。
### 2026-08-18 · 阶段2实战:Station010 IO 硬件组态修复 + IOE-IPC 工具链
- 派生项目 BPP_ResistantStation(Stat_Resistant_AI_Coding)按电气图核对 Station010 IO 组态;
- 发现 PLE 2.6.8 打开 IO 工程触发版本转换且实例崩溃 → 决策 D16:IO 工程只由 IOE 2.6.4 脚本驱动;
- 新工具 scripts/ioe_ipc.ps1:复用 MCP watcher 机制(--runscript + %TEMP%\ioe-ipc 文件命令队列)驱动独立 IOE 实例;open/树遍历/remove/save 全通;
- 真工程修复:删坏节点 _100A740_BL(Burster 5877A 为 USB 设备,误挂 EtherCAT),树与图纸页4一致(EK1100 → A1-A4 EL1018×4 + C1-C3 EL2008×3),typeId 逐项校验;备份 .bak_20260818;
- 9 条踩坑归档 docs/ioe_scripting_playbook.md(对话框阻塞主线程、.~u 残留锁、Environment.Exit 强退、插件初始化竞态、cp1252 回显假警报等)。

### 2026-08-20 · MCP 编译完成后超时修复

- 复现 Station010 的 Application Build 已在 PLE 完成，但 `compile_project` 超过 300 s；单独按消息类别/严重级别读取也超过 180 s。
- 定位为原 MCP 的重复构建与 `get_message_objects(category, severity)` 全组合扫描，而不是 PLC 编译本身。
- 扩展 `apply-crlf-patch.ps1`：应用工程只执行一次 `ScriptApplication.build()`，只按类别各调用一次 `System.get_messages(category)`，并以 IDE Build summary 计数；摘要不可验证时失败关闭。
- 同步覆盖 `compile_project` 与 `get_compile_messages`，增加 `test-fast-compile-message.py` 离线回归；`dist/scripts` 与 `src/scripts` 一起修补且 `-Check` 幂等。
- Station010 离线实测：编译约 7.6 s 返回 0 errors / 7 warnings；缓存读取约 0.8 s。未连接、下载或运行实体 PLC。

### 2026-08-20 · 跨项目初始化、Post-export 队列与 Codex Skill

- 用户确认未来会用同一方案开发多台自动化设备；把 Station010 的目录经验提炼为通用 AI 旁车模板与事务化初始化器，拒绝覆盖、统一相对路径且不复制 `.project`/Std/闭源资料。
- Post-export 从单一覆盖信号升级为 `pending/processing/done/failed` 独立队列；离线消费者只做 Git/指纹/ownership 审计，锁后枚举避免 stale candidate，并强校验请求 Station/PLC 与项目配置一致。
- 建立并安装 `ctrlx-opcon-engineering` Skill，明确初始化、导出审计、PLC 离线开发、故障诊断可组合；两轮独立前向测试发现并推动修复模板缺执行器、profile 硬编码和错误工程请求门禁。
- 产品化边界与优先级归档 `docs/mcp_productization_roadmap.md`；下一阶段先做受控 fork、会话租约、operation、`project_health`、`compile_project_v2` 与 `apply_change_set`。

### 2026-08-22 · Post-export Stage 2 PlanOnly operation ledger

- 新增 `Invoke-PostExportEngineering.ps1`：把成功的 Stage 1 报告转换为幂等 operation、不可变 action 和哈希绑定 evidence，覆盖 clean、repair、CpStudio-owned、条件 Export #2 与最终验证状态。
- 协调器只维护旁车状态，不启动 PLE、MCP 或 REST，也不访问实体 PLC；action 必须由当前唯一 persistent Codex 会话执行。
- 新增 `New-PostExportRunnerEvidence.ps1`：只验证/封装当前 runner 的显式 observation，重验 action、Stage 1、ownership、所需关键 Station 指纹、Build/PLC SHA，并生成确定性的 warning signature multiset；不会启动或调用工程工具，也不会默认把验收项设为 true。
- 新项目模板、初始化器自测、质量门禁和 `ctrlx-opcon-engineering` Skill 已同步；live engineering runner 仍由唯一 persistent Codex 会话承担，真正的跨进程 MCP 租约仍未实现。

### 2026-08-23 · 用户本地离线 Post-export checker

- 新增双击入口、PowerShell 生命周期控制器和 MCP stdio helper；仅在没有既有 PLE/MCP/工程锁时启动一组 owned 会话，执行 open + strict no-save fresh Build + messages + shutdown，不调用编辑/保存或任何在线工具。
- MCP 兼容补丁新增 strict no-save v2：dirty 状态不可确认或工程为 dirty 时拒绝 Build；checker 同时验证工程 SHA256、owned PID/父子关系、退出和锁释放，fresh evidence 与缓存诊断分离。
- Export #2 使用可验证 anchor：只由 Export #1 的 fresh verified 0-error Build 和带时间戳 request 建立，可跨对象占用、次数纠正、Output 确认及 Build 前 Link I/O 继续；进入 Build 即消费，旧终态不能复活；无 request 时不生成不可关联 anchor。
- 全局锁覆盖 anchor 选择到报告原子写入；竞争、权限、锁文件或锁目录异常均失败关闭且不落报告。根模板各 458 项离线断言、初始化器 65 项断言通过。真实生命周期 smoke test 因机器仍有既有 PLE/MCP owner 与 `.project.~u` 而按门禁延期，未强杀或手删锁。

### 2026-08-27 · Controlled Runner P1.1

- 产品顺序固定为 Runner → 项目/流程生成 → HMI 产品化 → 商业交付；当前只推进 Runner。
- 模板新增 P1.1 单一入口：校验项目/profile/manifests，使用 OS 排他文件租约，串联已有 Stage 1 审计和 Stage 2 PlanOnly ledger，并写结构化 run manifest。
- P1.1 不启动 PLE/MCP、不执行 immutable action，也没有任何在线或部署能力；当前项目和模板自测各 30 项断言，新项目初始化器 70 项回归通过。
- stdio MCP 不能由独立 CLI 复用。P1.2 必须由交互用户会话中的唯一 Agent/Broker 独占 stdio 与 PLE；未来 Windows Service 只做队列、策略和证据，不从 Session 0 启动可见 PLE。

### 2026-08-27 · Controlled Runner P1.2a Action Client

- 新增 .NET 8 Runner Core/CLI：严格校验 Stage 2 action/hash、工程/profile、
  ownership/fingerprint、guardrail 与 evidence contract。
- 新增 OS 级 client/action 双租约、不可变 claim/result、终态重放和本地验证；
  相同 action 不会重复送往 Broker，残缺 claim 进入 `UNKNOWN` 等待人工复核。
- action 额外绑定 `operation.json.currentAction`；每次终态重放都会重新核对 result、
  observation、evidence、guardrails 与 SHA，篡改或 ledger 漂移均在 Broker 前拒绝。
- 当时新增本地 Named Pipe v1 client，只连接已存在的 Broker并核对实际 server PID
  与当前 Windows session；它已由下一节 P1.2b protocol v2 current-user validated registration +
  submit/query 替代。evidence producer 由发布 SHA 固定。
- P1.2a client 本身不启动 PLE/MCP/Broker，也不含在线工具；该切片结束时 P1.2b
  尚待实现，当前状态以紧随其后的 P1.2b 记录为准。写工程 action 继续 fail-closed。
- Release Build 为 0 errors / 0 warnings；SelfTest 14/14、176 assertions；新项目
  初始化器 81 assertions，并同时编译生成后的 Runner、执行 Doctor 与 wrapper
  不触发 `dotnet run` 的防回退检查。

### 2026-08-27 · Controlled Runner P1.2b Interactive Broker

- 新增必须由用户显式启动的 interactive Broker；它使用 current-session owner lease
  独占 profile/project，并实现唯一 `codesys-persistent` stdio child 与 persistent PLE
  session 的 owner 生命周期。当前已安装 adapter 缺少新契约，生产路径会在启动 PLE
  前安全阻断。CLI/client、`status`、`doctor` 和测试不会替用户启动 Broker/PLE/MCP。
- Named Pipe 升级为 protocol v2 durable submit/query：submit 先落盘并返回 acceptance，
  随后客户端按 execution ID query；已接受后发生 timeout/cancel 只表示客户端停止等待，
  不会把仍在 Broker 中执行的 Build 伪报成未执行或失败。
- `%LOCALAPPDATA%` current-user registration 绑定 heartbeat、SID、Broker PID/start time、
  executable path/SHA、Windows session、MCP/PLE PID、persistent session 和完整 project
  identity。客户端只使用 canonical registration discovery，不能传 Pipe/PID；Pipe
  采用 `CurrentUserOnly`，Broker 反查 client PID/session。
- registration 是 current-user validated，而不是抵御同用户恶意代码的安全根；同一
  Windows 用户是本阶段明确的信任边界，受控安装/签名/release-bound identity 后续实现。
- durable operation journal 保存 actionId/action SHA/idempotency 与完整状态历史；exact
  replay 不重复执行。store 层区分 pre-dispatch cancel 与 engineering call 开始后的
  non-cancelable completion，但当前公开 Pipe contract 只有 submit/query；Broker 中断
  期间的调用进入 `UNKNOWN_REVIEW_REQUIRED`，不得自动重复 Build。
- typed allowlist 当前仅开放 `inspect_and_build`、`verify_after_export_2`；
  `apply_change_set_and_build` 继续 fail-closed。固定离线序列为 session/exact project
  核验 → 前指纹 → 单次 `compile_project` 同次结构化 summary/correlation/preflight
  核验 → session/project 再核验 → 后指纹稳定性 → terminal observation；缓存型
  `get_compile_messages` 不参与 fresh 成功判定；没有
  generic MCP、连接、下载、运行时启停、变量写入或 FORCE surface。
- 当前离线回归为 Runner **24 cases / 196 assertions**（连续三轮）、Broker **12/12**（连续三轮）、
  Engineering fake MCP **9/9**，使用 fixture、fake engineering session 和本地 Pipe，
  测试期间未启动 PLE/MCP/工程工具。**尚未执行实体 PLE
  acceptance**；因此当前不宣称真实 PLE、仿真、下载或实体 PLC 已验收。
- 已消除两处 Windows 回归抖动：protocol v2 fake Pipe 以 submit/query 握手和 3 秒
  客户端 deadline 确定 pending，不再赌 250 ms 调度；Broker atomic JSON 只对
  access/sharing/lock violation 做 6 次、总计约 230 ms 的有界短重试，耗尽仍失败，
  immutable 目标竞态保持 `BROKER_IMMUTABLE_STATE_EXISTS`，临时文件保持清理。
- 显式操作入口：

  ```powershell
  dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
    start --engineering-root '<ai-root>' --station-root '<station-root>' `
    --plc-project '<plc-project>' --profile 'ctrlX PLC 2.6.8'

  dotnet .\src\runner\CtrlX.OpCon.Runner.Broker\bin\Release\net8.0\vcrunner-broker.dll `
    status --engineering-root '<ai-root>'

  dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
    doctor --engineering-root '<ai-root>' --json

  dotnet .\src\runner\CtrlX.OpCon.Runner.Cli\bin\Release\net8.0\vcrunner.dll `
    execute-action --engineering-root '<ai-root>' --action-path '<action.json>' `
    --expected-sha256 '<64-hex-sha256>' --json
  ```

  以上是 2026-08-27 切片结束时的 acceptance 边界；2026-08-28 的真实通道结果见
  下一节。完整 client run `status`/`verify` 示例见 `src/runner/README.md`。

### 2026-08-28 · Controlled Runner real PLE channel acceptance

- 受控 adapter 的 ownership、same-call fresh Build、fixed-category typed warning 与
  recursive mapping/Symbol snapshot 已应用到本机，并通过 isolated readiness、全局
  `-Check`、Python/Node 语义向量和 .NET 工程会话回归。
- Station010 的新 immutable `inspect_and_build` action 通过唯一 interactive Broker
  调用真实 PLE；能力账本恰好为 `get_codesys_status`、`compile_project`、
  `get_ctrlx_semantic_snapshot`。没有第二个 PLE、工程写入或任何在线能力。
- fresh Build 为 **0 errors / 101 条可见 warnings**，typed warning records 可审阅；semantic
  snapshot 为 456 条 mapping facts，mapping SHA-256 `491B719C...A5086`，Symbol
  SHA-256 `3FE32193...E686F`。PLC project 与结构哈希前后完全一致。
- warning candidate 含 `PLE_WARNING_OUTPUT_TRUNCATED`，因此 101 条不证明完整告警全集，
  正式 warning baseline 当前不可批准。安装资源与官方 REST v2 schema 的只读核对已确认
  100 条是工程 `Compile Options` 的编译器生成上限，不是 MCP/ScriptEngine 的读取分页。
  下一步只在隔离副本中验证 `CompileOptionsEditor.maxCompilerWarnings=<no limit>` 的
  GET/PUT/readback/Build/回滚事务，再生成新 action/candidate。
- 该 action 因缺少经人工审阅的 baseline 正确停在 bootstrap `BLOCKED`，不是 `DONE`。
  候选只能进入 `pending-human-review`；不得自动晋升，正式 baseline 建立后必须用新的
  immutable action 复验。

### 2026-08-28 · Controlled Runner fail-closed review hardening

- 独立审查发现并关闭了四类证据窗口：candidate/AI triage 冒充人审、review/baseline
  hash 与解析内容的重复打开竞态、semantic 最终 REST 读取后的 dirty race，以及 REST
  body 在 header 后失去 timeout/先整体缓冲再检查大小。
- Stage 1/2 现在只接受 `docs/reviews/` 下单独的人审文档，并拒绝已知生成物及其改名
  副本；review、scope、warning/semantic baseline 都以同一有界 bytes 完成校验、SHA
  与解析。畸形请求及候选/evidence 敏感扫描不持久化或回显凭据。
- semantic adapter 增加 traversal 前后 dirty 与最终第三次 ScriptEngine probe；REST
  使用 30 s 全程 abort、8 MiB 流式上限。patcher 语法失败非零退出并恢复本轮写入。
- 离线回归通过：Runner 196 assertions、Broker 13/13、Engineering 37/37、Release 0/0、
  root/template PS5.1 tests、adapter readiness 与全局 `-Check`。没有启动 PLE/MCP，未触碰
  Station010/PLC/CpStudio/Std。warning 截断和人审 baseline 仍是最终 P1.2 blocker。

### 2026-08-28 · Isolated warning limit and explicit Clean Build

- 官方 PLE REST v2 `CompileOptionsEditor.maxCompilerWarnings` 已在 manifest 绑定、同 SHA
  的可丢弃副本完成 `100 → <no limit> → 100`、精确 readback 和回滚；源/副本
  `.project` 字节均未改变。
- REST PUT 即使恢复原值仍令 PLE 内存工程 dirty。隔离工具不保存，并强制要求关闭不保存
  后重开/丢弃；普通 compile 的 no-save guard 继续失败关闭。
- 普通 `application.build()` 受路径/增量状态影响：原路径显示 101 条可见 warning，同字节
  隔离路径显示 4 条；移除/复制 cache 与 user option 均未让两者收敛，因此都不能作为正式
  语义基线。
- `2c23612` 新增 `clean_compile_project`：恰好一次 `application.clean()` 和一次
  `application.build()`，包含 identity/dirty/fixed-category/typed-warning 证据，不调用 save、
  `clean_all`、`generate_code` 或在线操作；`ffa596a` 新增隔离 warning-limit 工具。补丁已安装，
  全局 `-Check` 和离线事务回滚回归通过。
- 新项目模板同步写入显式 Clean Build 门禁，并以 ASCII
  `RUNNER_ACCEPTANCE_CONTRACT` 固定该合同；初始化器在 Windows PowerShell 5.1 下完整通过
  106 项验收，避免无 BOM 测试脚本中的中文 literal 被系统代码页误解。
- 当时剩余门禁为重启 MCP 扩展后执行隔离副本持久化与双 Clean Build；该历史待办已由
  下一节验收结果关闭。

### 2026-08-28 · Persisted unlimited limit and repeated Clean Build acceptance

- Codex 扩展重启后已加载 `clean_compile_project`。`maxCompilerWarnings=<no limit>` 仅保存到
  manifest 绑定的可丢弃隔离副本；正常关闭并重开后精确读回仍为 `<no limit>`，Station010
  源工程没有保存该设置。
- 隔离副本连续两次显式 Clean Build 均为 **0 errors / 4 warnings**。两次 warning 多重集
  完全一致，四条 typed record 都是 `The attribute OPC.UA.DA is unknown and will be ignored by
  the compiler.`；records、diagnostic rows、warning details、summary、category coverage、
  identity 与 dirty 证据均完整，没有截断 sentinel。
- Station010 PLC 源工程 SHA-256 始终为
  `0F9557B3F5100E4FF44EBF1BE30C5833EFE11F1E02D8A8AB3991DD24640734CA`。没有连接、下载、
  启停、变量读写、FORCE 或其他在线操作，也没有修改 CpStudio、IO 或 `Std`。
- Broker/evidence 已接入 `clean_compile_project`，相关 Runner/Broker/Engineering/Stage/
  evidence/candidate/initializer 离线测试全部在 PowerShell 7 下通过。这只完成技术合同和
  告警完整性门禁；本轮新的正式 immutable action/candidate 尚未生成，人工 warning/
  semantic baseline 尚未审阅或建立，bootstrap 状态继续保持 `BLOCKED`。

### 2026-08-28 · First real Export action and Symbol warm-up hardening

- 真实 CpStudio Export request `08bd1cc9-f16d-4903-99ff-7d83a88b0dae` 已经 Stage 1 精确消费，
  并生成 immutable action `cpstudio-stage2-08bd1cc9-f16d-4903-99ff-7d83a88b0dae-c7a0ea87-0001`。
  Broker 受控执行得到完整 Clean Build **0 errors / 4 warnings**；四条均为相同的
  `OPC.UA.DA` attribute warning，工程 SHA 和 structure SHA 执行前后未变。
- 首次 semantic snapshot 失败关闭。只读复测证明 Clean Build 后 Symbol Configuration 的
  第一次成功 REST GET 可能仍是异步重建中的短响应，随后才返回稳定完整响应；这不是放宽
  dirty、mapping 或双读一致性门禁的理由。
- 语义适配器现在只丢弃一次有界 Symbol warm-up GET，再执行原有两次权威读取；权威双读
  任一差异仍失败关闭。回归显式使用“首读瞬态、后两读一致”的三段 payload，并继续覆盖
  权威读取变化和最终 dirty probe。旧 canonical block 只能通过精确 SHA allowlist 升级。
- 原 action 已以 `BLOCKED` evidence 封口且不可复用。完整 warning evidence 已生成待人审
  candidate；semantic candidate 必须由下一次真实 Export 产生的新 action 使用修复后的适配器生成。

### 2026-08-28 · Second real Export action and semantic-projection stabilization

- 第二次真实 CpStudio request `fa0c5fa1-3fff-4b3c-a8d3-05f590538fb4` 生成并执行 immutable
  action `cpstudio-stage2-fa0c5fa1-3fff-4b3c-a8d3-05f590538fb4-d8fa7348-0001`。Clean Build
  为 **0 errors / 4 warnings**，四条均为完整 `OPC.UA.DA` warning；工程文件与 structure SHA
  前后完全一致，没有任何在线操作。
- action 在 semantic snapshot 双读稳定性处失败关闭；旧证据把 Project、Mapping 与 Symbol
  合并成同一错误，因此不能反推本次具体变化层。代码审查同时发现原适配器比较 raw mapping
  arrays/scopes，而最终封存的是去掉 `resolved/mappingReadable/error` 并排序后的语义投影；
  raw 顺序或内部字段变化会造成假阳性。一次 Symbol warm-up 也不足以覆盖多阶段异步重建。
- 新适配器把 mapping 读取统一投影为最终 canonical facts 后比较 SHA；工程 identity 使用
  action 路径的规范化大小写；Symbol 最多做 4 次有界 settle 并要求连续两读一致，之后丢弃
  settle 数据并执行三组 Mapping/Symbol 交叉权威读取，最后再做一次 Mapping/dirty guard。
  这样同时关闭 mapping raw 表示噪声和最后一次 mapping 期间 Symbol 变化的 TOCTOU 窗口；
  REST timeout、streaming body cap 与 compact MCP response cap 均未放宽。
- 失败诊断只包含不稳定组件名、记录大小与 SHA，不携带 mapping records 或 Symbol body。
  多阶段 Symbol、永不收敛、mapping 内部噪声、真实 mapping 语义变化和 final dirty 等离线回归
  均通过；完整 adapter readiness 及全局安装/`-Check` 通过。
- 第二个 action 已封口且不可重跑；warning candidate 可生成，semantic candidate 仍需下一次
  真实 Export 的新 action。之后仍须独立人工审阅并创建正式 baseline，再用后续新 action 复验。

### 2026-08-28 · Adapter/Broker contract alignment and complete candidates

- 第三次真实 action 的 Clean Build 为 **0 errors / 4 complete warnings**，但以
  `SEMANTIC_ADAPTER_EVIDENCE_INVALID` 失败关闭。根因是 adapter 已升级为 triple-read、
  bounded-settle、raw-SHA 合同，而 Broker acceptance 仍硬编码旧 mapping/Symbol source
  元数据；这属于 Runner 自身合同版本漂移，不是 PLC、I/O 或 Symbol 语义错误。
- Broker 已精确同步新版合同：mapping source 必须是三组语义投影读取加最终
  mapping/dirty guard；Symbol source 必须绑定 action application/REST endpoint，并证明
  2–4 次 settle、3 次权威读取、raw payload SHA 与 8 MiB 上限。故障注入覆盖旧 source、
  缺失 SHA、settle 边界、权威次数、body 上限及 application/endpoint 漂移。
- 新真实 CpStudio Export request `cb1af562-25e6-4523-b2d8-037751d9433d` 生成 action
  `cpstudio-stage2-cb1af562-25e6-4523-b2d8-037751d9433d-633764e6-0001`。修复版唯一 Broker
  完成 Clean Build **0 errors / 4 complete warnings** 和稳定 semantic snapshot；工程与结构 SHA
  前后不变，没有在线、下载、启停、变量写入、FORCE 或第二 PLE。
- action 正确停在 `SEMANTIC_BASELINE_BOOTSTRAP_REQUIRED`。已生成待人审 warning candidate
  和 semantic candidate：456 mapping records（438 bound / 18 unbound），mapping SHA
  `491B719CA3FFDB28855CF207538B3CB0F1AAFD7C29AD5B577FBC5AACF51A5086`，Symbol SHA
  `3FE32193B8EAC6FE03662F92BC2EF5AFF0827131C7C7226A2154FD6F2C8E686F`。自动化技术门禁已完成；
  正式 baseline 仍必须由独立人工证据建立，并由另一个新 Export/action 复验。

## 2026-08-28 无身份正式 baseline 建立

- 新增通用 `Approve-PostExportBaselines.ps1`：用户只做一次明确确认，工具校验两个候选的 project/action/count/hash 后，原子生成两份正式 baseline 和去身份确认记录；不要求或保存姓名、工号。
- Station010 正式记录为 4 条 warning / 1 个签名、456 条 mapping / 18 个当前不用的 unbound，review ID 为 `approval-3761fac2d36b-074f9525c2c7`。两份 baseline 绑定同一确认记录和 SHA。
- PowerShell 7 的审批、Stage 1、Stage 2、candidate、evidence、静态回归通过；本轮没有启动 PLE/MCP 或执行任何在线操作。最终 P1.2 验收只剩新的正常 Export 和全新 immutable action。

## 2026-08-28 最终 baseline action 与恢复门禁冲突

- 首个新 action 在 Build 前遇到 PLE 工程树瞬时未就绪并以 `PROJECT_STRUCTURE_READ_FAILED` 封口；Broker 现仅对该只读 resource 增加 500 ms 间隔、最多 30 s 的有界重试，取得有效前快照前绝不进入 Build。
- 新真实 request `aadf8692-07e0-4862-b525-5dcfd0b78fb0` 的 action 完成 Clean Build **0 errors / 4 warnings**，456 mapping、Symbol 和正式 baseline 全部匹配，工程与结构 SHA 前后不变且无在线操作。
- action 仅因 `RECOVERABLE_BASELINE_NOT_AT_HEAD` 阻断。当前 Git-blob 证明与 D8 的 `.project` 不入库规则冲突；禁止为变绿而提交二进制或删除门禁，下一步改为可验证、可恢复且不入 Git 的最小合同后再执行新 action。

## 2026-08-28 本机 checkpoint 与 P1.2 最终验收

- recoverable-baseline 已改为 Build 前本机内容寻址 checkpoint。Broker 在有效的工程文件/结构前快照之后、`clean_compile_project` 之前，按当前用户、工程 identity 与 PLC SHA-256 创建不可变 `.project` blob；同 SHA 精确复用，损坏 blob 不覆盖，源工程漂移或 checkpoint 校验失败时 Build 次数保持 0。
- Broker、Engineering、Runner、项目框架和新项目初始化器回归均通过；生产路径不依赖 Git HEAD、不提交 `.project`，也不自动恢复。恢复范围明确为 `current-user-local-machine`。
- 精确消费新的 CpStudio request `839ff68c-6ac8-4764-8258-7cef4aa10406` 并执行全新 immutable action `cpstudio-stage2-839ff68c-6ac8-4764-8258-7cef4aa10406-282dae08-0001`。Clean Build 为 **0 errors / 4 warnings**，456 mapping、Symbol 和正式 warning/semantic baseline 全部匹配；PLC/结构哈希前后不变。
- checkpoint 为 1,991,792 bytes，SHA-256 `8274453076502750908CFC72353EB925A0504805F84B73E28DCD2FCCB18C79FD`，与 action 前后的 PLC 工程一致。operation revision 2 最终为 `DONE`，不要求 Export #2 或修复。
- 全程无 connect、download、runtime start/stop、变量写入、FORCE、第二 PLE 或 `Std` 修改；Broker/PLE 已关闭且无 `.~u`。P1.2 至此完成，后续进入 P1.3 Windows Runner Host。

## 2026-08-28 Host 无黑窗启动验证

- Scheduled Task 改为启动 WinExe GUI-subsystem apphost；`Status/Stop/Logs` 保持经
  `dotnet + DLL` 调用。完成 stop/uninstall/build/install/start 后 Host 为 `WAITING_FOR_ACTION`。
- Host 无子进程，验证前后未新增 WindowsTerminal/OpenConsole/conhost，22 个既有
  claim/result marker 未变化。该早期检查点当时尚未完成 P1.3c，coordinator/evidence
  ingestion、完整 payload pin 与稳定安装/升级/回滚留给随后收口，不扩展本轮范围。

## 2026-08-28 P1.3c 自动摄取与 immutable release 生命周期

- 在上述历史检查点之后，Host 已补齐自动 result/evidence 摄取：只接受 fully verified
  terminal result，以 result 中的 expected evidence SHA-256 为绑定，并在只读文件锁期间调用
  release-bound 的纯离线 Stage 2 coordinator。合法无 evidence 终态保持
  `WAITING_FOR_COORDINATOR` 人工复核且不重跑；busy 有界退避，任何其他 fresh ledger 异常阻断。
- Host runtime 固定为五文件内容寻址 immutable release。Scheduled Task 同时 pin 精确
  `releaseId` 与 manifest SHA-256；`Install` 已覆盖首次安装和升级，`Rollback` 已覆盖精确上一
  release，普通切换故障注入会自动恢复源 task/release/运行状态。
- 本机完成 stop/build/install/start、升级、rollback、再次升级和失败恢复阶段性验收。当时 active release
  为 `d19514130c55b14f9bb43890db0b8d1e4114af2bccd44665cec2396dd1357248`，previous release
  为 `e80f3023f23e414603f6a4f0778b2f5bbdac1b2d63d0002c90ff9a59a51f8cc7`，active manifest
  SHA-256 为 `88C4AF0755A1F3A18C125689FA83AC6252DDCBC06C33EB253427B89622B8F37E`，Host 最终为
  `WAITING_FOR_ACTION`；P1.3c 收口后的当前 release 见下一节。
- 本轮 Host/Stage 2 路径没有启动 Broker、MCP、PLE、Node 或在线 PLC 操作，也不新增真实 PLE、
  仿真或真机验收声明。该检查点当时仍缺 release 切换强杀窗口的 durable deployment
  journal/reconcile、production ingestor 完整 fixture E2E 和团队发行门禁；后续收口见下一节。

## 2026-08-28 P1.3c durable recovery 与 production ingestor 收口

- production 默认 Stage 2 ingestor 的独立 SelfTest 已以真实 PowerShell coordinator 路径完成 6 项
  fixture E2E：Host 默认摄取、有效 DONE、有效 BLOCKED、真实 workflow ledger 独占锁映射为
  `STAGE2_COORDINATOR_BUSY` 且 operation/evidence/action 零 mutation、evidence SHA 漂移拒绝，
  以及无 evidence UNKNOWN 保持人工复核。标准命令为：

  ```powershell
  dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest.csproj -c Release
  ```

- release 切换现以 durable pending journal 记录阶段并在下次显式 lifecycle 入口 reconcile。纯离线
  failpoint matrix 与参考工作站真实断点/进程强杀均已覆盖切换窗口；升级、精确 rollback、损坏候选
  拒绝及普通故障恢复通过，journal 不会在未证明 source/target 终态时被删除。
- 显式 `Uninstall` 复用 fail-closed task 校验：root、current user、action 和 settings 必须精确；只对
  已知 legacy build-output task 容忍 stale binary description pin，已禁用的中断卸载不会被重新启用。
  `deployment.json` 缺失时，仅可从 task 的精确 `releaseId + manifest SHA-256` 反推 immutable
  release，并在 manifest/五文件 payload 完整校验后安全卸载；unknown/tampered task 阻断。
- Scheduled Task action 精确指向 active release 的 `payload\vcrunner-host.exe`，description 记录
  releaseId 与 manifest SHA。wrapper 的显式 lifecycle 校验五文件 manifest，并在启动、切换和
  安全卸载路径执行 apphost self-check；AtLogOn 任务自身直接启动 action，不会预先独立检查
  `.deps.json`/`.runtimeconfig.json`。
- 参考工作站最终 active release 为
  `faa27c1d79415996ddcd524833160c57ea23ac63888f17b853487a81b46ab0f1`，active manifest SHA-256
  为 `20c15444dd84bd85859c8c56f47ff47fd39d027034c60d02ccbc4158e0714395`；previous release 为
  `ac89b28f9a93a61c10b5bd7731c3b5b83288169a105c62eb4218a30c119f4b51`，Host 为
  `WAITING_FOR_ACTION`。P1.3c 技术实现和参考工作站验收完成；本轮未启动 PLE/MCP/Broker/Node
  或执行在线 PLC 操作，不新增真实 PLE、仿真或真机验收声明。
- 团队发行、签名/ACL、受控安装，以及在 AtLogOn 真正启动 Host 前校验五文件 runtime closure 的
  bootstrap 进入 P1.4，当前未完成。

## 关键决策清单

| # | 决策 | 日期 |
|---|---|---|
| D1 | `.project` 只能经 IDE 脚本引擎修改,不手改字节 | 08-04 |
| D2 | 历史结论：PLC 库可脱离 CpStudio 解析；“完全绕开 CpStudio”已由 D20 修正 | 08-11 |
| D3 | MCP 模式 = persistent(headless 在品牌 IDE 不可用) | 08-11 |
| D4 | 历史分工：用户骨架 / AI 细节；已由 D20/D21 扩展为长期协作与 AI 旁车初始化 | 08-11 |
| D5 | 同一时间只允许一个 Codex 窗口使用本 MCP | 08-12 |
| D6 | eval_python 仅用于审计;常规操作走正规工具 | 08-12 |
| D7 | npm 包升级后必须重打 CRLF 补丁 | 08-12 |
| D8 | .project 二进制不入仓库(Bosch 模板版权 + 体积) | 08-12 |
| D9 | 四路线组合打法:①主线/②主攻/③验证/④储备 | 08-12 |
| D10 | HMI 选型:Avalonia 原生壳或 Kiosk 主画面,Web 仅远程备选 | 08-12 |
| D12 | 路线④逻辑层 = OpenPLC,实验先行不投产;开发在独立 Linux 机 | 08-12 |
| D13 | 路线④逻辑层升级 OpenPLC **v4**(v3 EOL);不用内置 SOEM 层,自定义 hardware layer 对接既有 IgH io_master(shm);editor-driven 开发模式 | 08-12 |
| D14 | 路线④开发项目 = **FreePLCDemo**(/media/administrator/D/FreePLC/FreePLCDemo,ai-repo-skeleton 派生,独立仓库) | 08-12 |
| D15 | **Editor 回退策略**:VS Code 替代 Editor 只是一条路线;Editor v4.2.11 常备后备(不卸载/不升级、格式不分叉、单写者、里程碑回退演练);详见 FreePLCDemo handover §5 | 08-13 |
| D16 | **IO 工程只由 IOE 2.6.4 脚本驱动**(PLE 打开=版本污染+崩溃);IOE-IPC = --runscript watcher + 文件命令队列;优雅关闭 p.close(),禁 Environment.Exit;详见 docs/ioe_scripting_playbook.md | 08-18 |
| D19 | **ctrlX 编译消息使用有界读取**：应用只做一次 `build()`；只读取 Build/Additional code checks，每类一次 `get_messages`；无 Build summary 时失败关闭，不再全类别×严重级别扫描 | 08-20 |
| D20 | **CpStudio 持续作为 OpCon 模型/HMI/标准对象事实源**；AI 只维护 ownership 声明的 PLC 应用增量，导出后先审计再修复 | 08-20 |
| D21 | **新项目统一使用事务化 AI 旁车初始化器和版本化 Skill**；不复制 Station010 项目事实、`.project`、Std 或闭源资料 | 08-20 |
| D22 | **Post-export hook 只发布独立请求**；离线消费者不启动 PLE/MCP，且请求 Station/PLC 必须与项目配置强一致 | 08-20 |
| D23 | **Stage 2 先采用 PlanOnly operation ledger**；action/evidence 必须哈希绑定，协调器不启动 PLE/MCP/REST；live runner 与跨进程 MCP 租约后续实现 | 08-22 |
| D24 | **Runner 分为控制面和唯一会话执行面**；P1.1 默认不启动 PLE/MCP，P1.2 由交互会话 Agent/Broker 独占 stdio/PLE，Windows Service 不从 Session 0 启动 PLE | 08-27 |
| D25 | **P1.2b 使用显式 interactive Broker + protocol v2 current-user validated registration + durable submit/query**；同一 Windows 用户是当前信任边界；当前只允许 typed inspect/verify 和固定离线 Build，写工程/在线功能继续关闭，真实 PLE acceptance 单独执行 | 08-27 |
| D26 | **工程 baseline 必须经过用户明确确认**；Runner 只能生成 deterministic candidate，禁止自动晋升；正式 warning/semantic baseline 必须绑定确认记录/evidence hash，并由新的 immutable action 复验 | 08-28 |
| D27 | **截断的 PLE warning population 永不允许成为正式 baseline**；Broker、Stage 1、Stage 2 与 evidence sealer 均以 `PLE_WARNING_OUTPUT_TRUNCATED` 失败关闭 | 08-28 |
| D28 | **所有可批准证据必须同字节校验并有界读取**；AI candidate/triage 不能充当独立人审，semantic snapshot 必须在最终 REST 读取后再次证明工程 clean/stable | 08-28 |
| D29 | **普通 `application.build()` 不是语义重建证明**；正式 baseline 必须使用独立 `clean_compile_project`（恰好一次 clean + 一次 build），warning-limit REST PUT 后必须关闭不保存并重开 | 08-28 |
| D30 | **Runner 的正式编译证据必须来自 Broker 受控的 `clean_compile_project`**；手工隔离 Clean Build 只关闭技术完整性门禁，不能替代新的 immutable action/candidate 或独立人工 baseline 审阅 | 08-28 |
| D31 | **Adapter 与 Broker acceptance 的证据 schema 必须作为一个版本化合同同步演进**；source 字面量、新增证明字段和上限都要有真实 action 与故障注入回归，旧 action 失败后只能由新 Export/action 验证修复 | 08-28 |
| D32 | **baseline 不采集个人身份**；删除 reviewer 姓名/工号，改为 `confirmedByUser: true`，机器自动生成 reviewId/time/path/SHA；仍保留独立确认记录、漂移检测和新 action 复验 | 08-28 |
| D33 | **工程树瞬时未就绪只做窄范围有界重试**；有效前快照前禁止 Build，终态 action 不自动重放；recoverable baseline 不得靠提交 `.project` 二进制绕过 | 08-28 |
| D34 | **recoverable baseline 使用 Build 前本机内容寻址 checkpoint**；范围是当前用户/本机，同 SHA 复用、损坏不覆盖、源漂移在 Build 前失败关闭，不再要求 Git HEAD 包含 `.project` | 08-28 |
| D35 | **Host 自动 evidence 摄取和部署都必须保持可验证边界**；terminal result 绑定 evidence SHA/只读锁，合法无 evidence 只等待人工复核；runtime 以五文件 immutable release 安装，task action 指向 exact release exe、description 记录 manifest；P1.3c 只在 durable journal/reconcile、production ingestor E2E 和真实强杀恢复通过后关闭 | 08-28 |
| D36 | **P1.3c 技术实现与参考工作站验收完成不等于团队发行完成**；签名/ACL、受控安装和 AtLogOn 启动前五文件 bootstrap 统一进入 P1.4。显式 lifecycle 的 manifest/self-check 不能冒充 AtLogOn 自身的预检 | 08-28 |
| D39 | **DIDO 自动化是可选 Project Pack 能力**；每个工位提供自己的完整 CSV，Build/Check 生成并校验 ASC，Stage 1 对比 CpStudio BusConfig，Stage 2 绑定匹配哈希；模板不复制工位点位，Import/Save/Write/Export/Link I/O 仍走官方工具 | 08-31 |
| D40 | **外部电气交换统一为 ASC，日常编排统一为 `Runner -Command Run`**；ASC intake 生成内部 canonical CSV 并阻断占位名/部分拓扑，Run 只续跑其上一轮记录的 operation，不认领历史 ledger，不扩大 PLE/在线能力 | 08-31 |

## 待办 / 下一步

1. 新项目使用统一初始化器创建 AI 旁车；用户继续在 CpStudio 维护模型/标准对象/HMI，AI 维护 ownership 声明的 PLC 增量；
2. warning-limit、Clean Build、adapter/Broker schema 与真实 candidate 生成均已通过；当前 candidates 来自 request `cb1af562-25e6-4523-b2d8-037751d9433d`，禁止复用旧 action 或自动晋升；
3. 正式 warning/semantic baselines、本机内容寻址 checkpoint 与全新 immutable action 均已验证；P1.2 已关闭，写工程 action 仍保持未开放；
4. 继续用已配置的真实 CpStudio Post-export hook 处理后续变更；任何 baseline 或 scope 漂移都必须新建 action；
5. P1.3c 与 P1.4a 已关闭；AtLogOn 五文件 bootstrap 延期到商业化/无人值守部署阶段，兼容矩阵与新工作站验收有工位时再做；当前可推进项目目录/流程生成及后续通用健康检查、结构化编译，`apply_change_set_and_build` 在 payload/readback/恢复门禁完成前保持关闭；
6. 仿真验证（set_simulation_mode）后，由用户单独批准真机下载调试；
7. **路线④**:开发机已就绪,P0~P2 完成(继承 PreemptRt);执行转入 **FreePLCDemo**(v4 安装 → P4 集成);
   交接见 `route4-rtpreempt-openplc/HANDOVER.md` §7。
## D17(2026-08-18 夜)PLE SymbolConfig 脚本极限实测 + Station010 GitHub 备份
- 实测结论:SymbolConfig 条目对 ScriptEngine 树 API 完全不可见(find/get_children/export_xml 全空);可读形态仅 IDE 导出的 Symbolconfiguration XML。详见 docs/ple_symbolconfig_git_notes.md。
- 3 个陈旧符号编译错误(bus_000S900 / _000SK010A1_Channel_6/_7)定性为非 CpStudio 产物(Engineering_Data.xml 对照),待清理。
- Station010 备份到私有仓库 SOLASOLAo/Stat_Resistant_Station010(6a7b4ea 基线 + b9b1161 快照);git 推送配方(openssl+3128+gh token)沉淀到同上笔记。
- 用户迁移到另一台设备开发,转接文档见 McpCoding/HANDOVER.md。

## D18(2026-08-18)CpStudio BMK 双层残留闭环 + connector 映射补丁

- **纠正 D17 的旧结论**：Symbol Configuration 的显示名与脚本内部名不同；内部节点为 `Symbols`，其动态扩展对象是 `ScriptSymbolConfigObject`。PLE 官方 REST API 可以稳定读写公开成员，因此不再依赖 UI。
- 官方 REST 稳定基地址：`http://localhost:9002/plc/engineering/api/v2`；应用符号接口为 `/devices/Device/Plc%20Logic/Application/symbol-config`。根路径兼容路由并不稳定，不纳入工作流。
- Station010 连续两次实测确认：CpStudio 改名/停用 BMK 会更新 `BinIo`，但可能保留 EtherCAT I/O Mapping 与 Symbol Configuration 两层旧引用；固定顺序为 Git diff → 映射修复 → Symbol Select/UnSelect → 保存 → 编译。
- 发现原 MCP `map_io_channel` 只遍历项目树子节点，无法处理 ctrlX/DataLayer 的 connector 通道。已扩展为遍历 `connectors/host_parameters/is_mappable_io/io_mapping`，支持 `Channel_6.Output` 名称定位并强制写后回读。
- 补丁已并入既有 `apply-crlf-patch.ps1`，形成单一 ctrlX 兼容补丁入口；npm 升级后必须先 `-Check` 再应用。
- 实测结果：清除 `_000SK010C1_Channel_6` 的 C1 Channel 6 映射和失效符号后，编译由 1 error / 9 warnings 恢复为 **0 errors / 7 warnings**；未连接或操作实体 PLC。

## D19(2026-08-20)ctrlX 编译消息有界读取

- `ScriptApplication.build()` 是应用工程唯一的常规 Build 入口；不把 `clean()`、`clean_all()` 与 `generate_code()`叠加到每次 MCP 编译。
- 编译结果只从 Build 与 Additional code checks 两个类别读取，每类只调用一次 `System.get_messages(category)`；IDE summary 是 error/warning 计数事实源。
- 不能解析 Build summary 时必须返回错误，不能以空消息推断编译成功。
- 该扩展纳入统一 `apply-crlf-patch.ps1`，npm 升级后与 CRLF、connector I/O Mapping 补丁一同检查和重装。

## D37(2026-08-29)P1.4a 精简团队离线包

> 本节是对 D36 之后“P1.4 全部尚未完成”规划口径的追加 superseding 记录；D36 所记录的
> P1.3c 当时事实与安全边界不变，不回写或删除历史内容。

- `scripts/runner/New-CtrlXOpconRunnerHostPackage.ps1` 已实现 P1.4a 离线包：根目录 exact inventory
  为 `Install.ps1`、canonical `Invoke-CtrlXOpconRunnerHost.ps1`、`RunnerHostDeployment.psm1`、
  `package-manifest.json` 与 `payload/`；payload 只含 Host 五文件。
- package manifest 以规范相对 path、length、SHA-256 和整体 `contentId` 绑定 8 个内容文件；
  `Install.ps1` 在 `Install`、`Rollback`、`Uninstall`、`Status` 等任何命令前验证 exact inventory
  与 manifest。PowerShell 7 离线回归 exit 0，并覆盖篡改拒绝；未启动 PLE、MCP、PLC、Broker
  或 Node，也未执行在线操作。
- 接收工位通过 PowerShell 7 对指定 AI 工程根目录安装；Host 仍需 .NET 8 runtime，但无需 Git、
  源码 checkout、SDK 或本机 build。
  同一 canonical `Install` 路径承担首装和升级；精确回滚、安全卸载与状态查询复用既有 P1.3c
  lifecycle 门禁。`Install` 不暴露 `Start`；fresh Install 默认保持 Host 停止，升级保留升级前的
  running/stopped 状态。
- P1.4a 沿用当前用户默认权限，不设置自定义 ACL；数字签名延期到商业发行或公司 IT 明确要求。
  这不是 AtLogOn 前的独立 runtime closure 校验：五文件 prelaunch bootstrap 尚未实现，兼容矩阵
  与全新团队工作站验收也未完成，所以 P1.4 整体继续保持未完成。

## D38(2026-08-29)开发阶段延期 AtLogOn Bootstrap

> 本节追加用户最新优先级决定，不回写 D36/D37 的历史事实。

- 当前仍处开发阶段，独立 AtLogOn 五文件 prelaunch Bootstrap 不实施、不注册，也不迁移现有任务；
  开发期继续通过 canonical wrapper 显式启动 Host。
- Bootstrap 只在进入商业化或明确需要无人值守登录自启时恢复；兼容矩阵和新团队工作站验收在有
  工位时执行。两项不阻塞项目目录/流程生成和后续通用开发能力。
- P1.4a 离线包、fresh Install 默认停止、当前用户默认权限和签名延期边界均保持不变。

## D39(2026-08-31)可选 ePLAN DIDO Project Pack

- 通用模板新增零依赖 CSV→CpStudio/ePLAN ASC 生成器和 BusConfig 只读核对器，但模板
  `project-pack.json` 不默认启用，也不携带任何工位 CSV/ASC。
- 项目显式配置 `sources.ioDesignators` 后，Project Pack `Build/Check` 将 CSV、生成器、核对器和
  ASC 绑定进内容寻址计划；Post-export Stage 1 逐通道比较名称、Active 状态及中英文描述。
- Stage 2 只接受 `MATCHED`，校验 CSV SHA 与当前 plan、BusConfig SHA 与 Stage 1 fingerprint，
  并将二者绑定到 operation/action；后续漂移失败关闭。Runner/Broker capability 未扩大。
- CpStudio Import、Save、Write designators、Export 及 PLE Link I/O 继续使用官方工具；没有脚本
  修改 CpStudio 模型、`.project` 或在线 PLC。

## D40(2026-08-31)统一 Run 入口与 ASC-only intake

- `Invoke-CtrlXOpconRunner.ps1 -Command Run` 复用既有 Stage 1/2，并从最近一次早先的 Run
  manifest 精确恢复 operation；未跟踪的历史 ledger 不认领。ACTION_READY 时不消费新请求，
  Export #2 仅绑定已跟踪的 `WAITING_FOR_EXPORT_2`，无工作时返回 `IDLE/NO_PENDING`。
- 外部电气输入只接受已验证的 UTF-16LE-BOM、CRLF、15 列 ASC；内部仍使用可 diff 的 canonical
  CSV。精确且无描述的 `_..._Channel_N` 自动名归一为空，错位或带描述占位名失败关闭。
- 覆盖已有 CSV 时，模块/地址/DI-DO 类型 key 集必须相同，部分文件和拓扑漂移不会覆盖旧源。
  ASC 不包含可靠的 EtherCAT 模块 BOM；硬件拓扑后续仍须独立 manifest + IOE 官方接口。
- 根项目与模板 Runner/ASC 脚本和测试同步；完整离线回归未启动 PLE/MCP/Broker 或在线操作。

## D41(2026-09-01)Engineering Console v0.1

- 新增独立 .NET 8 WPF Engineering Console，作为 Runner、Host、Project Pack 的薄 GUI；
  三页集中显示工程阶段、下一步、完整 IOE/CpStudio/AI/PLE 流程、人工边界和证据。
- 命令面固定为 Runner Status/Run、Host Status/Start/Stop、Project Pack Check；不提供任意
  shell、嵌入式 AI、第二个 IDE owner、直接 `.project` 修改或任何在线 PLC 能力。
- P2 IOE Apply 按钮保持禁用；P3 Link I/O 继续显示为人工步骤，P4 等待真实 DAT。
- 模板新增 PowerShell 7/双击 CMD 入口；初始化器只把 `.cs/.csproj/.xaml/.md` 复制到
  `tools/workbench`，排除 `bin/obj`，并校验数量、SHA、生成工程 Build 和 smoke。
- Release Build 0 errors / 0 warnings，Workbench 84 项断言、初始化器 278 项断言和当前/
  通用模板 smoke 均通过；没有启动 PLE/MCP/IOE 或执行在线操作。

## D42(2026-09-01)Engineering Console v0.2 compact UI

- 只调整 WPF XAML：主页合并为一个状态、一个下一步、一个主按钮；7 行重复流程压缩为
  4 段，Host/CpStudio/目录/证据入口收拢到底部工具栏。
- Plan 页直接显示 P2 的 Plan、checkpoint、Apply、readback 四步；Apply 继续禁用，未改
  Runner、Host、Project Pack、PLE/IOE/CpStudio 或任何在线门禁。
- Release Build 0 errors / 0 warnings，Workbench 84 项断言、Station010 smoke 通过；真实
  Workbench/Plan 窗口完成可视化检查。

## 2026-10-07 · CpStudio 库更新原生接口核查

- 按用户的原生脚本/API 要求，只读检查 CSV5_11 的官方帮助、启动配置及程序集元数据/调用引用；
  未操作 GUI、执行供应商方法、修改工程或启动第二个 IDE。
- 尚未建立六步库更新流程的受支持外部入口。结论见基线 §7.10；详细候选与证据边界见
  `skills/ctrlx-opcon-engineering/references/cpstudio-native-automation.md`。
- 更新现有 Skill 的执行方式选择与 GUI 指南边界，保留版本校验、已有 GUI 源码和 SmartForms/WPF 模式。
  此次没有新增或宣称验收通过的原生 CpStudio runner。

## 2026-10-07 · PLE 无菜单调用及 CpStudio 接口适配研究

- ST60一键流程移除PLE的Tools/Execute Script File、弹窗和坐标点击代码，新增固定
  `native_ple_phase.cjs`，复用唯一现有persistent MCP的IpcClient/watcher；不新建服务/IDE。
- 原生执行器补齐裸watcher回调缺失的driver上下文；冷会话编译消息在Build后重新读取，
  Symbol库namespace必须在预检前通过原生编译解析。保留源码/hooks/I/O/Symbol及警告门禁。
- 隔离副本成功记录为ST60旁车的
  `data/reports/cpstudio-mcp-acceptance/dd5231b2-125b-4d6a-8649-fc828e327cde/acceptance.json`：
  0错误/9条既有警告，316源码、158I/O、939Symbol权限，已保存离线且测试PLE退出。
  本轮未重跑正式CpStudio Parse/Export整链。
- 按用户授权继续CpStudio内部接口研究，发现公开工程管理器单例及DDP加载配置。
  只读扩展原型编译成功，但未完成当前工程实例引导；不把内部方法列为已通过的外部API。
  临时宿主已关闭；原有正式CpStudio窗口保留，未向其执行工程写命令。
- 现有skill增加PLE原生入口指南、更新源模板，并加入可重复执行的只读PE元数据检查器；
  CpStudio原生桥接仍标明未验收。与“整合 ST60 项目工程”对话协调独占窗口后执行上述验证。

## 2026-10-07 · CpStudio 原生桥接隔离闭环

- 按用户“继续”授权，在主 ST60 对话确认暂停窗口后，完成 CpStudio5.11.0.169 自有 x86 宿主。
  使用原 DDP 程序、独立配置和 `ExecuteAssembly` 加载自有桥接，没有修改供应商安装文件，
  没有对正式 PID15376 执行工程写命令，也没有鼠标、UIA 或热键输入。
- 固定命令通过当前工程身份检查，原生 Reload、精确 OOD0.1.2.6→隔离测试0.1.2.7、
  依赖校验、Apply/reload、完整模型 Save 和冷重开回读通过；PLC 库仍0.1.1.1，非新发布。
  模型343667节点保持，比较结果为目标版本/基引用更新及一项原生保存名称更新。
- Public Export 包装层的早期未知结果已记录，结束自有一次性宿主后恢复隔离 PLC checkpoint；
  改用原生 STA ExportThread 并收集通知，缺失 Post-export 脚本按错误处理。隔离观察脚本
  就绪后，新验收 `d22cfc20-12d4-4cdf-9cec-fc10347cdbf7` 的 Parse/Save/Export、PLE 原生
  Build/Save 全部通过：0错误/9条既有警告、316源码、158 I/O、939 Symbol及保护检查保持。
  测试 PLE 保存退出；Post-export 仅为隔离观察入口，不认领正式 Stage1/Stage2。
- 可复用四文件源码加入现有 skill 的 `assets/cpstudio-native-v511`。便携入口原生恢复测试
  版本0.1.2.6，拒绝不存在的99.99.99.99；随后冷启动回读0.1.2.6、无脏内容，版本计划通过。
  原生桥接仅启动隔离副本的自有宿主，stock实例接管、正式集成及其他版本仍未验收。
  没有实体PLC操作、HMI现场部署或提交推送。

## 2026-10-07 · 组件库原生文件入口补齐

- INNTAI 开发对话反馈库版本、编译库导出/安装与已审查组件脚本缺少执行入口；核对当前
  skill、源码和本机patched0.6.3发现 Station runner 只接受preflight/build。另确认
  typed `compile_project` 已支持 `.library` 的 `check_all_pool_objects`，而
  `clean_compile_project` 仅支持 Application；此处明确工具适用范围，未修改npm包。
- 扩展既有 `native_ple_phase.cjs` 的离线 `component` 阶段，并增加固定原生
  `component_existing.py`。使用精确PID/profile/primary project、授权隔离根目录及已审查
  `scripts/ple/*.py` 内容指纹；固定文件暂存、job指纹、回执与现有单owner/no-replay规则共用。
  wrapper拒绝在线或脏状态、错误目标、替换源码和未保存返回，库不要求active Application；
  记录实际ProjectInfo与脚本JSON证据。不宣称Python沙箱或自动编译/安装/仿真验收。
- 10项Node检查与3项CPython原生API模拟检查通过。没有调用INNTAI/ST60 MCP/PLE/CpStudio，
  没有启动第二个IDE、修改这些工程或执行虚拟/实体在线操作。实际组件脚本原生验收由当前
  owner在其授权窗口内执行；组件workflow、PLE入口及AGENTS的typed缺口替代路线已同步，
  仍禁止routine eval_python。

## 2026-10-07 · CpStudio 导出错误明细与只读诊断

- INNTAI owner反馈隔离参考工程已Reload/Parse/Apply OOD1.0.3.0/Save，但Export回执
  `7497378f-c195-43ab-b8d5-3f9ebb59a18e` 仅有“See output window”通知。磁盘startup日志有
  HTTP400；owner另从原生输出读出创建 `/Station` 失败、REST返回 `BadRequest` 与
  `A blocking operation is in progress`。后续PLE编译0错误/4条基线警告不覆盖Export失败，
  阻塞操作的具体来源仍由当前owner调查；本轮不重试Export。
- 在共享桥接加入就绪后的原生Output/Messages事件收集、操作UUID及512条有界历史，
  getter失败单独记录；成功和失败Export回执均保留明细、通知和原始success flag。
  新增只读diagnostics，读取历史和上次Export结果，不调用PLE/REST、清除输出或修改模型。
  ready公布命令能力，旧宿主拒绝新诊断请求；五文件源码需owner在未来受控启动时加载。
- 15项离线消息测试、旧宿主拒绝检查及完整x86宿主/桥接编译通过，仍有既有ApplicationBase
  弃用编译警告。只读取已有失败回执/日志及供应商元数据，没有向INNTAI/ST60的当前
  PLE/CpStudio发命令、热换DLL或启动IDE。实际新宿主消息捕获仍待owner验收。
  Skill验证、改动链接检查与安装源一致性检查通过，已同步用户安装副本。

## 2026-10-07 · PLE 自有执行器生命周期与 REST 阻塞调查

- INNTAI owner提供新宿主失败Export；只读磁盘回执
  `e143d5f2-ad9f-4160-9e47-27feac217c65` 确认complete/nativeExportSuccessful均false，
  499条当次消息（122 Messages、377 Output），无captureError，全局丢弃190条。
  Output有371条blocking错误及6条已有目录/对象冲突；不能说全部错误均来自blocking。
  原生消息捕获已得到失败运行验收，整链成功及部分写入恢复仍未证明。
- 只读供应商PE/IL确认REST CheckForBlockingOperation读取Engine全局
  LengthyOperationIsActive；owner报告jobs均Done，无Running。不能把当前阻塞归因于
  未完成REST job。ScriptEngine便利Execute创建执行器但无Dispose；Native Execute内
  callback Finish已有finally。watcher主线程转发和在线借用执行器不应被本工具释放。
- 固定preflight/build/component入口统一改用CreateScriptExecutor创建自有执行器，
  关闭其公开默认ProgressCallbackFactory，LoadDrivers/Execute后finally Dispose。
  回执增加executorDisposed/cleanupUnknown；只有对应UUID释放标记和原生阶段结果都确认
  才成功，清理未知或timeout保留锁。此修正不写私有flag、不清除既存LengthyOperation，
  不宣称已经定位或修复当前REST根因。
- 13项Node离线测试通过，涵盖实际生成Python的成功、既存gate、LoadDrivers/Execute/
  Create/Dispose失败，以及清理未知保锁和已清理失败放锁；使用原生API doubles，未接IDE。
  owner另报告隐藏.NET异常：工程句柄-1，栈到LanguageModelProvider.UpdateLanguageModel。
  Continue后脚本读LengthyOperationIsActive=False，但随后
  `841c177a-3f51-48d1-80f3-6f593af42dc1` Export仍终态阻塞失败且无新modal，因果/线程
  上下文未证明。owner计划自行保存故障副本并受控恢复，当前工具变更验收由其执行。
- 本轮只读源码、元数据、回执并修正共享源码/skill；没有调用当前MCP/REST、操作PLE或
  CpStudio会话、热换DLL、编辑INNTAI工程或执行在线/实体动作。
  Skill格式验证、4份文档的9条本地链接检查及基线HTML再生成通过；安装副本已同步，
  Install-CtrlXOpconSkill.ps1 -Check确认与canonical源码一致。
- 交接后owner自行受控重启唯一PLE为PID31720并运行修正版；只读磁盘回执
  `84fb5385-657b-413b-ace3-e372bfbbb21d` preflight与
  `2062e821-0ae3-495a-966e-9889a6dbb358` component均complete=true、saved/offline、
  executorDisposed=true、cleanupUnknown=false，含精确UUID释放标记。确认这两阶段的
  原生执行及清理，不能推导后续Export、build或REST故障已恢复；当前Export仍由owner执行。
- owner随后报告Export `e0c89618-953f-44ea-83e0-2347f7b14bbd` complete/nativeSuccess均true、
  无notifications，OOD INNTAI1.0.3.0/其他版本保持，typed编译0错误/9既有警告。
  受控重启和入口修正组合后恢复，不指定单一根因；原始失败副本/回执保留，finish_consumer
  Symbol迁移及完整源码/硬件检查仍由owner继续。应owner要求结束额外诊断；此项仅记录其
  交接消息，没有操作会话或继续调查。

## 2026-10-07 · SFC reader 便携依赖修正

- INNTAI owner反馈finish_consumer及8项SFC after比较通过，但installed read_graphs.py的
  after直接从engineeringRoot导入scripts.plc.sfc_graph_key，ECom_ST60旁车缺该文件，
  CLI报ModuleNotFoundError。当次用只读启动器加载同一维护模块完成比较；未改算法/回执。
  owner继续正式离线文件同步和编译，本工具维护不操作工程。
- read_graphs.py改为直接按文件加载：项目模块优先，仅在文件缺失时使用reader自身asset
  布局内scripts/plc/sfc_graph_key.py，不依赖全局sys.path/scripts包缓存。项目模块存在
  但损坏时继续报错，不静默替换；SFC比较算法及checkpoint格式保持。文档补明两文件
  相对布局与launcher staged-reader依赖。
- 7项graph离线检查通过，其中新增缺旁车模块的完整after入口、项目模块优先和损坏模块
  拒绝回退；既有SFC步骤/子项/属性/操作ID保护检查保持。所有REST响应均为fixtures，
  没有调用当前MCP/REST、操作IDE、修改INNTAI/ECom工程或重跑真实比较。
  Skill格式、本轮4份文档7条链接及基线HTML再生成通过；安装版已同步并-Check一致。

## 2026-10-08 · PLE Close 超时及 online executor 离线核对

- INNTAI owner报告1.0.3.1编译库/本机仿真24/24通过，唯一broker PLE PID28864/session
  4d9e4f34-c369-4e0c-bbba-4ded0c314e11，offline component确认自有执行器Dispose。
  stop/logout并保存后Close请求7b952e83-629a-4073-bae3-5b3aa1e6376c超时，watcher最后
  为Marshaling且无result；Open7886443f-3e53-41db-8b86-d18ae3999264及只读eval
  6a9726e2-8ae0-4b4a-98de-b500faae4a90未确认处理。之前首次Open的迟到成功已由owner
  独立核实。记录为未知终态，不重放、不清私有flag，不推断任何executor造成。
- 本轮只读源码和元数据，核对component磁盘回执a0c115a6-661a-4f41-9082-eeabbc93ba91
  complete/executorDisposed=true、cleanupUnknown=false；旧IPC目录本轮已不在原路径，
  Close无终态仅按owner报告记录。库、仿真工程及证据已由owner保存，恢复仍归唯一owner。
- 安装watcher的execute_on_primary_thread先于WaitOne(120000)，旧Marshaling不能定位
  回调进入阶段。IPC客户端超时删除命令/脚本并释放自身mutex，不等于取消原生工作。
  只读IL确认ScriptProject.close调用IProject.Close并丢弃返回值，ScriptOnline原生事件
  管理执行栈及实例清理；with_executor借用执行器且finally清理Python临时变量。
  disconnect工具会把构造/logout异常当success，不能用其marker认领原生logout。
- 共享watcher/兼容安装器补充请求UUID的dispatch/primary entry/marshal return日志，
  不改变执行或超时语义；skill附独立logging-only diff。8项离线double检查、隔离adapter
  apply/check/语法及回滚回归、便携diff在安装源码临时副本上的真实git apply检查通过。
  本轮未修改npm包或运行中的watcher，未调用当前MCP/REST、操作IDE/工程/在线设备。
  原生Close及online故障根因仍未知；新日志仅供owner未来受控维护/启动。
  Skill格式验证、本轮5份文档6条本地链接、源文件diff检查及基线HTML再生成通过；
  安装skill已同步并-Check一致，这不等于安装或启用broker日志补丁。

## 2026-10-08 · 迟到 Open 与 Reference Symbol Export 失败补记

- 按INNTAI owner提供的事实记录，未执行工程查询/操作：旧PID28864在交付保存后通过
  broker shutdown停止，owner确认进程不存在。原Close请求7b952e83仍无确认终态，
  不补记成功/失败，不重放。新PID18304打开隔离ReferenceProject的请求
  f2be04b5-5a4d-4dc5-b5f2-bee4a2b7340f约188秒后出现success=true磁盘回执；owner另用
  fresh只读native审计确认目标/dirty=false，typed编译0/4及native preflight1241cf18通过。
  只读Computer Use观察/激活未发现模态，未证实激活恢复因果。
- Reference原生Apply/Parse/Save已到INNTAI1.0.3.1，但Export
  0879212b-608d-45a5-b235-c90f5a584462明确失败：UpdateSymbolConfig JSON Reader
  Invalid property identifier character '{'，types[39].variables[3].attribute/line11052。
  owner确认209源码、1条自有SFC保持及dirty=false；这些保护结果不覆盖导出失败。
- 与之前Symbol HTTP异步写响应问题仅按症状相似记录，本次根因未知。owner正在复用
  BufferedSymbolResponse会话内修正，未改厂家文件、blocking flag或安全设置；本轮仅更新
  共享文档，不操作会话、不新增诊断/补丁或推断恢复结果。

## 2026-10-10 · typed 状态成功回执与原生库引用修正

- INNTAI owner提供1.1.0.1原生验证反馈：库/隔离consumer编译0/0，本机Simulation35/35，
  无实体操作；曾有stop/disconnect成功后仍Logged In=True，以及list_project_libraries
  返回NoLibraries而实际Application manager明确引用1.1.0.1。本轮只读runtime JSON和
  component635219e8回执，确认35/physicalOperations=false与complete/executorDisposed/
  cleanupUnknown字段；不接管ST60 owner持有的PLE。
- 核对当前0.6.3源码，disconnect吞构造/logout异常；库列表用manager.get_children
  而不是get_libraries。新增三个canonical模板：with_executor和实际状态前后读回，
  logout必须False，已STOP不重复stop；库引用从明确Application原生manager枚举，
  缺manager/枚举失败/多Application无active scope拒绝假空列表。stop成功仅证明STOP。
  三工具要求预期工程已primary，不调用ensure_project_open自动切换或保存。
- 兼容安装器同步src/dist helper wiring及空列表消息，校验已知原始模板并拒绝覆盖未知/
  自定义版本；纳入原有transaction/语法验证。skill附三模板和窄范围server diff。
  20项离线double测试、完整隔离apply/check/语法/回滚及便携diff实际应用检查通过。
  不宣称原生修正版已验收或通用根因；未改npm安装文件、当前broker、工程或在线状态。
- owner受限online_session.py仅允许本目录Virtual且Simulation=True；实际RUN时stop，
  logout后断言未登录才导入/关闭。按最新用户策略记录WP收到OK完成、不自动RP比较，
  覆盖早期WRITE_VERIFIED要求，不修改该组件源码或其他协议策略。
  Skill格式、5份文档9条链接及源文件diff检查通过，基线HTML已再生成；installed skill
  已同步并-Check一致。安装skill未部署这些修正到当前npm broker。

## 2026-10-11 · 库更新原生统一入口

- 用户询问 Reload→Parse PLC Code→Save All→Export 是否能一键及作为开发接口使用。
  核对现有固定原生命令及隔离验收；旧双击 GUI 启动器不包含版本迁移。
- 补充 `Invoke-CpStudioLibraryUpdate.ps1`，仅编排既有客户端的六步命令，要求精确
  OOID/OOD版本和现有离线 PLE 工程/PID。完整保存复用工程及模型 Save；返回各步回执，
  原生失败/超时/错误回执即止，不重新提交、接管窗口、启动宿主/IDE或自动回滚。
- 六项离线检查覆盖输入/身份参数保持及失败停止；新组合入口未执行真实工程，
  当前CpStudio、PLE、broker和正式工程未操作。同步共享skill；原生命令既有隔离验收
  与该新组合入口实际验收范围分开记录，后续由工程owner完成。
- PowerShell语法、skill格式与资源链接检查通过，基线HTML已再生成；installed skill
  已同步且-Check一致。ST60 sidecar仅新增统一入口源文件，不替换已有桥接/运行DLL。

## 2026-10-16 · 可复用库开发范例与全局 skill

- 按用户要求保持简单实用：扩充现有 skill 的 library-validation 路由，加入三个自有文本范例与一个只复制到新/空目录的入口，不新建同名/重叠 skill 或 Runner。
- MachineCommon 保存压力 FB/16场景夹具；IND360 保存回环 TCP 模拟/真实 PowerShell 测试/Ready-only消费源；INNTAI保存协议模拟与1.1.1.1最终八场景串口夹具。每个范例说明来源、依赖、运行步骤及证据边界。
- 已通过4项复制检查、IND36014项模拟端及19项真实TCP/菜单日志回归、INNTAI8项PC协议测试、Python/PowerShell语法与skill本地链接检查；8个INNTAI原生对象与历史最终声明/实现一致。
- 同步本机全局安装与ST60 devkit，安装器-Check一致。本轮无IDE/PLC编译/PLC仿真/实体操作，不修改ST60工程逻辑；历史原生证据不作为新版本验收。本地更新，未提交或推送。

## 2026-10-16 · CpStudio 通用模型添加接口

- 接收ST40侧技术转接：实现Variables、Struct/成员/实例及显式上下界数组的读取、预览、
  添加和回读，不触碰正式ST40，不提供任意脚本、配方值写入、删除或批量改类型入口。
- 通用模块 `CpStudioNativeModel.cs` 与三个固定命令/客户端参数已实现；更新两个构建器的
  模块及供应商Data程序集引用。既有resident身份/owner/实例、Export及超时不重放规则保留。
  UTF-8请求信封在写claim之前限制64KiB，避免被原生上限拒绝后产生假超时。
- 独立副本 `ECom_ST60/McpCoding/data/native-model-additions-20261016` 来自ST40
  `st40-manual-view-a223bd179d89cf31`冻结检查点；Std仅只读链接、PrjExt独立复制。
  未读用ST40 owner token，不接管其窗口、PLE、REST或MCP。
- 首次数组回读发现未用维度0被原生识别成活动维度；失败回执bd8c0759已留存。只关闭
  自有隔离宿主、恢复该副本的冻结检查点，修正为-1后重新编译验证，没有重放失败计划。
- 实际添加24项声明（含12基本类型、TypeData两组Count/数组、双角度结构、Variables/
  StationData实例和负下界/2D/3D数组），原生比较保留8739项既有索引记录。17项原生
  正反向检查通过，含重复调用、错误身份/类型/边界、递归、值写入拒绝与stale plan。
  Save/关闭/冷重开24项全部unchanged，两把枪原ProgNo保留；额外stale测试仅本副本加一BOOL。
- 新客户端12项、既有resident13项及更新流程7项离线检查通过。完整路径读取延迟结构/
  数组缓存另行实测；接收说明强调保留ST40私有命令，不能直接覆盖本地bridge或热换DLL。
  用户待授权向ST40主对话协调唯一PLE窗口，当前未执行Export/PLC编译或现场动作。
- 延迟树7项完整路径读取已通过；负索引使用原生已展开集合的精确名称定位，避免旧成员
  regex漏掉负号，结构数组元素使用公开ExpandMember/成员集合，避免带下标根名被再次
  解析成数组查询。展开后添加StationData BOOL原生核对保留8887项旧记录、重复调用新增0。
- 最终新进程27352冷重开继续读回7个值、24项声明全unchanged、重新计划应用新增0；
  当前索引8890（含原生展开缓存及隔离测试探针）。resident候选仅在独立目录编译通过，
  未安装/覆盖运行DLL。PowerShell语法、skill格式/链接、MD→HTML及安装-Check通过；
  共享skill已同步。隔离宿主已正常关闭、processExited=true，正式ST40和共享PLE未操作。
  本轮模型验收汇总为该隔离目录acceptance.json；Export/PLC编译仍待用户许可协调窗口。

## 2026-10-17 · 通用模型添加验收窗口协调

- 用户明确允许向ST40主对话发消息，由其安排唯一PLE的隔离Export/编译窗口；已发送协调请求。
  在owner交接前不联系共享PLE/REST/MCP、不启动另一相同profile实例；正式ST40未操作。
- 隔离工程Pre/Post-export钩子原值均为空，不向正式队列发请求。将只读源码/硬件/Symbol/
  库引用采集入口及其既有依赖放入本隔离目录，入口语法检查通过；未执行原生采集或编译。

## 2026-10-20 · WPF / OpCon 通用集成组件候选

- 用户新增独立通用能力目标，保留原模型接口Export/编译待办；不替换华沿正在收敛的原生三页。
  已读取华沿HMI交接、本机帮助及公开程序集契约。当前PLE PID24484和CpStudio PID33064由华沿
  使用；只从进程/文件确认，没有调用共享PLE/MCP/REST或操作其窗口。
- 元数据及调用点表明VisiWin.PerformClick只进入OnClick，不经过原生鼠标按下/释放路径；原生键
  还处理心跳/计时器和单位/令牌初始化。此差异解释既有转接不足，不宣称已定位其他所有门禁。
- 在src/hmi/OpCon.WpfIntegration实现候选0.1.0.0：原生控件保持同级父级与OwnerUnit，WPF布局
  槽承载真实输入，既有Item只读显示/原生双语、前缀和心跳配置。无私有字段/假点击/Execute
  直写/第二连接/重试队列；处理未知质量、长暂停恢复、几何占用、捕获/焦点及自有资源释放。
- 39项C#离线检查及原生同级配置/双语资源边界检查通过；实际WPF装载/三个尺寸和普通WinForms
  几何占用/释放属于离线证据，不冒充原生OpCon键或PLC运行。源码、公开契约、人工构建/候选
  打包与运行验收步骤保留；正常Export资源携带与真实操作/PLC故障隔离均未验证。
- 已征询后续窗口协调，用户明确“先只做组件开发，暂不联系”；未给华沿发消息、不接管其
  HMI/虚拟环境，也不操作实体PLC、机器人或现场IPC。等待后续允许时按唯一所有权取得独立窗口。
- 候选目录bin/candidate-0.1.0-20261020已生成，包内自有源码独立重建再次39项通过，配置/双语
  检查通过；包内Runtime只含自有DLL，非空目录覆盖已拒绝。PowerShell语法、组件文档链接及
  文档差异检查通过；基线HTML同步。无发布、提交、现场安装或工程运行验收。
- 后续组件开发补齐官方Post-export资源步骤源：仅同步自有DLL/XAML并合并自身GUI引用，保留
  原有钩子/vwn/PLC。提供路径JSON、批处理入口与OOD Hmi片段，不假设未核验的原生复制API。
  15项文件夹检查通过，含真实批处理调用Windows PowerShell和空格路径；已有GUI内容、重复
  无写入、越界/Std/链接拒绝、未完成更新停止均检查。运行HMI拒绝只实现了保护，未进行运行用例。
- 资源测试先发现空复制清单被表示为[null]，另一次发现PowerShell向File.Replace传空字符串；
  失败均留在自有测试目录，后者保留claim/tmp且原GUI未变。改为空数组及NullString后通过；
  失败现场没有盲目清理/重放。该进展不改变共享工程禁止接管、真实PLC/Export尚未验收的状态。
- 完整目标核验发现初始化失败的异常路径中，readSet.Dispose抛错会阻止后续ClearMapping；
  候选0.1.0.1用finally确保仍尝试清理控件占用。39项既有离线回归通过，没有声称重现供应商
  运行异常。完整要求/证据/缺口表写入现有RUNTIME-VALIDATION，明确原生探针、真实请求/周期、
  故障恢复与完整Export均缺证据；仅组件开发/暂不联系条件仍有效，未改变任何共享会话。

## 2026-10-20 · 纯 WPF 输入最小样例与操作接口缺口

- 用户要求继续研究操作接口并完成WPF参数框/手动键最小样例，明确不动华沿工程、不占共享PLE/CpStudio。
  继续只读外部Std SDK，不调用任何现有HMI、PLC、MCP/REST或工程会话。
- 扩展元数据检查至27类，新增Inspect-Operations只读入口，13项版本/调用差异核验通过：Key的
  StartEdit只进入DigitalItem编辑、VarIn.StopEdit进入原生NumEdit，原生手动鼠标路径另有心跳/计时器；
  Shopfloor Contract 2.0.1.0承载WPF FrameworkElement并提供语言/可见性生命周期。没有据此宣称
  已取得完整受支持的参数提交/手动操作API；私有字段、假点击、直接Execute写入均未使用。
- 新增独立OpCon.WpfOperations 0.1.0.0：可见输入全部WPF，原生适配器仍未实现。自有端口契约
  区分绑定/会话代次、新开始与继续许可、本地记录/原生分发/未知，保存原端口和输入ID以取消/释放；
  不重试未知结果、不把Busy一律解释为释放、草稿不冒充PLC回读。本地探针只编译进样例/测试exe。
- 58项离线输入检查通过，含重入、重复、原实例释放、上下文变化、Busy、异常不重放、草稿取消和
  资源释放；实际WPF模板/合成确认与Esc事件、真实Hide/Show/Close和页面渲染已检查，默认禁用页及
  显式本地探针页另做真实Sample.exe启动自检，初始输入数均为0。测试窗口不激活、屏幕外显示。
- 人工构建、启动和待适配契约写入operations/README；旧候选包仅携带新原型源码，资源同步不部署
  新原型。真实鼠标/触摸/键盘/DPI、原生语言/触摸键盘、PLC接收/扫描/Unit状态及故障恢复仍未验证。
  原CpStudio通用模型添加Export/编译待办继续保留，未提交、推送或部署。

## 2026-10-20 · WPF 库定位、扩展接口查找与进程内宿主

- 用户明确目标是自研WPF操作控件随库复用、提高外观和兼容性，并嵌入CpStudio生成HMI；
  复用现有VisiWin/CoDeSysV3/PLCHandler，保留权限、令牌和执行反馈。继续禁止华沿改动及共享PLE/CpStudio。
- 用户确认没有额外开发SDK。只读本机匹配ST60 Std、安装帮助、公开厂商资料；新增检查
  NumEdit、配置/资源适配器、代理提供器和归属类型。34类元数据、13项证据核验通过，
  仍没有匹配版本的完整受支持操作事务。具体入口/缺口及供应商问题在operations/NATIVE-ADAPTER。
- 增加独立WpfInputHost和SFC/XAML承载样例；匹配原生SFCLoader在设计上下文加载成功，
  实际ElementHost装载纯WPF参数框和手动键。它是视图宿主，不是已实现的原生操作适配器。
- 宿主测试发现ElementHost内没有WPF Window，且恢复焦点会开始一次编辑；增加CancelInput及
  WinForms生命周期转发，改为明确输入才开始编辑、忽略Enter自动重复。纯WPF前端升至0.1.0.1，
  59项输入检查及两次实际启动自检通过；24项宿主检查涵盖失活、隐藏、禁用、取消关闭、释放、
  多实例隔离及布局错误。使用屏外非激活窗口/合成托管事件，无OS输入注入。
- 所有新增测试都是设计装载或本地输入证据。没有启动HMI驱动、联系PLC、取得请求/周期/Unit反馈，
  也未验证物理键盘/触摸、实际DPI、原生语言、工具箱、正常Export或运行HMI。没有联系其他对话、
  提交、推送或部署；原通用模型添加的Export/编译待办保留。
- 用户随后纠正目标表述：当前是自研功能库（如华沿机器人库）自身的界面和按钮采用WPF，
  主要为了兼容性；通用控件复用与实例配置/DLL解耦是实现层选择。已同步目标文档，
  本次仅修正文档，不改实现或工程，原生操作适配器及运行验收状态不变。

## 2026-10-27 · CORE Data Layer 只读诊断收入全局 skill

- 将已实测的标准库读取脚本收入 ctrlx-opcon-engineering，新增 read/browse/metadata/SSE 调用说明；目标显式核对，认证外仅 GET，无 PLE/CpStudio 会话、写入或自动重连/重发。
- 已发布变量优先直接读取 CORE；共享工程被排除时，未发布的内部表达式只报告缺口，不自动登录、改 Symbol 或导出。保留既有 PLE Keep 只读路线。
- 新增内容同步维护源码、全局安装和 ST60 devkit；各份原有不相关差异保留，未运行整目录覆盖安装。三个 skill 结构校验、帮助入口、离线 HTTP/SSE 行为检查通过；原始脚本此前的 ST60 实测记录留在项目。
- 本次未连接控制器、PLE/CpStudio/MCP、机器人或 IPC，未提交/推送；技术基线 HTML 已重新生成。

## 2026-10-29 · 工程操作避免干扰人工桌面

- 用户指出 computer-use 使用过多、耗时且干扰手动操作。全局 ctrlx-opcon-engineering 明确默认接口/原生路线；缺少 MCP 工具不自动转 GUI。
- 未明确要求 GUI 或安排独占窗口时，不抢焦点、鼠标、键盘、剪贴板；后台 UIA/控制消息也按共享界面操作处理。仅视觉验证才按需无激活截图，用户恢复手动操作即暂停 GUI 输入。
- 接口操作仍可能占用 IDE 主线程，保留唯一 owner 和有界任务约束。维护源码、全局版和 ST60 devkit 仅同步本次规则，未操作工程或设备。

## 2026-10-29 · 现有工具发布基线与独立 MCP 仓库

- 用户明确要求将现有工具发布到公开 `SOLASOLAo/ctrlx-ai-coding` 的 main，并创建私有
  `SOLASOLAo/ctrlx-engineering-mcp` 保存新 MCP 的方案与后续开发。两者分开维护，不切换运行中的 MCP 配置。
- 维护源补回安装版 skill 的 4 处规则与 ST/SFC 风格检查器/测试；纳入 CpStudio 原生桥接、库更新、
  PLE 固定脚本入口、原生状态回读补丁、只读 Data Layer 工具和 WPF 研究源码。首页明确实现与验收边界。
- 修复 skill 安装器将 Python 运行缓存误报为源码差异的问题；检查/复制/精确更新均排除该缓存，
  保留真实额外文件检测。8 项安装回归及本机安装内容核对通过，没有覆盖安装版 skill。
- 完整 MCP 补丁在临时包副本应用/检查/语法/回滚验证通过；新旧编译消息、semantic snapshot、
  原生状态回读及生命周期诊断检查通过，没有修改全局 npm 包。
- skill 结构、对象版本 10 项、风格 18 项、样例复制 4 项、原生脚本阶段 13 项通过；
  CpStudio diagnostics 17 项、库更新 7 项、模型客户端 12 项、驻留连接 13 项离线夹具通过。
  库构建/组件/图形读取及 INNTAI/IND360 协议测试通过，IND360 仅使用本机 loopback 模拟器。
- 新增 7 项 CORE 只读回归：目标错配不发请求、认证后仅 GET、分片 SSE、错误不重连、嵌套脱敏、
  节点校验和现有输出保护。WPF 源码/配置边界检查通过，未新增实际 HMI/PLC 验收声明。
- Broker 工程会话及 IPC 离线测试、Runner 286 项断言、Workbench 84 项断言通过；未运行现场工程。
  相关文档本地链接检查通过；扫描候选均为合成测试标记，旧 token-in-URL 示例改为凭据管理器方式。
  补丁文件中的单空格上下文行是 unified diff 语法，保留；其他改动通过空白检查。
- 保留 CODESYS MCP 上游 MIT 声明，忽略本机凭据、私钥、供应商运行库和测试报告。
  没有启动/切换 PLE 或 CpStudio，没有连接实体 PLC/机器人、修改现场工程或当前 MCP 配置。
