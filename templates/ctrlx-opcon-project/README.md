# {{DISPLAY_NAME}}

{{STATION_ID}} 的 CpStudio + ctrlX PLC Engineering + Codex/MCP AI 开发旁车仓库。

本仓库保存可读需求、AI 对象归属、PLC 源码、Catalog、自动化脚本和验证证据。供应商生成工程位于
`{{STATION_ROOT_REL}}`，标准对象位于 `{{STANDARD_LIBRARY_ROOT_REL}}`；两者都不会复制进本仓库。

## 快速开始

1. 阅读 `AGENTS.md`、`HANDOVER.md` 和 `TODO.md`；
2. 核对 `config/project.yaml`，把仍为 `null` 的工程路径补齐；
3. 在 `specs/` 中登记已确认的 Station、I/O、Event、Unit 和 Chain；
4. 运行纯离线框架检查：

   ```powershell
   .\tests\static\Test-ProjectFramework.ps1
   ```

5. 运行 Post-export 队列的纯离线自测：

   ```powershell
   .\tests\cpstudio\Test-PostExportQueue.ps1
   ```

6. 运行 Stage 2 PlanOnly operation ledger 的纯离线自测：

   ```powershell
   .\tests\cpstudio\Test-PostExportEngineering.ps1
   ```

7. 首次操作 PLC 工程前，确认只有一个 persistent MCP 会话使用该 PLE profile。

8. 检查受控 Runner（不会启动 PLE/MCP）：

   ```powershell
   .\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command Status
   .\scripts\runner\Invoke-CtrlXOpconRunner.ps1 -Command Doctor
   ```

CpStudio Export #1 的离线报告可交给
`scripts/cpstudio/Invoke-PostExportEngineering.ps1`。该工具只生成带哈希的
operation/action 并接收 runner 证据，不启动 PLE/MCP/REST。P1.1 Runner 统一执行
Stage 1/Stage 2 控制面；P1.2a .NET 客户端校验并消费 immutable action，但只连接
已存在的本地 Broker。P1.2b interactive Broker 离线基础已随骨架提供：它使用
current-user validated registration、Named Pipe v2、durable submit/query、单 profile/project
owner 和 typed action allowlist。它必须显式启动，action wrapper 不会自行启动
PLE、MCP 或 Broker。参考环境中的受控 adapter、显式 `clean_compile_project` 和只读 semantic
snapshot 技术通道已经实测；新工位仍须安装并校验 adapter、配置 semantic scope、用显式
Clean Build 取得完整且未截断的 warning 集合、建立绑定独立人工证据的正式 warning/semantic
baseline，并以新 immutable action 完成本工位离线验收。缺 baseline 时必须以对应 bootstrap
`BLOCKED` 结束，不会伪造成功证据。`apply_change_set_and_build` 仍不支持。只有 Symbol/后处理
证据明确要求时才安排
Export #2。

`RUNNER_ACCEPTANCE_CONTRACT: clean-compile + complete-warning-set + independent-review; missing-baseline => bootstrap-blocked`

## 目录

```text
├── config/       工程定位和质量门禁
├── specs/        已确认的业务/电气规格
├── ai/           AI 对象归属、混合钩子和图形属性
├── src/plc/      可读 PLC 源码
├── catalog/      已核对的标准对象接口，不存闭源实现
├── scripts/      CpStudio、PLC、IOE、Git 和环境辅助
├── tests/        静态、编译和仿真检查
├── data/         本地请求、快照、报告和备份，默认不入 Git
└── docs/         架构、决策和操作文档
```

工作区必须保持 Station、`Std` 与本仓库为三个独立的同级树。不要为了目录美观移动 CpStudio 生成目录。

## 当前状态

- 初始化日期：{{CREATED_DATE}}
- PLC 工程路径和首次离线编译基线：待确认
- 实体 PLC 操作：未授权；初始化流程不连接、不下载、不启停、不 FORCE
