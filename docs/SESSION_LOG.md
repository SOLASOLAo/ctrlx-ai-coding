# ctrlX AI Coding — 讨论与决策记录(SESSION LOG)

> 记录人:AI + AGZ1WX · 2026-08-04 ~ 2026-08-22
> 本文是过程流水账;结论性内容以 `ctrlX_AI_project_baseline.md` 为准。

## 背景

用户用 ctrlX 做工程,原 Nexeed Control plus Studio(CpStudio)低代码平台过于冗余:
- 真正需要的只是它提供的 OpCon 库与一键导出能力;
- 平台本身不好用、库数量不完善;
- 初始目标曾是让 CpStudio 退化为一次性骨架/HMI 生成器；Station010 实战后于 2026-08-20 修正为
  **CpStudio 持续维护供应商模型，AI 经 MCP/REST 维护声明归属的 PLC 应用逻辑**。

## 时间线

### 2026-08-04 ~ 08-05 · 探索起步
- 安装 `@codesys/mcp-toolkit`(headless 模式),对接 ctrlX PLC Engineering;
- config.toml 初版(`config.toml.bak_ctrlx`、`bak_20260805`);
- 确认 `.project` 为加密容器(共享 15 字节头),手改文件路线放弃,只能走 IDE 脚本引擎。

### 2026-08-06 ~ 08-11 · headless 验证与路线切换
- 完成 10 项 headless 实测:打开加密工程、create_pou/set_pou_code、读回校验、全工程编译(0 errors)、
  create_project 新建工程(自带 OpCon 骨架 + 34 库占位符)、resource 读取、库管理等;
- 关键结论 ①:**PLC 侧可完全绕开 CpStudio**(库已在本地托管仓库,占位符编译时自动解析);
- 关键结论 ②:**headless 模式在 ctrlX 品牌 IDE 不可用**(脚本末尾无退出补丁,进程挂死)→ 切换 persistent;
- 08-11:config.toml 切换为 `codesys-persistent`(旧块注释保留),产出基线文档 MD + HTML。

### 2026-08-11 · 分工确定
- **用户**:CpStudio 搭骨架(Station/Module/Command 层级、HMI、handler/变量、库导出、骨架模板制作);
- **AI**:PLC 代码细节(SqM_Auto/Manual、SqS 序列、工艺逻辑、编译-修复闭环、下载调试辅助);
- 干净的 OpCon 骨架模板:AI 不代做,归用户。

### 2026-08-12 上午 · persistent 上线排障
- **IDE 自行退出(code 0)**:3 个并行 node MCP server 抢同一 profile 竞态 → 规则:同一时间只开一个 Codex 窗口;
- **CRLF 缺陷**:`get_compile_messages` 报 `SyntaxError: unexpected token '\r'` → 修补 watcher.py(行尾归一化)+ `_message_utils.py` CRLF→LF;
- **eval_python 陷阱**:对已打开工程裸调 `se.projects.open()` 卡死 UI 线程;恢复 = shutdown_codesys;正确姿势 `se.projects.primary`;
- 冒烟:compile **0 errors / 35 warnings**(培训样板固有符号警告),构建日志 Ready for download。

### 2026-08-12 下午 · 文档归档与仓库建立
- 08-12 验证过程写入基线 MD 第 7 章;
- 归档 GitHub 过程中发现:**昨日补丁脚本误吞 watcher.py 首行 docstring 引号**(`"""`→`""`),
  文件带语法错误仍在被引用 → 立即以 orig + 补丁重建规范文件(LF、无 BOM),py_compile 通过,
  MCP 实测仍正常(session ready,get_compile_messages 0.7s 返回);
- 建立本仓库:docs / config / patches / scripts / mcp_test,补丁产品化(一键脚本 + diff + 说明)。

### 2026-08-12 深夜 · 路线④开发机盘点与 FreePLCDemo 立项
- 开发机(i7-8700/8G,Ubuntu 22.04.5)实测:内核 6.12.100-rt20 PREEMPT_RT 激活;隔离核 5,11 生效;
  既有 PreemptRt 系统健康(io_master 核5 SCHED_FIFO 98 1kHz,lat_us≈65µs);从站柜未上电(link=false);
- cyclictest 基线 v1:max 182µs(T0@普通核,-i200 -l1M,无 -q,loadavg 4.4);教训:基线测试必须 -q;
- 发现 OpenPLC v3 service failed 新根因(.venv 内 20 个符号链接被 Windows 转成 reparse point,Linux 不可读),
  与既有 §4.1 runbook 不同,reset-failed 无效 → 决策弃 v3(D13);
- 修订 templates/(补 Linux 派生命令、显式会话循环、data/ 约定、衍生项目登记);
- 从模板派生 FreePLCDemo(D14),四文档写入实测事实;route4 HANDOVER §7 / TODO 全面更新。

### 2026-08-12 晚 · FreePLCDemo 设计定案 + v4 上线
- 设计讨论全部定案(存档 FreePLCDemo/docs/design-discussions-2026-08-12.md):
  P4=路线 A(igh_shm 插件);周期=总线 1ms×扫描 10ms;cycle 线程绑核 11;
  seq 咬合+双拷防撕裂;喂狗协议(manual_mode+heartbeat 2s);HMI=Avalonia(D10)+OPC UA;
- OpenPLC v4 安装完成并运行(:8443+JWT);安装坑:cmake≥3.28(pip 清华源)、tarball 非 git 仓库(跳过原生插件);
- HMI Web 原型上线 :8091(代理网关规避 dashboard 无 CORS);SOEM 原生插件未构建=物理防误用。

### 2026-08-12 深夜 · 路线④ P4 全链路闭环 🏆
- 网络定案:eno1 静态 .77(通 Windows .88),USB 移动 WiFi metric 500 分流;
- OpenPLC v4 安装(:8443+JWT);Editor v4.2.11(Windows)editor-driven 全流程跑通(task=10ms);
- **igh_shm 插件上线并闭环**:ST 程序 → runtime(核11 FIFO)→ shm → io_master → EL2008 物理输出,
  从站柜 20 站全 OP(wc=27/27);输入 %IX 已通(柜内 DI 实测进镜像表);
- Editor 兼容补丁:plcapp_management.py 保护插件(igh_shm 恒开/SOEM 恒关;升级 runtime 需重打);
- 详见 FreePLCDemo/{HANDOVER,docs/p4-integration-design}.md;剩余:P5 抖动报告 + P6 HMI(Avalonia)。


### 2026-08-13 · OpenPLC v4 调研与 Editor 安装(支撑 D13 editor-driven 模式)
- **OpenPLC Editor v4.2.11**(Autonomy-Logic,Electron+React)静默安装到 Windows 机 `PLC_Generate\FreePlc\`,启动验证通过;
- 查明 Runtime v4 连接机制:**HTTPS 8443 + JWT**(create-user 首个=admin)、**无 Web UI**;Editor 本地 STruC++ 编译 → zip 上传 → Runtime Make 编 .so;WebSocket 调试;UDP LAN 发现;协议内置 EtherCAT API(D13 自定义层不受影响,仅作参照);
- 踩坑:Electron 应用终端继承 `ELECTRON_RUN_AS_NODE=1` 致 Editor 变 Node 静默退出(exit 9),桌面启动正常;
- 公司代理拦截 release CDN → `gh release download`(走 api.github.com)绕过;
- 与另一会话(abff186 开发机盘点)合并:本条目为增量,不覆盖 FreePLCDemo 执行线。
### 2026-08-18 · 阶段2实战:Station010 IO 硬件组态修复 + IOE-IPC 工具链
- 派生项目 BPP_ResistantStation(Stat_Resistant_AI_Coding)按电气图核对 Station010 IO 组态;
- 发现 PLE 2.6.8 打开 IO 工程触发版本转换且实例崩溃 → 决策 D16:IO 工程只由 IOE 2.6.4 脚本驱动;
- 新工具 scripts/ioe_ipc.ps1:复用 MCP watcher 机制(--runscript + %TEMP%\ioe-ipc 文件命令队列)驱动独立 IOE 实例;open/树遍历/remove/save 全通;
- 真工程修复:删坏节点 _100A740_BL(Burster 5877A 为 USB 设备,误挂 EtherCAT),树与图纸页4一致(EK1100 → A1-A4 EL1018×4 + C1-C3 EL2008×3),typeId 逐项校验;备份 .bak_20260818;
- 9 条踩坑归档 docs/ioe_scripting_playbook.md(对话框阻塞主线程、.~u 残留锁、Environment.Exit 强退、插件初始化竞态、cp1252 回显假警报等)。

### 2026-08-20 · MCP 编译完成后超时修复

- 复现 Station010 的 Application Build 已在 PLE 完成，但 `compile_project` 超过 300 s；单独按消息类别/严重级别读取也超过 180 s。
- 定位为原 MCP 的重复构建与 `get_message_objects(category, severity)` 全组合扫描，而不是 PLC 编译本身。
- 扩展 `apply-crlf-patch.ps1`：应用工程只执行一次 `ScriptApplication.build()`，只按类别各调用一次 `System.get_messages(category)`，并以 IDE Build summary 计数；摘要不可验证时失败关闭。
- 同步覆盖 `compile_project` 与 `get_compile_messages`，增加 `test-fast-compile-message.py` 离线回归；`dist/scripts` 与 `src/scripts` 一起修补且 `-Check` 幂等。
- Station010 离线实测：编译约 7.6 s 返回 0 errors / 7 warnings；缓存读取约 0.8 s。未连接、下载或运行实体 PLC。

### 2026-08-20 · 跨项目初始化、Post-export 队列与 Codex Skill

- 用户确认未来会用同一方案开发多台自动化设备；把 Station010 的目录经验提炼为通用 AI 旁车模板与事务化初始化器，拒绝覆盖、统一相对路径且不复制 `.project`/Std/闭源资料。
- Post-export 从单一覆盖信号升级为 `pending/processing/done/failed` 独立队列；离线消费者只做 Git/指纹/ownership 审计，锁后枚举避免 stale candidate，并强校验请求 Station/PLC 与项目配置一致。
- 建立并安装 `ctrlx-opcon-engineering` Skill，明确初始化、导出审计、PLC 离线开发、故障诊断可组合；两轮独立前向测试发现并推动修复模板缺执行器、profile 硬编码和错误工程请求门禁。
- 产品化边界与优先级归档 `docs/mcp_productization_roadmap.md`；下一阶段先做受控 fork、会话租约、operation、`project_health`、`compile_project_v2` 与 `apply_change_set`。

### 2026-08-22 · Post-export Stage 2 PlanOnly operation ledger

- 新增 `Invoke-PostExportEngineering.ps1`：把成功的 Stage 1 报告转换为幂等 operation、不可变 action 和哈希绑定 evidence，覆盖 clean、repair、CpStudio-owned、条件 Export #2 与最终验证状态。
- 协调器只维护旁车状态，不启动 PLE、MCP 或 REST，也不访问实体 PLC；action 必须由当前唯一 persistent Codex 会话执行。
- 新增 `New-PostExportRunnerEvidence.ps1`：只验证/封装当前 runner 的显式 observation，重验 action、Stage 1、ownership、所需关键 Station 指纹、Build/PLC SHA，并生成确定性的 warning signature multiset；不会启动或调用工程工具，也不会默认把验收项设为 true。
- 新项目模板、初始化器自测、质量门禁和 `ctrlx-opcon-engineering` Skill 已同步；live engineering runner 仍由唯一 persistent Codex 会话承担，真正的跨进程 MCP 租约仍未实现。

### 2026-08-23 · 用户本地离线 Post-export checker

- 新增双击入口、PowerShell 生命周期控制器和 MCP stdio helper；仅在没有既有 PLE/MCP/工程锁时启动一组 owned 会话，执行 open + strict no-save fresh Build + messages + shutdown，不调用编辑/保存或任何在线工具。
- MCP 兼容补丁新增 strict no-save v2：dirty 状态不可确认或工程为 dirty 时拒绝 Build；checker 同时验证工程 SHA256、owned PID/父子关系、退出和锁释放，fresh evidence 与缓存诊断分离。
- Export #2 使用可验证 anchor：只由 Export #1 的 fresh verified 0-error Build 和带时间戳 request 建立，可跨对象占用、次数纠正、Output 确认及 Build 前 Link I/O 继续；进入 Build 即消费，旧终态不能复活；无 request 时不生成不可关联 anchor。
- 全局锁覆盖 anchor 选择到报告原子写入；竞争、权限、锁文件或锁目录异常均失败关闭且不落报告。根模板各 458 项离线断言、初始化器 65 项断言通过。真实生命周期 smoke test 因机器仍有既有 PLE/MCP owner 与 `.project.~u` 而按门禁延期，未强杀或手删锁。

### 2026-08-27 · Controlled Runner P1.1

- 产品顺序固定为 Runner → 项目/流程生成 → HMI 产品化 → 商业交付；当前只推进 Runner。
- 模板新增 P1.1 单一入口：校验项目/profile/manifests，使用 OS 排他文件租约，串联已有 Stage 1 审计和 Stage 2 PlanOnly ledger，并写结构化 run manifest。
- P1.1 不启动 PLE/MCP、不执行 immutable action，也没有任何在线或部署能力；当前项目和模板自测各 30 项断言，新项目初始化器 70 项回归通过。
- stdio MCP 不能由独立 CLI 复用。P1.2 必须由交互用户会话中的唯一 Agent/Broker 独占 stdio 与 PLE；未来 Windows Service 只做队列、策略和证据，不从 Session 0 启动可见 PLE。

## 关键决策清单

| # | 决策 | 日期 |
|---|---|---|
| D1 | `.project` 只能经 IDE 脚本引擎修改,不手改字节 | 08-04 |
| D2 | 历史结论：PLC 库可脱离 CpStudio 解析；“完全绕开 CpStudio”已由 D20 修正 | 08-11 |
| D3 | MCP 模式 = persistent(headless 在品牌 IDE 不可用) | 08-11 |
| D4 | 历史分工：用户骨架 / AI 细节；已由 D20/D21 扩展为长期协作与 AI 旁车初始化 | 08-11 |
| D5 | 同一时间只允许一个 Codex 窗口使用本 MCP | 08-12 |
| D6 | eval_python 仅用于审计;常规操作走正规工具 | 08-12 |
| D7 | npm 包升级后必须重打 CRLF 补丁 | 08-12 |
| D8 | .project 二进制不入仓库(Bosch 模板版权 + 体积) | 08-12 |
| D9 | 四路线组合打法:①主线/②主攻/③验证/④储备 | 08-12 |
| D10 | HMI 选型:Avalonia 原生壳或 Kiosk 主画面,Web 仅远程备选 | 08-12 |
| D12 | 路线④逻辑层 = OpenPLC,实验先行不投产;开发在独立 Linux 机 | 08-12 |
| D13 | 路线④逻辑层升级 OpenPLC **v4**(v3 EOL);不用内置 SOEM 层,自定义 hardware layer 对接既有 IgH io_master(shm);editor-driven 开发模式 | 08-12 |
| D14 | 路线④开发项目 = **FreePLCDemo**(/media/administrator/D/FreePLC/FreePLCDemo,ai-repo-skeleton 派生,独立仓库) | 08-12 |
| D15 | **Editor 回退策略**:VS Code 替代 Editor 只是一条路线;Editor v4.2.11 常备后备(不卸载/不升级、格式不分叉、单写者、里程碑回退演练);详见 FreePLCDemo handover §5 | 08-13 |
| D16 | **IO 工程只由 IOE 2.6.4 脚本驱动**(PLE 打开=版本污染+崩溃);IOE-IPC = --runscript watcher + 文件命令队列;优雅关闭 p.close(),禁 Environment.Exit;详见 docs/ioe_scripting_playbook.md | 08-18 |
| D19 | **ctrlX 编译消息使用有界读取**：应用只做一次 `build()`；只读取 Build/Additional code checks，每类一次 `get_messages`；无 Build summary 时失败关闭，不再全类别×严重级别扫描 | 08-20 |
| D20 | **CpStudio 持续作为 OpCon 模型/HMI/标准对象事实源**；AI 只维护 ownership 声明的 PLC 应用增量，导出后先审计再修复 | 08-20 |
| D21 | **新项目统一使用事务化 AI 旁车初始化器和版本化 Skill**；不复制 Station010 项目事实、`.project`、Std 或闭源资料 | 08-20 |
| D22 | **Post-export hook 只发布独立请求**；离线消费者不启动 PLE/MCP，且请求 Station/PLC 必须与项目配置强一致 | 08-20 |
| D23 | **Stage 2 先采用 PlanOnly operation ledger**；action/evidence 必须哈希绑定，协调器不启动 PLE/MCP/REST；live runner 与跨进程 MCP 租约后续实现 | 08-22 |
| D24 | **Runner 分为控制面和唯一会话执行面**；P1.1 默认不启动 PLE/MCP，P1.2 由交互会话 Agent/Broker 独占 stdio/PLE，Windows Service 不从 Session 0 启动 PLE | 08-27 |

## 待办 / 下一步

1. 新项目使用统一初始化器创建 AI 旁车；用户继续在 CpStudio 维护模型/标准对象/HMI，AI 维护 ownership 声明的 PLC 增量；
2. 配置真实 CpStudio Post-export hook，验证 Stage 1 报告和 Stage 2 PlanOnly ledger，再由既有唯一 persistent 会话执行首个 action/evidence 闭环；
3. 按 `docs/mcp_productization_roadmap.md` 建立 live runner、跨进程 MCP 租约、健康检查、结构化编译和 change set；
4. 仿真验证（set_simulation_mode）后，由用户单独批准真机下载调试；
5. **路线④**:开发机已就绪,P0~P2 完成(继承 PreemptRt);执行转入 **FreePLCDemo**(v4 安装 → P4 集成);
   交接见 `route4-rtpreempt-openplc/HANDOVER.md` §7。
## D17(2026-08-18 夜)PLE SymbolConfig 脚本极限实测 + Station010 GitHub 备份
- 实测结论:SymbolConfig 条目对 ScriptEngine 树 API 完全不可见(find/get_children/export_xml 全空);可读形态仅 IDE 导出的 Symbolconfiguration XML。详见 docs/ple_symbolconfig_git_notes.md。
- 3 个陈旧符号编译错误(bus_000S900 / _000SK010A1_Channel_6/_7)定性为非 CpStudio 产物(Engineering_Data.xml 对照),待清理。
- Station010 备份到私有仓库 SOLASOLAo/Stat_Resistant_Station010(6a7b4ea 基线 + b9b1161 快照);git 推送配方(openssl+3128+gh token)沉淀到同上笔记。
- 用户迁移到另一台设备开发,转接文档见 McpCoding/HANDOVER.md。

## D18(2026-08-18)CpStudio BMK 双层残留闭环 + connector 映射补丁

- **纠正 D17 的旧结论**：Symbol Configuration 的显示名与脚本内部名不同；内部节点为 `Symbols`，其动态扩展对象是 `ScriptSymbolConfigObject`。PLE 官方 REST API 可以稳定读写公开成员，因此不再依赖 UI。
- 官方 REST 稳定基地址：`http://localhost:9002/plc/engineering/api/v2`；应用符号接口为 `/devices/Device/Plc%20Logic/Application/symbol-config`。根路径兼容路由并不稳定，不纳入工作流。
- Station010 连续两次实测确认：CpStudio 改名/停用 BMK 会更新 `BinIo`，但可能保留 EtherCAT I/O Mapping 与 Symbol Configuration 两层旧引用；固定顺序为 Git diff → 映射修复 → Symbol Select/UnSelect → 保存 → 编译。
- 发现原 MCP `map_io_channel` 只遍历项目树子节点，无法处理 ctrlX/DataLayer 的 connector 通道。已扩展为遍历 `connectors/host_parameters/is_mappable_io/io_mapping`，支持 `Channel_6.Output` 名称定位并强制写后回读。
- 补丁已并入既有 `apply-crlf-patch.ps1`，形成单一 ctrlX 兼容补丁入口；npm 升级后必须先 `-Check` 再应用。
- 实测结果：清除 `_000SK010C1_Channel_6` 的 C1 Channel 6 映射和失效符号后，编译由 1 error / 9 warnings 恢复为 **0 errors / 7 warnings**；未连接或操作实体 PLC。

## D19(2026-08-20)ctrlX 编译消息有界读取

- `ScriptApplication.build()` 是应用工程唯一的常规 Build 入口；不把 `clean()`、`clean_all()` 与 `generate_code()`叠加到每次 MCP 编译。
- 编译结果只从 Build 与 Additional code checks 两个类别读取，每类只调用一次 `System.get_messages(category)`；IDE summary 是 error/warning 计数事实源。
- 不能解析 Build summary 时必须返回错误，不能以空消息推断编译成功。
- 该扩展纳入统一 `apply-crlf-patch.ps1`，npm 升级后与 CRLF、connector I/O Mapping 补丁一同检查和重装。
