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
   pwsh -File '<runner-host-package>\Install.ps1' `
     -Command Install -EngineeringRoot '<absolute-ai-root>' -WhatIf
   pwsh -File '<runner-host-package>\Install.ps1' `
     -Command Install -EngineeringRoot '<absolute-ai-root>'
   pwsh -File '<runner-host-package>\Install.ps1' `
     -Command Status -EngineeringRoot '<absolute-ai-root>'
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
Clean Build 取得完整且未截断的 warning 集合、执行一次不采集身份的显式用户确认并建立正式
warning/semantic baseline，并以新的 Export/immutable action 完成本工位离线验收。缺 baseline 时必须以对应 bootstrap
`BLOCKED` 结束，不会伪造成功证据。`apply_change_set_and_build` 仍不支持。只有 Symbol/后处理
证据明确要求时才安排
Export #2。

P1.3a/P1.3b Host 是独立的当前用户后台进程：除单实例、heartbeat/status、日志和
崩溃恢复外，还会自动发现并消费本次 activation 后由权威 ledger 发布的 immutable
`currentAction`。历史已终态工作被隔离，旧 open claim 可恢复；有待处理 action 且 Broker
未显式启动时保持 `WAITING_FOR_AGENT`，没有 action 时保持 `WAITING_FOR_ACTION`。

P1.3c 自动 result/evidence 摄取也随骨架提供：terminal result 和 sealed evidence 经 SHA 绑定及
只读锁校验后，由 release-bound 的纯离线 Stage 2 coordinator 推进 ledger；合法无 evidence
终态保持 `WAITING_FOR_COORDINATOR` 等待人工复核且绝不重跑。busy 使用有界退避，任何其他
fresh ledger 异常都会阻断推进。Host 不启动 Broker、Node、MCP、PLE，也不执行在线 PLC 操作。

Host runtime 使用五文件、内容寻址的 immutable release；Scheduled Task action 精确指向 active
release exe，description 记录 `releaseId + manifest SHA-256`。构建后可用 wrapper 执行
`Install/Start/Stop/Status/Logs/Rollback`：
`Install` 同时负责首次安装和升级，`Rollback` 切回精确 previous release，普通切换失败会恢复
原 task/release/运行状态；`Uninstall` 仅用于移除本项目任务。修改前可先加 `-WhatIf`。
通用 P1.3c 的 production 默认 ingestor 6 项 E2E（含真实 ledger lock）、durable
journal/reconcile、真实断点/强杀、升级回滚、损坏拒绝及 missing-deployment 安全卸载均已在
参考工作站通过；每个新工位仍需单独验证。显式 lifecycle 校验五文件 manifest/self-check；
AtLogOn 自身直接启动 action，不预检 deps/runtimeconfig。Scheduled Task 使用无控制台 apphost，
`Status/Stop/Logs` 经 `dotnet + DLL`。

团队工位使用 P1.4a 精简离线包；Host 仍需 .NET 8 runtime，但不必在本机保留 Git、Runner 源码、
SDK 或执行 build。包固定含
`Install.ps1`、canonical wrapper/module、`package-manifest.json` 和 Host 五文件；安装器在任何
命令前验证 exact inventory、path/length/SHA-256 与整体 `contentId`。同一 `Install` 用于首装和
升级，另提供精确 `Rollback`、安全 `Uninstall` 与 `Status`；fresh Install 默认不启动 Host，首次
启动仍须显式调用 canonical wrapper，升级保留原 running/stopped 状态。包沿用当前用户默认权限且不设置自定义 ACL，数字签名延期到
商业发行或公司 IT 明确要求。独立 AtLogOn 五文件 prelaunch bootstrap、兼容矩阵和全新团队
工作站验收仍未完成，因此 P1.4 不得标记完成。

`RUNNER_ACCEPTANCE_CONTRACT: clean-compile + complete-warning-set + explicit-user-confirmation; missing-baseline => bootstrap-blocked`

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
