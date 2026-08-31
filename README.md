# ctrlX AI Coding

**用 MCP + AI 驱动 Bosch ctrlX PLC 编程** —— CpStudio 持续维护 OpCon 模型、标准对象与 HMI，
AI 依据可读规格经受控 MCP/REST 开发 PLC 应用逻辑并完成离线验证。

> AI-driven PLC programming for Bosch ctrlX via persistent MCP.
> CpStudio remains the model/HMI source; AI owns declared PLC application logic.

## 这个项目解决什么问题

ctrlX 工程的传统流程依赖 Nexeed CpStudio 低代码平台生成 OpCon 框架代码,但该平台:

- 冗余、不好用,库数量不完善;
- 每次改动都要回到平台重新生成;
- 真正有价值的只是它的 OpCon 库与层级骨架。

本项目验证并落地一条新路线:

```
阶段1 CpStudio V5.11(人,持续使用)
   Station/Command/Unit 层级 + 标准对象 + HMI/Event/StationData/BMK → 生成/导出
        ↓
阶段2 硬件组态(人)
   ctrlX 默认 IP 网页 → EtherCAT → ctrlX IO Engineering
        ↓
阶段3 AI + persistent MCP(主力)
   set_pou_code → compile(结构化错误) → 修复 → save,写 SqM/SqS/自动/手动细节
        ↓
阶段4 下载调试(MCP 在线工具)
   simulation → connect → download → start/stop → read/write/monitor
```

**核心结论(已实测)**:`.project` 是加密容器，只能经对应 IDE、MCP 或正式 REST 接口修改；
CpStudio 与 AI 通过对象归属清单协作，AI 不直接改供应商模型文件，也不覆盖未声明的生成对象。

## 当前状态(2026-09-01)

| 项 | 状态 |
|---|---|
| MCP 模式 | ✅ `codesys-persistent` v0.6.3(headless 在 ctrlX 品牌 IDE 不可用) |
| CRLF 缺陷补丁 | ✅ 已打 + 已产品化(`patches/`,含一键脚本) |
| 冒烟编译 | ✅ 0 errors / 35 warnings(培训样板固有符号警告) |
| 分工 | 用户做骨架(CpStudio),AI 做 PLC 代码细节 |
| 项目模板 | ✅ 新项目初始化器 + Stage 1 离线审计队列 + Stage 2 PlanOnly operation ledger |
| Project Pack | ✅ schema + PowerShell 7 Build/Check + draft initializer + Runner 漂移门禁 |
| Codex Skill | ✅ `ctrlx-opcon-engineering`，源码可版本化、安装可校验 |
| Controlled Runner | ✅ P1.1/P1.2、P1.3a/b/c 及 P1.4a 精简团队离线包已完成；⏸ AtLogOn bootstrap 延期到商业化/无人值守部署阶段，兼容矩阵与新工作站验收有工位时再做 |
| Engineering Console | ✅ 独立 .NET 8 WPF 薄壳；固定 Runner/Host/Project Pack 白名单、工程阶段/下一步/人工边界/证据显示；P2 Apply 和全部在线 PLC 操作禁用 |
| 产品化计划 | `docs/mcp_productization_roadmap.md` |

Stage 2 是哈希绑定、可恢复的 PlanOnly 协调器；P1.2 interactive Broker 使用
current-user registration、Named Pipe v2、durable submit/query 和 typed allowlist，且只由
工程师在交互会话中显式启动。2026-08-28 的最终 Station010 immutable action 已通过：
显式 Clean Build 0 errors / 4 条完整 warning，456 mapping、Symbol、正式 baseline、
本机 checkpoint 与工程/结构哈希全部匹配，无在线动作。P1.2 已关闭。

P1.3a/P1.3b 新增 `vcrunner-host`：当前用户后台单实例、heartbeat/status、同会话精确停止、
有界 JSONL 日志与崩溃恢复，并自动发现、消费 Host activation 后由权威 ledger 发布的
immutable `currentAction`。activation 前的历史已终态工作不会被当成新任务；旧 open claim
仍可恢复且恢复后的结果持续可见。有待处理 action 且没有有效 Agent 时保持 `WAITING_FOR_AGENT`，
没有 action 时保持 `WAITING_FOR_ACTION`。

P1.3c 已实现自动 result/evidence 摄取：Host 对 terminal result 和 sealed evidence 重新执行
SHA 绑定及只读文件锁校验，再调用 release-bound 的纯离线 Stage 2 coordinator 推进 ledger；
合法的无 evidence 终态保持 `WAITING_FOR_COORDINATOR` 等待人工复核，不重跑 action；Stage 2
忙时有界退避，存在其他 fresh ledger 异常时阻断推进。该路径不需要 Agent，也不启动 Broker、
Node、MCP、PLE，且不执行任何在线 PLC 操作。production 默认 ingestor 的 6 项 fixture E2E
均已通过，覆盖 Host 默认摄取、DONE、BLOCKED、真实 workflow ledger 独占锁映射为 busy 且零
mutation、evidence SHA 漂移拒绝，以及无 evidence 的人工复核。

Host runtime 已发布为五文件、内容寻址的 immutable release。Scheduled Task action 精确指向
active release 的 `vcrunner-host.exe`，description 记录 `releaseId + manifest SHA-256`；wrapper
的显式 lifecycle 会校验五文件 manifest，并在启动、切换和安全卸载路径执行 apphost self-check。
AtLogOn 任务自身只是直接启动该 action，不会先独立校验 `.deps.json` 或
`.runtimeconfig.json`。durable deployment journal/reconcile，以及真实断点/强杀、升级回滚、
损坏拒绝和 `deployment.json` 缺失时的安全卸载均已在参考工作站通过。当前 active release 为
`faa27c1d79415996ddcd524833160c57ea23ac63888f17b853487a81b46ab0f1`，previous release 为
`ac89b28f9a93a61c10b5bd7731c3b5b83288169a105c62eb4218a30c119f4b51`，Host 为
`WAITING_FOR_ACTION`。P1.3c 技术实现和参考工作站验收至此完成；该结果不新增真机或真实 PLE
验收声明。

P1.4a 已提供精简团队离线包：发行机用 `New-CtrlXOpconRunnerHostPackage.ps1` 固定封装
`Install.ps1`、canonical wrapper/module、Host 五文件和 `package-manifest.json`；manifest 记录每个
内容文件的 path/length/SHA-256 与整体 `contentId`，安装器在任何命令前验证。接收工位通过
PowerShell 7 对指定 AI 工程根目录安装；Host 仍需 .NET 8 runtime，但无需 Git、源码、SDK 或
本机 build。同一 `Install` 同时承担首装与升级，
另提供精确 `Rollback`、安全 `Uninstall` 和只读 `Status`。fresh `Install` 只注册 release 并默认
保持 Host 停止，首次启动必须另行显式执行；升级 `Install` 保留升级前的 running/stopped 状态。
当前沿用 Windows 当前用户权限，不增加自定义 ACL；
数字签名延期到商业发行或公司 IT 明确要求。独立的 AtLogOn 五文件 prelaunch bootstrap 尚未实现，
并按用户决定延期到商业化/无人值守部署阶段；开发期继续显式启动 Host。包含 Host/.NET 运行前提的
兼容矩阵与新团队工作站验收在有工位时再做。这些部署项不阻塞当前功能开发，P1.4 产品化范围仍开放。

```powershell
.\scripts\runner\New-CtrlXOpconRunnerHostPackage.ps1 `
  -OutputPath 'C:\Transfer\CtrlXRunnerHost'

pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -EngineeringRoot '<ai-root>'
pwsh -File 'C:\Transfer\CtrlXRunnerHost\Install.ps1' `
  -Command Status -EngineeringRoot '<ai-root>'

dotnet run --project `
  .\tests\runner\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest\CtrlX.OpCon.Runner.Stage2Ingestor.SelfTest.csproj `
  -c Release
```

## 创建新工站 AI 旁车

不要复制某个现有 Station 项目的 BMK、规格和项目脚本。先预览，再由统一初始化器创建：

```powershell
.\scripts\New-CtrlXOpconProject.ps1 `
  -ProjectId 'example-cell' `
  -DisplayName 'Example Assembly Cell' `
  -StationId 'Station020' `
  -StationRoot 'C:\Engineering\ExampleCell\Station020' `
  -OutputPath 'C:\Engineering\ExampleCell\McpCoding' `
  -WhatIf
```

初始化器会生成 `project-pack.json` 和 draft `generated/engineering-plan.json`。补齐
`specs/processes/*.process.json` 并把 Pack 状态改为 `ready` 后执行：

```powershell
pwsh -File .\scripts\project\Build-CtrlXOpconProjectPack.ps1 -Command Build -RequireReady -Json
pwsh -File .\scripts\project\Build-CtrlXOpconProjectPack.ps1 -Command Check -RequireReady -Json
```

生成器不写 CpStudio/PLE，只输出流程计划、提示、测试和追溯。新 action 固定 Pack/plan 身份；
Host 与直接 ExecuteAction 共用校验器逐项验证计划事实源，对 stale/draft Pack 失败关闭。

完整参数和离线测试见 `templates/README.md`。初始化器只创建 AI 旁车，所有工程路径写成相对路径；不会复制
Station、`Std`、`.project` 或闭源资料，目标目录已存在时会拒绝覆盖。

安装或校验 Codex Skill：

```powershell
.\scripts\Install-CtrlXOpconSkill.ps1 -Force
.\scripts\Install-CtrlXOpconSkill.ps1 -Check
```

安装后重新加载 Codex，即可显式使用 `$ctrlx-opcon-engineering`。Skill 负责编排方法和安全边界；
项目事实仍来自当前仓库的 `config/specs/ai/src/catalog`。

## 仓库结构

```
├── README.md                  ← 本文件
├── AGENTS.md                  ← AI Agent 工作指南(先读)
├── docs/
│   ├── ctrlX_AI_project_baseline.md    ← 基线记录(权威文档,11 章)
│   ├── ctrlX_AI_project_baseline.html  ← 基线记录 HTML 版
│   ├── mcp_productization_roadmap.md    ← MCP 产品分层、优先级和验收标准
│   ├── SESSION_LOG.md                  ← 讨论与决策流水账
│   ├── ioe_scripting_playbook.md       ← IOE 脚本化操作手册(阶段2实战踩坑)
│   └── PC_Info_Report.txt              ← 环境快照
├── config/
│   ├── codex.config.toml.example       ← 生效中的 Codex MCP 配置(路径按本机改)
│   └── history/                        ← 配置演进备份
├── patches/
│   └── codesys-mcp-persistent-crlf/    ← ⭐ ctrlX IDE 必需补丁（行尾、I/O、编译消息）+ 一键脚本
├── scripts/                            ← 新项目初始化、环境采集和 IOE 驱动
├── mcp_test/                           ← MCP 验证用 IronPython 脚本(.project 二进制不入库)
├── templates/                          ← ctrlX/OpCon AI 旁车 + 通用代码项目模板
├── tests/                              ← 初始化器等纯离线工具测试
└── route4-rtpreempt-openplc/           ← 路线④ PREEMPT_RT+IgH+OpenPLC 交接(独立 Linux 机开发)
```

## 快速上手(复现本环境)

1. **安装**:ctrlX WORKS(含 ctrlX PLC Engineering PLE-V-0206.x)+ Node.js + `npm i -g codesys-mcp-persistent`;
2. **配置**:参考 `config/codex.config.toml.example`,把 `[mcp_servers.codesys-persistent]` 的
   `--codesys-path` / `--codesys-profile` / `--workspace` 改成你的路径(profile 名必须精确,如 `ctrlX PLC 2.6.8`);
3. **打补丁**:
   ```powershell
   cd patches\codesys-mcp-persistent-crlf
   .\apply-crlf-patch.ps1 -Check
   .\apply-crlf-patch.ps1
   ```
4. **验证**:通过 MCP 调用 `get_codesys_status`(等待 ready)→ `compile_project`;
5. **读文档**:`docs/ctrlX_AI_project_baseline.md` 第 8~11 章(脚本 API、实施路线、红线、FAQ)。

## 红线(务必先读)

- 🔴 `write_variable` 是**强制写值(FORCE)**,真机操作前确认安全状态;
- 🔴 不手改 `.project` 字节;CpStudio 重新生成前必备份 AI 改动;
- 🔴 npm 升级 `codesys-mcp-persistent` 会覆盖 ctrlX 兼容补丁（含编译超时修复）→ 重跑 `apply-crlf-patch.ps1`;
- 🟡 同一时间只开一个使用本 MCP 的 Codex 窗口(多实例竞态致 IDE 退出)。

## 路线图(产品方向)

- [x] 阶段 0:环境基线 + persistent 上线验证 + 补丁产品化(2026-08-12)
- [ ] 阶段 1:用户 CpStudio 骨架(层级/HMI/handler/变量)
- [x] 阶段 2:硬件与 IO 组态(EtherCAT)(Station010 实测 2026-08-18,方法见 docs/ioe_scripting_playbook.md)
- [ ] 阶段 3:AI 填充逻辑(SqM/SqS/自动/手动),compile 结构化错误闭环
- [ ] 阶段 4:仿真 → 真机下载调试
- [x] 产品化基础:可复用项目初始化器、Post-export Stage 1 审计队列、Stage 2 PlanOnly ledger 和 Codex Skill
- [x] 产品化 MCP 技术通道:Controlled Runner P1.1、P1.2a client、P1.2b interactive Broker、受控 adapter、fresh Build、typed warning 与真实 PLE semantic snapshot
- [x] 产品化 Host P1.3b：activation 后 immutable `currentAction` 自动发现/消费、历史隔离、旧 claim 恢复和无 Agent 等待
- [x] 产品化 Host P1.3c：自动 result/evidence 摄取、production ingestor 6 项 E2E、durable deployment journal/reconcile，以及 immutable release 的真实强杀/升级回滚/损坏拒绝/安全卸载验收
- [x] 产品化 Host P1.4a：带内容 manifest 的精简团队离线包；接收工位无需 Git/源码/build，PowerShell 7 支持首装/升级、回滚、卸载和状态查询；fresh Install 默认停止，升级保留原运行状态
- [ ] 产品化 Host P1.4 后续：AtLogOn 启动前五文件 bootstrap 延期到商业化/无人值守部署阶段；兼容矩阵与新工作站验收在有工位时再做；两者不阻塞当前开发，默认不自定义 ACL，数字签名按商业/公司 IT 要求延期

## 版权说明

- Bosch / Bosch Rexroth / OpCon / ctrlX / Nexeed 为各自权利人商标;本仓库不分发其库与工程二进制;
- TrainingStation 为 Bosch 培训材料,本仓库仅引用其路径作参考样板;
- 本仓库原创内容(文档/脚本/补丁)见各文件头部说明。
