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

## 待办 / 下一步

1. 新项目使用统一初始化器创建 AI 旁车；用户继续在 CpStudio 维护模型/标准对象/HMI，AI 维护 ownership 声明的 PLC 增量；
2. warning-limit、Clean Build、adapter/Broker schema 与真实 candidate 生成均已通过；当前 candidates 来自 request `cb1af562-25e6-4523-b2d8-037751d9433d`，禁止复用旧 action 或自动晋升；
3. 正式 warning/semantic baselines、本机内容寻址 checkpoint 与全新 immutable action 均已验证；P1.2 已关闭，写工程 action 仍保持未开放；
4. 继续用已配置的真实 CpStudio Post-export hook 处理后续变更；任何 baseline 或 scope 漂移都必须新建 action；
5. P1.3c 已关闭；按 `docs/mcp_productization_roadmap.md` 推进 P1.4 团队发行、签名/ACL、受控安装和 AtLogOn 五文件 bootstrap，再继续通用健康检查、结构化编译和 change set；`apply_change_set_and_build` 在 payload/readback/恢复门禁完成前保持关闭；
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
