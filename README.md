# ctrlX AI Coding

CpStudio / OpCon / ctrlX 工程开发工具与 `ctrlx-opcon-engineering` skill 的维护仓库。
CpStudio 持续维护模型、生成结构与 HMI；AI 通过明确的对象归属和原生接口修改工程。

**当前工具基线：2026-10-29。** 本仓库保存现有工具；新的统一 MCP 在独立的
[ctrlx-engineering-mcp](https://github.com/SOLASOLAo/ctrlx-engineering-mcp) 私有仓库研发。
该仓库仅对获授权的账号可见，初始内容为方案与开发记录，不代表新 MCP 已可使用。

## 当前能力与验证边界

| 能力 | 当前状态 | 使用入口 |
| --- | --- | --- |
| PLE 持久 MCP | 基于 `codesys-mcp-persistent 0.6.3`，维护 ctrlX 行尾、编译、Symbol/I/O 和原生状态回读补丁 | [补丁与离线检查](patches/codesys-mcp-persistent-crlf/README.md) |
| PLE 原生脚本 | 复用已有唯一会话，执行固定的预检、构建及组件库阶段；不通过菜单加载脚本 | [原生脚本入口](skills/ctrlx-opcon-engineering/references/ple-native-script.md) |
| CpStudio 原生桥接 | 面向 **5.11.0.169** 的实验性进程内适配；有隔离样例及驻留连接证据，其他版本与正式工程需分别验收 | [桥接范围与安装](skills/ctrlx-opcon-engineering/references/cpstudio-native-automation.md) |
| 库更新 | 精确 OOID/OOD 版本计划，Reload → Apply → Parse → Save All → Export，返回各阶段回执；PLC 库安装及消费工程编译另行衔接 | [库更新流程](skills/ctrlx-opcon-engineering/references/cpstudio-library-update.md) |
| CORE 只读诊断 | 认证后仅 Data Layer GET；读取、浏览、元数据和有界 SSE；不占用 PLE/CpStudio，不自动重连 | [读取与订阅](skills/ctrlx-opcon-engineering/references/core-datalayer-readonly.md) |
| 工程 skill 与库样例 | 模型/代码归属、原生优先、桌面不干扰、OpCon ST/SFC 风格检查及 MachineCommon/IND360/INNTAI 样例 | [Skill](skills/ctrlx-opcon-engineering/SKILL.md)、[库样例](skills/ctrlx-opcon-engineering/assets/library-examples/README.md) |
| Runner / Broker / Host | 已有排他租约、执行记录、离线检查编排和参考工作站验收；它们尚不是覆盖五个工具的统一 MCP | [Runner](src/runner/README.md)、[路线与历史验收](docs/mcp_productization_roadmap.md) |
| WPF / OpCon 研究样例 | 展示与宿主、纯 WPF 输入样例已有离线检查；**原生操作适配器未完成，不能宣称 HMI→PLC 操作已接通** | [WPF 源码与限制](src/hmi/OpCon.WpfIntegration/README.md) |
| IOE / WORKS | 保留既有 IOE 脚本经验与工程工具；没有完整的统一 MCP 适配器 | [IOE 脚本说明](docs/ioe_scripting_playbook.md) |

本次发布整理不启动工程软件、不连接控制器。历史原生验证只对相应版本、目标与步骤有效；
源码/离线测试通过不等于新工位、物理设备、正式 Export 或 WPF 操作验收通过。

## 安装与更新

在独立工具目录获取本仓库，不覆盖正在使用的工位目录：

```powershell
git clone https://github.com/SOLASOLAo/ctrlx-ai-coding.git
cd ctrlx-ai-coding

# 首次安装 skill；不会修改 MCP 配置、工程或供应商安装目录。
powershell.exe -NoProfile -File ./scripts/Install-CtrlXOpconSkill.ps1

# 已安装时先检查。安装版包含本地更新时，先审阅差异再决定覆盖。
powershell.exe -NoProfile -File ./scripts/Install-CtrlXOpconSkill.ps1 -Check
# 确认仓库是希望安装的版本后：
# powershell.exe -NoProfile -File ./scripts/Install-CtrlXOpconSkill.ps1 -Force
```

PLE MCP 的已验证基础版本为 **0.6.3**。首次配置可参考
[MCP 配置示例](config/codex.config.toml.example)，填写自己的安装路径、工作目录及精确 profile
（参考工作站为 `ctrlX PLC 2.6.8`）。不把示例中的路径当成本机事实。

```powershell
npm install -g codesys-mcp-persistent@0.6.3
powershell.exe -NoProfile -File ./patches/codesys-mcp-persistent-crlf/apply-crlf-patch.ps1 -Check
# 仅在会话所有者安排的维护窗口应用补丁：
# powershell.exe -NoProfile -File ./patches/codesys-mcp-persistent-crlf/apply-crlf-patch.ps1
```

`npm install/update` 会覆盖兼容补丁。已有可用配置不需要为本次仓库更新重新安装 MCP、
安装 CpStudio 插件、重启 IDE 或启用 Runner/Host。需要这些能力时按各入口的版本与所有权要求操作。
厂商软件和对应授权由工作站自行提供，本仓库不分发供应商 DLL、工程容器或编译库。

## 日常开发

1. 确定目标工程、软件版本、模型/代码归属及当前所有者。
2. 优先 typed MCP、原生脚本、官方 REST 和已验证桥接；缺少接口不自动转为 GUI 点击。
3. 批量修改明确归属的源码，保存并回读；需要生成结构变化时从 CpStudio 模型处理。
4. 库更新明确区分 OOD 与 PLC 库版本。Parse/Export 后检查受影响的代码、Symbol、I/O 和 HMI，并执行新编译。
5. 超时或结果未知先核对执行状态，不重放写入。在线诊断优先使用独立只读 Data Layer 通道。

GUI 自动化入口仍保留在 [历史一键启动器](skills/ctrlx-opcon-engineering/references/cpstudio-oneclick.md)，
仅用于用户选择的 GUI 工作方式。后台 UIA、按键或控制消息同样会操作共享界面。

## 创建新工位与可选工具

通过 [项目初始化器](scripts/New-CtrlXOpconProject.ps1) 建立 AI 旁车，先用 `-WhatIf` 预览。
不要把某个工位的 BMK、现场点位、凭据或流程作为通用模板。

- [工程技术基线](docs/ctrlX_AI_project_baseline.md)：版本、接口及历史验证事实；[HTML](docs/ctrlX_AI_project_baseline.html) 由 Markdown 生成。
- [工程控制台](docs/engineering_workbench.md)：可选的 Runner/Host/Project Pack 界面。
- [项目模板](templates/ctrlx-opcon-project/README.md)：目录、配置、离线审计及初始化说明。
- [团队配置](templates/ctrlx-opcon-project/TEAM_SETUP.md)：需要团队部署时按需使用。
- [变更记录](docs/SESSION_LOG.md)：过程与历史决策。

## 验证与边界

离线验证包括 skill 安装/结构、脚本单元测试、原生桥接客户端夹具、MCP 补丁夹具及组件源码检查。
测试入口随各模块提供；原生 IDE 验证只能在明确的独占窗口进行。

- 不直接编辑 `.project` 字节，不用 PLE 打开 IOE 工程。
- 同一 profile/工程只允许一个所有者；不抢焦点、鼠标、键盘或剪贴板。
- `write_variable` 的现有实现属于 FORCE，不能当作普通写值接口。
- 实体 PLC 下载、启停、写值/FORCE、机器人动作与 IPC 部署需有覆盖目标和动作的授权。
- WPF 原生握手、通用模型添加的正式 Export/编译、跨版本和新工作站兼容性仍按各模块记录分别验收。

## 来源与许可

Bosch、Bosch Rexroth、OpCon、ctrlX、Nexeed 的商标与软件权利属于相应权利人。
本仓库不是其官方 SDK。MCP 衍生代码的来源和 MIT 许可见
[第三方说明](THIRD_PARTY_NOTICES.md)。公开仓库不改变供应商软件的使用或分发条件。
