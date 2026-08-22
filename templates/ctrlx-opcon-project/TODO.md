# TODO — {{DISPLAY_NAME}}

## P0：首次离线基线

- [ ] 核对 `config/project.yaml` 的 Station、Std、CpStudio、PLC、IO 和 BusConfig 相对路径；
- [ ] 在 `specs/` 登记初始 Station、I/O 和 Event，所有未知项标记 `pending`；
- [ ] 在 `ai/` 登记第一个 AI-owned 对象和 mixed hook；
- [ ] 只登记项目实际使用且已经核对的 Catalog 对象；
- [ ] 运行 `.\tests\static\Test-ProjectFramework.ps1`；
- [ ] 经唯一 persistent MCP 会话完成完整离线编译，记录 error=0 和 warning 签名基线；
- [ ] 初始化 Git，提交并推送 AI 仓库；集成工程使用独立受控仓库。

## P1：CpStudio 集成

- [ ] 配置只向 `data/requests/pending/` 发布独立请求的 Post-export hook；
- [ ] 运行 `tests/cpstudio/Test-PostExportQueue.ps1`，验证队列、锁、失败留痕和只读 Station 审计；
- [ ] 运行 `tests/cpstudio/Test-PostExportEngineering.ps1`，验证 PlanOnly operation/action/evidence 与条件 Export #2 状态机；
- [ ] 验证导出后 ownership/hooks/graphical、I/O Mapping 和 Symbol Configuration 审计；
- [ ] 用真实 Stage 1 报告建立一次 Stage 2 ledger，并由既有唯一 persistent 会话提交 action evidence；
- [ ] 记录导出批次、回读结果和编译证据。live runner 与跨进程 MCP 租约尚未实现。

## P2：仿真与真机

- [ ] 为 AI-owned FB/Chain 建立离线或仿真测试；
- [ ] 由用户单独确认现场安全、下载、启停和 FORCE 流程；
- [ ] 完成团队工作站部署与交接验收。
