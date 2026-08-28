# AGENTS.md — {{DISPLAY_NAME}} AI Agent 工作指南

> 任何 AI 编码代理在本仓库工作前，先读完本文件，再读 `HANDOVER.md` 和 `TODO.md`。

## 1. 项目一句话

基于 {{PLATFORM}} 开发 {{DISPLAY_NAME}}（{{STATION_ID}}）：CpStudio 维护供应商模型/HMI，AI 依据
`specs/` 与 `ai/` 清单，经受控 MCP/REST 维护 PLC 应用逻辑。

## 2. 分工

| 角色 | 职责 |
|---|---|
| 用户 | 架构与工艺决策、CpStudio 骨架、硬件接线/组态、真机安全确认和部署批准 |
| AI | 可读规格和 PLC 源码、MCP 写入/回读、离线编译闭环、静态/仿真测试和文档 |

## 3. 红线

1. `.project` 是 IDE 管理的加密容器，禁止手改文件字节；只能通过对应 IDE、MCP 或正式接口修改。
2. 连接实体 PLC、下载、启停和变量写入/FORCE 前必须取得用户明确批准；离线检查和仿真不等于真机授权。
3. `{{STATION_ROOT_REL}}` 是 CpStudio/IDE 集成工程；生成后先 diff，再按 `ai/` 清单恢复 AI 增量。
4. `{{STANDARD_LIBRARY_ROOT_REL}}` 是只读供应商资产；禁止修改、删除、移动或复制进本仓库。
5. 同一时间只允许一个 persistent MCP/Codex 会话使用同一 PLE profile 和工程。
6. 完整 AI-owned 对象放 `src/plc/`；CpStudio-owned 或 mixed 对象只做声明过的语义合并，禁止旧副本整对象覆盖。
7. 不入库：`.project`、编译缓存、用户配置、凭据、许可证、闭源手册、原始生产数据和大型运行日志。
8. IO 工程只由匹配版本的 ctrlX IO Engineering 处理；禁止用 PLC Engineering 打开 IO 工程。

## 4. 事实源

- `config/project.yaml`：路径、IDE 版本、profile 和仓库地址；
- `specs/`：用户确认后的长期需求，未确认内容必须标记 `pending`；
- `ai/ownership.yaml`：对象负责人和写入模式；
- `ai/hooks.yaml`：CpStudio 生成对象中必须保留的最小调用/接线；
- `ai/graphical.yaml`：SFC 图形属性与正式 REST 写入策略；
- `src/plc/`：AI-owned 对象的可读源；
- `HANDOVER.md`：当前状态；`TODO.md`：下一步。

## 5. 标准闭环

1. 确认或更新 `specs/`；
2. 生成 dry-run 计划并核对对象归属；
3. 经 MCP/REST/IOE 写入，不直接改工程文件；
4. 回读并比较规范化内容；
5. 完整离线编译和静态检查；
6. 记录证据、更新 HANDOVER/TODO，再提交和推送。

CpStudio 导出后，必须同时审计 AI-owned 对象、mixed hooks、I/O Mapping、BinIo、Symbol
Configuration 和 SFC 图形属性。Post-export hook 只发布 Stage 1 请求；Stage 2 PlanOnly coordinator 只生成
哈希绑定的 action 并校验 evidence，不启动 PLE、MCP 或 REST。P1.2a client 与 P1.2b
interactive Broker 离线基础已随骨架提供；Broker 使用 Named Pipe v2、current-user
validated registration、durable submit/query 和单 owner 租约，并必须由交互用户显式启动。
P1.3a/P1.3b current-user Host 可在后台提供单实例、状态、日志和崩溃恢复，并自动发现、
消费本次 activation 后的 immutable `currentAction`。历史已终态工作隔离，旧 open claim
可恢复；缺少有效同会话 Agent 时 `WAITING_FOR_AGENT` 是正常等待状态。P1.3c 对 terminal
result/evidence 做 SHA 绑定和只读锁校验，再调用 release-bound 的纯离线 Stage 2 coordinator
推进 ledger；合法无 evidence 终态保持 `WAITING_FOR_COORDINATOR` 等待人工复核且不重跑，
busy 有界退避，任一其他 fresh ledger 异常阻断。Host 绝不启动 Broker、Node、MCP、PLE，
也不执行在线 PLC 操作。Host 以五文件内容寻址 immutable release 安装；task action 必须精确
指向 active release exe，description 记录 `releaseId + manifest SHA-256`。显式 lifecycle 校验
五文件 manifest/self-check，但 AtLogOn 自身不会预检 `.deps.json`/`.runtimeconfig.json`。
通用 P1.3c 技术实现和参考工作站验收已完成；团队发行、签名/ACL、受控安装及 AtLogOn 启动前
五文件 bootstrap 属于尚未完成的 P1.4。
在受控 adapter、语义证据 producer 及真实 PLE 离线 acceptance 通过前，生产 action 必须失败关闭。

## 6. PLC ST 风格

每个独立条件都用括号包裹，括号内侧各留一个空格；复合条件换行时 `AND`/`OR` 放在上一行末尾：

```st
IF ( ConditionA ) AND
   ( ConditionB )
THEN
```

## 7. 会话纪律

- 进场：读 AGENTS → HANDOVER → TODO → 本次相关 specs/ai/catalog；
- 收场：更新 HANDOVER、勾选 TODO、运行门禁、提交并推送；
- 提交前缀：`feat:`、`fix:`、`docs:`、`test:`、`tools:`、`refactor:`。

## 8. 当前状态

- [x] {{CREATED_DATE}}：创建标准 AI 旁车骨架；
- [ ] 补齐工程路径、初始规格和 Catalog；
- [ ] 用显式 `clean_compile_project` 建立首次离线编译与完整 warning 签名基线；
- [ ] 配置并验证 CpStudio Post-export Stage 1 请求与 Stage 2 PlanOnly ledger。
- [ ] 验证本工位受控 adapter、语义证据 producer 和真实 PLE 离线 acceptance；完成前不得将生产 action 标记成功。
- [ ] 验证本工位 P1.3b/P1.3c Host 的 activation 后 action 消费、历史隔离、旧 claim 恢复、自动 evidence 摄取与合法无 evidence 人工复核；记录 immutable release 的 `Install`/`Rollback`、durable reconcile、损坏拒绝和安全卸载。通用 P1.3c 已完成，P1.4 团队发行/签名/ACL/受控安装/AtLogOn 五文件 bootstrap 仍待完成。
