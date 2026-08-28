# 项目自动化脚本

- `cpstudio/`：hook 只发布 Stage 1 请求；另有必须由用户双击、且只在 0 个既有 PLE/MCP 时运行的离线 Build 检查器；
- `runner/`：受控 Runner 入口；P1.1 做项目预检和 Stage 1/Stage 2 编排，P1.2a 连接既有 Broker 并封口 action 证据，P1.2b 提供显式启动的 interactive Broker，P1.3a Host 提供后台状态/日志/恢复；
- `plc/`：MCP/REST 的 dry-run、change-set、回读和快照辅助；
- `ioe/`：只通过匹配版本 IO Engineering 操作 IO 工程；
- `git/`：差异、审计、证据和提交辅助；
- `setup/`：不会启动 IDE、不会写工程的只读环境体检。

通用能力优先留在方法论仓库或 MCP；项目脚本只保留 {{STATION_ID}} 的薄配置/适配，避免跨项目复制漂移。
Runner P1.1/P1.2a 都不启动 PLE/MCP/Broker。P1.2b interactive Broker 离线基础已实现，使用 Named Pipe v2、current-user registration、durable submit/query 和单 owner 租约，但只能由交互用户显式启动。本工位的受控 adapter、语义证据 producer 和真实 PLE 离线 acceptance 通过前，生产 action 必须失败关闭。离线检查器只生成 advisory report，不冒充 Stage 2 evidence，也不会被 hook 自动调用。
P1.3a/P1.3b Host 同样不启动 Broker/MCP/PLE；有待处理 action 且没有有效 Agent 时显示
`WAITING_FOR_AGENT`，没有 action 时显示 `WAITING_FOR_ACTION`。
