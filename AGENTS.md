# AGENTS.md — AI Agent 工作指南

> 任何 AI 编码代理(Codex 等)在本仓库或相关 ctrlX 项目工作前,**先读完本文件**。
> 人类可读版总览见 `README.md`;详细技术基线见 `docs/ctrlX_AI_project_baseline.md`。

## 1. 项目一句话

用 **CpStudio + persistent MCP + AI** 协作开发 Bosch OpCon/ctrlX 自动化项目：CpStudio 持续维护
供应商模型、标准对象与 HMI，AI 依据可读规格维护声明归属的 PLC 应用逻辑；长期目标是沉淀可复用的
**AI coding 产品**（MCP 工具、项目模板、Skill 与代码生成规范）。

四条技术路线并行推进(详见 `docs/ctrlX_tech_routes.html`):
① CpStudio 骨架 + AI MCP(主线)→ ② 自研 HMI + ctrlX(主攻演进)→ ③ CODESYS 软PLC(备选验证)→ ④ 纯 RT Linux(远期储备)。

## 2. 分工(2026-08-11 定,勿越界)

| 角色 | 职责 |
|---|---|
| **用户** | CpStudio 模型（Station/Command/Unit 层级、标准对象、HMI/Event/StationData/BMK）、硬件组态、工艺与真机安全确认 |
| **AI** | AI 旁车初始化、PLC 应用逻辑、编译-修复闭环、I/O/Symbol/SFC 审计、仿真辅助、文档与证据维护 |

AI 可以创建标准化的 AI 旁车目录，但不伪造 CpStudio 供应商模型；影响工艺或安全的未知内容先标记 pending。

## 3. 红线(违反会出事故)

1. **`.project` 是加密容器**——绝不手改文件字节,只能经 IDE 脚本引擎(MCP 工具)修改。
2. **`.project` 二进制不入库**(Bosch 模板版权 + 体积),已在 `.gitignore`;不要试图强制添加。
3. **npm 升级 `codesys-mcp-persistent` 会覆盖 ctrlX 兼容补丁**（CRLF + connector I/O Mapping + 有界编译消息读取）→ 升级后必须重跑
   `patches/codesys-mcp-persistent-crlf/apply-crlf-patch.ps1`(先 `-Check`)。
4. **同一时间只允许一个 Codex 窗口使用 codesys MCP**(多实例抢 profile 会致 IDE 退出)。
5. **`write_variable` 是 FORCE 强制写值**,不解除一直生效;真机 download/start_stop/write 前必须与用户确认安全状态。
6. **eval_python 仅作审计用途**;常规操作走正规 MCP 工具;**勿对已打开工程裸调 `se.projects.open()`**(卡死 IDE UI 线程)。
7. CpStudio 重新生成可能覆盖 AI 代码：生成后先 diff，再按 ownership/hooks/graphical 清单恢复；先确认集成 Git 可恢复精确起点，不能恢复时只建一个内容寻址 checkpoint，禁止重复创建哈希相同的备份。

## 4. 环境关键事实(已实测,改前核对)

| 项 | 值 |
|---|---|
| PLC IDE | `C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\StudioPlc\Common\ctrlX-PLC-Engineering.exe` |
| profile(必须精确) | `ctrlX PLC 2.6.8` |
| MCP 模式 | **persistent 唯一可行**(ctrlX 品牌 IDE headless 不可用) |
| MCP resource server 名 | `codesys-persistent` |
| Codex 配置 | `C:\Users\AGZ1WX\.codex\config.toml`(本仓库 `config/codex.config.toml.example` 为副本) |
| 库仓库 | `C:\ProgramData\Rexroth\PLE-V-0206\0\Studio\Managed Libraries`（OpCon 库编译时由占位符解析；不表示可以绕开 CpStudio 模型所有权） |
| 模板 | `C:\ctrlXWORKS\ctrlXPLCEngineering\PLE_V_0206\Studio\Templates\Standard.project`(=TrainingStation 拷贝,含 OpCon 骨架+34 库占位符) |
| 参考样板 | 桌面 `To_Participants_ctrlX_V2.6.10_CN\TrainingStation\...`(只读参考,不分发) |
| 测试工程 | `C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\TS_PLC_TEST.project` |
| 编译基准 | 培训样板固有符号警告(Loc*/SqC*),**以 errors=0 为准** |

## 5. MCP 使用速记

- 卡死恢复:`shutdown_codesys`(SIGKILL 兜底)→ 下次调用自动重启;日志 `%TEMP%\codesys-mcp-persistent\<session>\watcher_error.txt`
- `get_compile_messages` 返回**上次编译的缓存**——改代码后先 `compile_project` 再取消息
- IronPython 2.7 脚本引擎;脚本 API 速查见基线文档第 8 章
- 补丁体检:`apply-crlf-patch.ps1 -Check`（同时检查 watcher 行尾和 ctrlX connector 通道映射能力）

## 6. 文档与提交约定

- **事实源分工**:结论性技术事实 → `docs/ctrlX_AI_project_baseline.md`;过程与决策流水 → `docs/SESSION_LOG.md`;
  路线规划与执行进度 → `docs/ctrlX_tech_routes.html`(§7 清单勾选即进度)
- **MD 是源,HTML 是产物**:改完 `ctrlX_AI_project_baseline.md` 后运行 `python scripts/md2html.py` 重新生成 HTML
- 重大环境/配置/补丁变更:**更新文档 → 提交 → 推送**,一次做完
- 提交信息风格:`docs:` / `patches:` / `scripts:` / `config:` / `hmi:` 前缀 + 简述;中文正文可
- 日期一律 ISO 格式(YYYY-MM-DD);新增决策追加到 SESSION_LOG 决策清单与基线红线章节

## 7. 当前状态快照(2026-08-29)

- [x] 阶段 0:环境基线 + persistent 上线验证 + ctrlX 兼容补丁产品化（含编译超时修复）
- [x] 通用 AI 旁车初始化器 + Post-export 离线审计队列 + `ctrlx-opcon-engineering` Skill
- [x] MCP 分层产品化路线与验收标准：`docs/mcp_productization_roadmap.md`
- [x] Controlled Runner P1.1：单一 CLI、OS 排他租约、项目预检、Stage 1/Stage 2 编排、结构化 run manifest；默认不启动 PLE/MCP
- [x] Controlled Runner P1.2a：.NET 8 immutable-action client、双租约、幂等终态、失败关闭和 evidence 封口
- [x] Controlled Runner P1.2b 离线基础：interactive Broker、current-user registration、Named Pipe v2、durable submit/query、单 owner 和 typed action allowlist
- [x] Controlled Runner P1.2 真实 PLE 技术通道：受控 ownership/fresh/Clean Build、typed-warning 与 semantic-snapshot adapter 已应用；Station010 新 action 连续取得完整 0 errors / 4 条 `OPC.UA.DA` warnings，工程/结构 SHA 前后不变
- [x] Controlled Runner P1.2 失败关闭加固：用户确认记录、同字节有界 hash/parse、warning 截断阻断、畸形请求/证据脱敏、三组 Mapping/Symbol 交叉权威读取、最终 Mapping/dirty guard、REST timeout/stream cap 与 patch rollback 回归完成
- [x] Controlled Runner P1.2 正式基线验收：Station010 的 warning/semantic baselines 已由一次明确用户确认建立，不采集姓名/工号；全新 immutable action 已完成 0 errors / 4 warnings、456 mapping、Symbol、checkpoint 与工程/结构哈希复验
- [x] Controlled Runner P1.3a/P1.3b/P1.3c：current-user Host 生命周期、自动 action 消费、result/evidence 摄取、durable recovery 与五文件 immutable release 已完成技术实现及参考工作站验收；Host 不启动 Broker/MCP/PLE/Node 或在线操作
- [x] Controlled Runner P1.4a：精简团队离线包可在接收工位用 PowerShell 7 完成完整性校验、安装/升级、精确回滚、安全卸载与状态查询；Host 仍需 .NET 8 runtime，但不依赖 Git、源码、SDK 或本机 build；fresh `Install` 默认不启动 Host，升级保留原 running/stopped 状态
- [ ] Controlled Runner P1.4 后续：独立 AtLogOn 五文件 prelaunch bootstrap、兼容矩阵与新团队工作站验收尚未完成；默认沿用当前用户权限、不自定义 ACL，数字签名延期到商业发行或公司 IT 明确要求
- [ ] 阶段 A(进行中):用户 CpStudio 骨架 → AI 填充逻辑(阶段 3)→ 仿真 → 真机
- [ ] 阶段 B:路线② HMI 原型(OPC UA demo → hmi-framework,主画面 Avalonia 原生壳,Web 版远程备选)
- [ ] 阶段 C:路线③ 标准 CODESYS + MCP 实测(先验证后买授权)
- [ ] 阶段 D:路线④ PREEMPT_RT + IgH 抖动实验
