# 项目自动化脚本

- `cpstudio/`：hook 只发布 Stage 1 请求；另有必须由用户双击、且只在 0 个既有 PLE/MCP 时运行的离线 Build 检查器；
- `runner/`：受控 Runner 入口；P1.1 做项目预检和 Stage 1/Stage 2 编排，P1.2a 连接既有 Broker 并封口 action 证据，P1.2b 提供显式启动的 interactive Broker，P1.3a/b Host 提供后台状态、日志、恢复和自动 action 消费，P1.3c 提供受控 evidence 摄取及 immutable release 生命周期；
- `plc/`：MCP/REST 的 dry-run、change-set、回读和快照辅助；
- `ioe/`：只通过匹配版本 IO Engineering 操作 IO 工程；
- `git/`：差异、审计、证据和提交辅助；
- `setup/`：不会启动 IDE、不会写工程的只读环境体检。

通用能力优先留在方法论仓库或 MCP；项目脚本只保留 {{STATION_ID}} 的薄配置/适配，避免跨项目复制漂移。
Runner P1.1/P1.2a 都不启动 PLE/MCP/Broker。P1.2b interactive Broker 离线基础已实现，使用 Named Pipe v2、current-user registration、durable submit/query 和单 owner 租约，但只能由交互用户显式启动。本工位的受控 adapter、语义证据 producer 和真实 PLE 离线 acceptance 通过前，生产 action 必须失败关闭。离线检查器只生成 advisory report，不冒充 Stage 2 evidence，也不会被 hook 自动调用。
P1.3a/P1.3b/P1.3c Host 不启动 Broker/Node/MCP/PLE，也不执行在线操作；有待处理 action 且
没有有效 Agent 时显示 `WAITING_FOR_AGENT`，没有 action 时显示 `WAITING_FOR_ACTION`。terminal
evidence 经 SHA/只读锁门禁后只交给 release-bound 的纯离线 Stage 2；合法无 evidence 终态保持
`WAITING_FOR_COORDINATOR` 人工复核。Host 使用五文件内容寻址 release，wrapper 通过 `Install`
首装/升级、`Rollback` 精确回退。P1.3c 的 production ingestor 6 项 E2E、durable
journal/reconcile、真实强杀恢复、升级回滚、损坏拒绝与 missing-deployment 安全卸载已通过
参考工作站验收；task action 指向 exact release exe，description 记录 manifest。显式 lifecycle
校验五文件/self-check，AtLogOn 自身不预检 deps/runtimeconfig。P1.4a 精简团队离线包固定包含
`Install.ps1`、canonical wrapper/module、package manifest 与 Host 五文件；接收工位用
PowerShell 7 安装，Host 仍需 .NET 8 runtime，但无需 Git、源码、SDK 或 build。同一 `Install`
用于首装/升级；fresh Install 默认不 Start，升级保留原 running/stopped 状态。另有精确
`Rollback`、安全 `Uninstall` 和 `Status`。默认沿用当前用户权限、不设置自定义 ACL，数字签名
延期到商业/公司 IT 明确要求。独立 AtLogOn 五文件 prelaunch bootstrap、兼容矩阵和新工作站验收
仍未完成，P1.4 不得标记完成。
