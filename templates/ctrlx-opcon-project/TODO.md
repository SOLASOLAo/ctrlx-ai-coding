# TODO — {{DISPLAY_NAME}}

## P0：首次离线基线

- [ ] 核对 `config/project.yaml` 的 Station、Std、CpStudio、PLC、IO 和 BusConfig 相对路径；
- [ ] 在 `specs/` 登记初始 Station、I/O 和 Event，所有未知项标记 `pending`；
- [ ] 在 `ai/` 登记第一个 AI-owned 对象和 mixed hook；
- [ ] 只登记项目实际使用且已经核对的 Catalog 对象；
- [ ] 运行 `.\tests\static\Test-ProjectFramework.ps1`；
- [ ] 经唯一 persistent MCP 会话执行显式 `clean_compile_project`，记录 error=0 和完整 warning 签名基线；
- [ ] 初始化 Git，提交并推送 AI 仓库；集成工程使用独立受控仓库。

## P1：CpStudio 集成

- [ ] 配置只向 `data/requests/pending/` 发布独立请求的 Post-export hook；
- [ ] 运行 `tests/cpstudio/Test-PostExportQueue.ps1`，验证队列、锁、失败留痕和只读 Station 审计；
- [ ] 运行 `tests/cpstudio/Test-PostExportEngineering.ps1`，验证 PlanOnly operation/action/evidence 与条件 Export #2 状态机；
- [ ] 验证导出后 ownership/hooks/graphical、I/O Mapping 和 Symbol Configuration 审计；
- [ ] 用真实 Stage 1 报告建立一次 Stage 2 ledger，由显式启动的唯一 interactive Broker 执行 action，并提交封口 evidence；
- [ ] 运行 `tests/runner/Test-CtrlXOpconRunner.ps1`，验证 P1.1 单 owner、项目预检、幂等消费和 run manifest；
- [ ] 运行 `scripts/runner/Invoke-CtrlXOpconRunner.ps1 -Command Doctor`，验证 P1.2a .NET action client、工程定位和 Broker 状态；
- [ ] 验证本机 Scheduled Task 使用无控制台 apphost，`Status/Stop/Logs` 经 `dotnet + DLL`，启动时不新增 WindowsTerminal/OpenConsole/conhost；
- [ ] 构建并验证 P1.3b Host：单实例、`Start/Stop/Status/Logs`、崩溃恢复，以及 activation 后 immutable `currentAction` 的自动发现/消费；
- [ ] 有待处理 action 且 Broker 未启动时确认 Host 为 `WAITING_FOR_AGENT`，无 action 时为 `WAITING_FOR_ACTION`，并确认不新增 Broker/Node/MCP/PLE 进程；旧 open claim 可恢复，历史已终态工作不重跑；
- [ ] 确认 action 终态落盘后 Host 为 `WAITING_FOR_COORDINATOR`；待通用工具补齐 coordinator/evidence ingestion 后，再验证 ledger 自动推进；
- [ ] 待 P1.3c 补齐 coordinator/evidence ingestion、完整 payload pin、稳定安装目录、升级和回滚后，完成本工作站部署验证；P1.3c 完成前不得标记产品化 Host 已交付；
- [ ] 安装并 `-Check` 本工位受控 adapter，配置 semantic scope，用显式 Clean Build 取得完整且未截断的 warning 集合，由项目负责人一次确认 candidates（不采集姓名/工号），再用新的 immutable action 完成真实 PLE 离线 acceptance；缺 baseline 时必须以对应 bootstrap `BLOCKED` 失败关闭；
- [ ] 记录导出批次、回读结果、编译证据和 baseline 审阅证据。

## P2：仿真与真机

- [ ] 为 AI-owned FB/Chain 建立离线或仿真测试；
- [ ] 由用户单独确认现场安全、下载、启停和 FORCE 流程；
- [ ] 完成团队工作站部署与交接验收。
