# HANDOVER — {{DISPLAY_NAME}}

最后更新：{{CREATED_DATE}}

## 当前结论

- 已创建 {{STATION_ID}} 的标准 CpStudio + ctrlX MCP AI 旁车目录；
- Station 与 `Std` 仅通过 `config/project.yaml` 的相对路径引用，没有复制任何闭源资产或 `.project`；
- 尚未连接、下载、启停或写入实体 PLC。

## 待核对

- `config/project.yaml` 中为 `null` 的 CpStudio、PLC、IO 或 BusConfig 路径；
- CpStudio/PLE/IOE 的项目实际版本；
- 第一次完整离线编译的 warning 签名基线；
- 初始 BMK、Event、Unit、Peripheral、AddOn 和 Chain 规格；
- CpStudio Post-export hook 的安装位置；Stage 1 队列/离线审计与 Stage 2 PlanOnly ledger 已随骨架生成，尚待真实导出验证；
- Stage 2 已包含 P1.2a .NET action client 和 P1.2b interactive Broker：Named Pipe v2、current-user validated registration、durable submit/query、双层租约、typed action 及长 Build 查询语义。参考环境的 ownership/fresh-Build adapter 与只读 semantic snapshot 技术通道已实测；当前工位仍须安装并 `-Check` adapter、配置 semantic scope、取得完整且未截断的 warning 集合、建立绑定独立人工证据的正式 warning/semantic baseline，并用新的 immutable action 完成本工位离线验收。缺 baseline 时必须以对应 bootstrap `BLOCKED` 结束，不会伪造 Build 成功；`apply_change_set_and_build` 仍不支持。

## 下次第一步

运行 `.\tests\static\Test-ProjectFramework.ps1`，再按 `TODO.md` 从 P0 开始补齐项目事实。

## 工作树/部署状态

- 新生成骨架，尚未初始化 Git 或推送；
- PLE/IOE/CpStudio 运行状态：未检查；
- 实体 PLC 操作授权：无。
