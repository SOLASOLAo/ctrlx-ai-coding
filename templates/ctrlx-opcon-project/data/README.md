# 本地运行数据

- `requests/`：CpStudio Post-export 的 `pending/processing/done/failed` 请求队列；
- `snapshots/`：PLC/IO/Symbol 规范化快照；
- `reports/`：审计、编译和测试报告；
- `backups/`：明确需要时创建的本地受控备份。

这些目录内容默认不入 Git；结论写入 `docs/` 或 `HANDOVER.md`。
