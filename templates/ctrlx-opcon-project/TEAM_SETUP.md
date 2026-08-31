# 团队工作站部署 — {{DISPLAY_NAME}}

> 本文件描述新电脑的稳定部署；当前开发进度见 `HANDOVER.md`。

## 标准布局

```text
<WorkspaceRoot>/
├── <StationDirectory>/   CpStudio/PLC/HMI 集成工程
├── Std/                  供应商标准对象，只读
└── <AiRepository>/       本仓库
```

本机配置应使本仓库中的相对路径分别指向：

- Station：`{{STATION_ROOT_REL}}`
- Std：`{{STANDARD_LIBRARY_ROOT_REL}}`

如果团队成员必须采用不同层级，不要在提交中写个人绝对路径；调整工作区布局使相对路径保持一致。

## 必需软件

| 组件 | 项目基线 |
|---|---|
| PowerShell | 7.5+；`%ProgramFiles%\PowerShell\7\pwsh.exe`，必须支持 `ConvertFrom-Json -DateKind` |
| .NET SDK / Desktop Runtime | 8.x，用于构建和运行受控 Runner/Host 及 WPF Engineering Console |
| CpStudio | 由项目负责人确认精确版本 |
| ctrlX PLC Engineering | `config/project.yaml` 中的 profile/version |
| ctrlX IO Engineering | `config/project.yaml` 中的 version |
| persistent MCP | 使用团队固定版本和校验过的 ctrlX 兼容构建 |
| Git/Codex | 使用个人授权账号；不得复制别人的 Token 或整份用户配置 |

## 不随 Git 分发

- `Std`、OpCon/Nexeed 闭源实现和手册；
- `.project`、许可证、凭据、设备证书和生产数据；
- IDE 安装介质与供应商托管库。

这些内容必须通过公司批准的渠道提供。

## 首次离线验收

1. 阅读 AGENTS/HANDOVER/TODO；
2. 核对 `config/project.yaml`，运行 `.\tests\static\Test-ProjectFramework.ps1`；
3. 确认只有一个 persistent MCP 会话；
4. 打开 PLC 工程并完成一次完整离线编译；
5. 记录 warning 的代码、对象和位置，不只记录总数；
6. 回读一个 AI-owned 对象并与 `src/plc/` 比较；
7. 不连接、不下载、不启停、不写实体 PLC。

## Runner Host（可选登录启动）

先构建受控源码并检查停止状态：

```powershell
dotnet build .\tools\runner\CtrlX.OpCon.Runner.Host\CtrlX.OpCon.Runner.Host.csproj -c Release
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Status
.\scripts\runner\Invoke-CtrlXOpconRunnerHost.ps1 -Command Install -WhatIf
```

确认预览的任务名和工程目录正确后，去掉 `-WhatIf` 安装当前用户登录任务。
该任务只启动 Host，不启动 Broker/MCP/PLE；工程 Agent 未由用户显式启动时
`WAITING_FOR_AGENT` 是正常状态。

## 团队交接

同一不可文本合并的 Station 工程同一时间只允许一名写入者。接手前先拉取 AI 与集成仓库；交接时记录
两个提交号、编译结果、未提交差异、IDE/锁状态以及真机操作状态。
