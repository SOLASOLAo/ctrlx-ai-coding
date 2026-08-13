# ctrlX AI Coding — 讨论与决策记录(SESSION LOG)

> 记录人:AI + AGZ1WX · 2026-08-04 ~ 2026-08-12
> 本文是过程流水账;结论性内容以 `ctrlX_AI_project_baseline.md` 为准。

## 背景

用户用 ctrlX 做工程,原 Nexeed Control plus Studio(CpStudio)低代码平台过于冗余:
- 真正需要的只是它提供的 OpCon 库与一键导出能力;
- 平台本身不好用、库数量不完善;
- 目标:**用 AI(MCP 驱动)替代 CpStudio 完成 PLC 程序主体**,CpStudio 退化为"骨架/HMI 一次性生成器"。

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

## 关键决策清单

| # | 决策 | 日期 |
|---|---|---|
| D1 | `.project` 只能经 IDE 脚本引擎修改,不手改字节 | 08-04 |
| D2 | PLC 侧完全绕开 CpStudio(库走本地托管仓库) | 08-11 |
| D3 | MCP 模式 = persistent(headless 在品牌 IDE 不可用) | 08-11 |
| D4 | 分工:用户骨架 / AI 细节;骨架模板 AI 不代做 | 08-11 |
| D5 | 同一时间只允许一个 Codex 窗口使用本 MCP | 08-12 |
| D6 | eval_python 仅用于审计;常规操作走正规工具 | 08-12 |
| D7 | npm 包升级后必须重打 CRLF 补丁 | 08-12 |
| D8 | .project 二进制不入仓库(Bosch 模板版权 + 体积) | 08-12 |
| D9 | 四路线组合打法:①主线/②主攻/③验证/④储备 | 08-12 |
| D10 | HMI 选型:Avalonia 原生壳或 Kiosk 主画面,Web 仅远程备选 | 08-12 |
| D12 | 路线④逻辑层 = OpenPLC,实验先行不投产;开发在独立 Linux 机 | 08-12 |
| D13 | 路线④逻辑层升级 OpenPLC **v4**(v3 EOL);不用内置 SOEM 层,自定义 hardware layer 对接既有 IgH io_master(shm);editor-driven 开发模式 | 08-12 |
| D14 | 路线④开发项目 = **FreePLCDemo**(/media/administrator/D/FreePLC/FreePLCDemo,ai-repo-skeleton 派生,独立仓库) | 08-12 |

## 待办 / 下一步

1. 用户:CpStudio 骨架(层级/HMI/handler/变量)+ 骨架模板整理(剥离 TrainingStation IO);
2. 骨架就绪 → AI 阶段 3:读骨架 → 写 SqM/SqS 细节 → compile 结构化错误闭环;
3. 仿真验证(set_simulation_mode)→ 真机下载调试;
4. 产品化方向:补丁/工具沉淀、自定义库集合、AI 代码生成规范、可复用的项目模板。
5. **路线④**:开发机已就绪,P0~P2 完成(继承 PreemptRt);执行转入 **FreePLCDemo**(v4 安装 → P4 集成);
   交接见 `route4-rtpreempt-openplc/HANDOVER.md` §7。