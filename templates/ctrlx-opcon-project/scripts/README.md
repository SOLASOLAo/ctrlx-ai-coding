# 项目自动化脚本

- `cpstudio/`：hook 只发布 Stage 1 请求；Stage 2 PlanOnly coordinator 只生成 action/校验 evidence，不启动 PLE、MCP 或 REST；
- `plc/`：MCP/REST 的 dry-run、change-set、回读和快照辅助；
- `ioe/`：只通过匹配版本 IO Engineering 操作 IO 工程；
- `git/`：差异、审计、证据和提交辅助；
- `setup/`：不会启动 IDE、不会写工程的只读环境体检。

通用能力优先留在方法论仓库或 MCP；项目脚本只保留 {{STATION_ID}} 的薄配置/适配，避免跨项目复制漂移。
Stage 2 的 live runner 与跨进程 MCP 租约尚未实现，action 由既有唯一 persistent Codex 会话执行。
