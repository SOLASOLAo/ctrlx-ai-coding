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
- Stage 2 已包含 P1.2a .NET action client 和 P1.2b interactive Broker：Named Pipe v2、current-user validated registration、durable submit/query、双层租约、typed action 及长 Build 查询语义。参考环境的 ownership adapter、显式 `clean_compile_project` 与只读 semantic snapshot 技术通道已实测；当前工位仍须安装并 `-Check` adapter、配置 semantic scope、用显式 Clean Build 取得完整且未截断的 warning 集合、由项目负责人一次确认 warning/semantic candidates（不采集姓名/工号），并用新的 immutable action 完成本工位离线验收。缺 baseline 时必须以对应 bootstrap `BLOCKED` 结束，不会伪造 Build 成功；`apply_change_set_and_build` 仍不支持。
- P1.3a/P1.3b/P1.3c Host 随骨架提供：交接时记录本机登录任务、Host `Status`、activation、active/previous release、runtime manifest SHA 和 Broker registration。Host 自动消费 activation 后的 immutable `currentAction`；历史已终态工作隔离，旧 open claim 可恢复。有待处理 action 且 Broker 未显式启动时 `WAITING_FOR_AGENT` 是预期状态，无 action 时为 `WAITING_FOR_ACTION`。terminal result/evidence 经 SHA 绑定和只读锁验证后自动交给 release-bound 的纯离线 Stage 2 coordinator；合法无 evidence 终态保持 `WAITING_FOR_COORDINATOR` 等待人工复核，busy 有界退避，其他 fresh ledger 异常阻断。Host 不启动 Broker/Node/MCP/PLE，也不执行在线操作。通用 P1.3c 的 production ingestor 6 项 E2E、durable journal/reconcile、真实强杀恢复、升级回滚、损坏拒绝和 missing-deployment 安全卸载已在参考工作站通过；当前工位仍须单独验证。
- 团队工位优先使用 P1.4a 精简离线包：包内固定为 `Install.ps1`、canonical wrapper/module、`package-manifest.json` 与 Host 五文件；安装器在任何命令前复核 path/length/SHA-256/contentId。接收工位用 PowerShell 7 对本 AI 工程根目录安装；Host 仍需 .NET 8 runtime，但无需 Git、源码、SDK 或本机 build。同一 `Install` 用于首装/升级；fresh Install 默认不 Start，升级保留原 running/stopped 状态。另有精确 `Rollback`、安全 `Uninstall` 和 `Status`；交接时记录 package `contentId` 与命令结果。
- P1.4a 沿用当前用户默认权限，不设置自定义 ACL，数字签名延期到商业发行或公司 IT 明确要求。独立 AtLogOn 五文件 prelaunch bootstrap 延期到商业化/无人值守部署阶段，不阻塞开发；兼容矩阵和新工作站验收在有团队工位时执行，P1.4 产品化范围保持开放。

## 下次第一步

运行 `.\tests\static\Test-ProjectFramework.ps1`，再按 `TODO.md` 从 P0 开始补齐项目事实。

## 工作树/部署状态

- 新生成骨架，尚未初始化 Git 或推送；
- PLE/IOE/CpStudio 运行状态：未检查；
- 实体 PLC 操作授权：无。
