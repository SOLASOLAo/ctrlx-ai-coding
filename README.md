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

## 当前状态(2026-08-28)

| 项 | 状态 |
|---|---|
| MCP 模式 | ✅ `codesys-persistent` v0.6.3(headless 在 ctrlX 品牌 IDE 不可用) |
| CRLF 缺陷补丁 | ✅ 已打 + 已产品化(`patches/`,含一键脚本) |
| 冒烟编译 | ✅ 0 errors / 35 warnings(培训样板固有符号警告) |
| 分工 | 用户做骨架(CpStudio),AI 做 PLC 代码细节 |
| 项目模板 | ✅ 新项目初始化器 + Stage 1 离线审计队列 + Stage 2 PlanOnly operation ledger |
| Codex Skill | ✅ `ctrlx-opcon-engineering`，源码可版本化、安装可校验 |
| Controlled Runner | ✅ P1.1/P1.2 与 P1.3a/P1.3b 已实现；🚧 P1.3c 尚未完成 |
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
没有 action 时保持 `WAITING_FOR_ACTION`；action 终态
落盘后保持 `WAITING_FOR_COORDINATOR`，等待后续 coordinator/evidence ingestion 推进 ledger。
Host 不启动 Broker、Node、MCP、PLE，也不执行任何在线 PLC 操作。P1.3b 已完成；
P1.3c 尚未完成，下一步是 coordinator/evidence ingestion，以及稳定安装、升级和回滚。
Host 登录任务使用 WinExe GUI-subsystem apphost，因此后台启动不弹控制台；
`Status/Stop/Logs` 则经 `dotnet + DLL` 保留命令行输出。完整 payload pin 仍属于 P1.3c。
重建或升级 Host 时按 `Uninstall → Build → Install → Start`，不要覆盖运行中的二进制。

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
- [x] 产品化 Host P1.3b：activation 后 immutable `currentAction` 自动发现/消费、历史隔离、旧 claim 恢复、无 Agent 等待和 `WAITING_FOR_COORDINATOR`
- [ ] 产品化 P1.3c：coordinator/evidence ingestion、完整 payload pin、稳定安装、升级/回滚；随后再推进 project_health/change set 与正式 SFC/Symbol/I/O 工具

## 版权说明

- Bosch / Bosch Rexroth / OpCon / ctrlX / Nexeed 为各自权利人商标;本仓库不分发其库与工程二进制;
- TrainingStation 为 Bosch 培训材料,本仓库仅引用其路径作参考样板;
- 本仓库原创内容(文档/脚本/补丁)见各文件头部说明。
