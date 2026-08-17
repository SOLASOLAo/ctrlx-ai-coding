# ctrlX AI Coding

**用 MCP + AI 驱动 Bosch ctrlX PLC 编程** —— 让 AI 直接编写符合 OpCon 标准的 ctrlX PLC 程序,
把 Control plus Studio(CpStudio)低代码平台缩减为一次性骨架生成器。

> AI-driven PLC programming for Bosch ctrlX via persistent MCP.
> CpStudio stays for one-shot HMI/skeleton generation; AI writes the PLC logic.

## 这个项目解决什么问题

ctrlX 工程的传统流程依赖 Nexeed CpStudio 低代码平台生成 OpCon 框架代码,但该平台:

- 冗余、不好用,库数量不完善;
- 每次改动都要回到平台重新生成;
- 真正有价值的只是它的 OpCon 库与层级骨架。

本项目验证并落地一条新路线:

```
阶段1 CpStudio V5.11(人,一次性)
   Station/Module/Command 层级 + HMI + handler/变量 + OpCon 状态机骨架 → 一键生成/导出
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

**核心结论(已实测)**:`.project` 是加密容器,只能经 IDE 脚本引擎修改;而所需 OpCon 库全部在
本地托管仓库自动解析 —— **PLC 侧可完全绕开 CpStudio**。

## 当前状态(2026-08-12)

| 项 | 状态 |
|---|---|
| MCP 模式 | ✅ `codesys-persistent` v0.6.3(headless 在 ctrlX 品牌 IDE 不可用) |
| CRLF 缺陷补丁 | ✅ 已打 + 已产品化(`patches/`,含一键脚本) |
| 冒烟编译 | ✅ 0 errors / 35 warnings(培训样板固有符号警告) |
| 分工 | 用户做骨架(CpStudio),AI 做 PLC 代码细节 |
| 阶段 | 等待用户骨架就绪 → 阶段 3 AI 填充逻辑 |

## 仓库结构

```
├── README.md                  ← 本文件
├── AGENTS.md                  ← AI Agent 工作指南(先读)
├── docs/
│   ├── ctrlX_AI_project_baseline.md    ← 基线记录(权威文档,11 章)
│   ├── ctrlX_AI_project_baseline.html  ← 基线记录 HTML 版
│   ├── SESSION_LOG.md                  ← 讨论与决策流水账
│   ├── ioe_scripting_playbook.md       ← IOE 脚本化操作手册(阶段2实战踩坑)
│   └── PC_Info_Report.txt              ← 环境快照
├── config/
│   ├── codex.config.toml.example       ← 生效中的 Codex MCP 配置(路径按本机改)
│   └── history/                        ← 配置演进备份
├── patches/
│   └── codesys-mcp-persistent-crlf/    ← ⭐ ctrlX IDE 必需补丁 + 一键脚本
├── scripts/                            ← 环境采集脚本 + ioe_ipc.ps1(IOE 驱动)
├── mcp_test/                           ← MCP 验证用 IronPython 脚本(.project 二进制不入库)
├── templates/                          ← ai-repo-skeleton:新代码项目骨架模板(四文档纪律)
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
- 🔴 npm 升级 `codesys-mcp-persistent` 会覆盖 CRLF 补丁 → 重跑 `apply-crlf-patch.ps1`;
- 🟡 同一时间只开一个使用本 MCP 的 Codex 窗口(多实例竞态致 IDE 退出)。

## 路线图(产品方向)

- [x] 阶段 0:环境基线 + persistent 上线验证 + 补丁产品化(2026-08-12)
- [ ] 阶段 1:用户 CpStudio 骨架(层级/HMI/handler/变量)
- [x] 阶段 2:硬件与 IO 组态(EtherCAT)(Station010 实测 2026-08-18,方法见 docs/ioe_scripting_playbook.md)
- [ ] 阶段 3:AI 填充逻辑(SqM/SqS/自动/手动),compile 结构化错误闭环
- [ ] 阶段 4:仿真 → 真机下载调试
- [ ] 产品化:精简 OpCon 骨架模板、自定义库集合、AI 代码生成规范、可复用项目模板

## 版权说明

- Bosch / Bosch Rexroth / OpCon / ctrlX / Nexeed 为各自权利人商标;本仓库不分发其库与工程二进制;
- TrainingStation 为 Bosch 培训材料,本仓库仅引用其路径作参考样板;
- 本仓库原创内容(文档/脚本/补丁)见各文件头部说明。