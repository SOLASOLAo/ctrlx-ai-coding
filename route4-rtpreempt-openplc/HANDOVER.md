# HANDOVER.md — 路线④:PREEMPT_RT + IgH EtherCAT + OpenPLC

> 创建:2026-08-12 · 更新:2026-08-13(Windows 侧 Editor v4.2.11 装好;Runtime v4 连接机制查明) · 开发机:**另一台 Linux PC**(非本 Windows 工程机)
> 本文自包含:拿到 Linux 机器后,读这一份 + 配套 `TODO.md` 即可开工。
> 上游背景:本仓库 `docs/ctrlX_tech_routes.html` §5、`docs/ctrlX_AI_project_baseline.md`。

## 1. 目标与范围

**做什么**:在无 CpStudio、无 ctrlX、无 CODESYS 的前提下,用纯开源栈搭一台"软 PLC":
Linux **PREEMPT_RT** + **isolated core** 上跑 **IgH EtherCAT master** 作 IO task,
**OpenPLC Runtime** 作 cycle task(IEC 61131-3 逻辑/状态机),模拟 PLC 完整循环。

**本阶段性质**:**实验与数据采集,不是生产部署**。产出 = 周期抖动数据 + 可运行原型 + 路线④产品化决策依据。

**明确不做**:功能安全(SIL)、商用分发合规(先内部验证)、HMI(路线公共底座,以后再接)。

## 2. 架构

```
Linux 工控机/PC(实验机)
├── PREEMPT_RT 内核(主线 6.12+,RT 已并入主线)
├── 隔离核(例 CPU2,3):isolcpus + nohz_full + rcu_nocbs + IRQ 亲和
│   ├── IgH EtherCAT Master(内核模块)── IO task,1ms 周期,专用网卡
│   └── OpenPLC Runtime cycle task ── SCHED_FIFO + mlockall,读写 IgH PD
├── 普通核:SSH / 监控 / 未来 HMI / 数采
└── 参考实现:Intel ECI(Edge Controls for Industrial)、LinuxCNC 同族
```

## 3. 关键事实(已调研,勿重复踩)

| 项 | 结论 |
|---|---|
| PREEMPT_RT | 自 **Linux 6.12(2024-12)完全并入主线**,`CONFIG_PREEMPT_RT=y` 即可,无需外部补丁 |
| IgH EtherCAT Master | GPLv2(LGPL 部分),免费;官方仓库 `gitlab.com/etherlab.org/ethercat`;商业闭源分发再考虑 rt-labs 商业授权 |
| SOEM(备选主站) | 用户态、无内核模块、上手更快,但 DC 支持弱于 IgH;原型期可先用 SOEM 探路 |
| OpenPLC | **v3 已弃(D13)**;转 **Runtime v4**(`github.com/Autonomy-Logic/openplc-runtime`):headless 双进程(Flask REST + C/C++ 实时核 SCHED_FIFO,Unix socket 通信);编译链 = Editor 本地 STruC++ 生成 C++ → zip 上传 → Runtime Make 编 .so 动态加载 |
| Editor(Windows) | ✅ **v4.2.11 已装**(2026-08-13,`PLC_Generate\FreePlc`,NSIS 静默);Electron+React;userData=`%APPDATA%\open-plc-editor` |
| 连接端口 | **HTTPS 8443**(自签 TLS,Editor 自动处理;第三方工具直连需忽略证书);**v4 无 Web UI**(v3 的 8080 网页不存在了) |
| 认证 | JWT:首次 `POST /api/create-user` 免认证(首个用户自动 admin)→ `/api/login` 取 token |
| 设备发现 | Editor 支持 **UDP 广播 LAN 发现**局域网内的 Runtime |
| Runtime 部署 | 原生:`git clone` + `sudo ./install.sh` + `sudo ./start_openplc.sh`;或 Docker `ghcr.io/autonomy-logic/openplc-runtime:latest`(-p 8443:8443 --cap-add SYS_NICE SYS_RESOURCE);依赖 GCC/CMake 3.28+/Python 3.10+/root;数据目录 `/var/lib/openplc-runtime`(原生)、`/var/run/runtime`(Docker) |
| RT 官方立场 | PLC Core 已 SCHED_FIFO;**PREEMPT_RT 官方标注 "optional but beneficial"** → 与本路线天然契合 |
| EtherCAT(v4 视角) | Editor↔Runtime 协议**内置 EtherCAT API**(网卡列表/扫描从站/测试/校验/运行状态),走 Runtime 插件系统;D13 已定自定义层对接既有 io_master shm,插件仅作参照 |
| 周边仓库 | `Autonomy-Logic/matiec`(编译器 fork)、`STruCpp`(ST→C++)、`xml2st`、`user-docs` |
| 集成点(主要工作量,D13) | **自定义 hardware layer ↔ 既有 io_master shm**(不用内置 SOEM 层):OpenPLC 周期任务经共享内存读写 IgH PD + 喂狗机制 |
| 网卡 | 选 IgH 支持好的 Intel 网卡:**I210**(DC 支持成熟)/ i225/i226;EtherCAT 用独立网口 |
| Ubuntu RT 内核捷径 | Ubuntu Pro 个人免费(≤5 台)提供 realtime kernel 变体,可省去自编内核 |
| GPL 边界 | 内核模块 GPL;用户态经 ioctl 通信;仅内部实验无合规问题,**商用分发前再评估** |

## 4. 环境准备清单(Linux 机器到手后)

1. **发行版**:Ubuntu 24.04 LTS(推荐,工具链全)或 Debian 12;
2. **内核**:二选一——
   a. Ubuntu Pro 免费订阅装 realtime kernel(省事);
   b. 自编主线 ≥6.12 内核,开 `CONFIG_PREEMPT_RT=y`;
3. **验证 RT**:`sudo apt install rt-tests` → `sudo cyclictest -m -p99 -i200 -l1000000 -t` —— 记录 max 延迟(目标 <50µs,<100µs 可用);
4. **BIOS 调优**(影响抖动,必做):关 C-State / 关超线程(可选)/ 关 Spread Spectrum;
5. **GRUB 隔离核**(示例,CPU2,3):
   ```
   GRUB_CMDLINE_LINUX="isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 nosoftlockup tsc=reliable"
   ```
6. **EtherCAT 从站测试硬件**:可用 **TrainingStation 的 EtherCAT IO 模块**(现成从站);没有硬件时先用 SOEM/IgH 的本地回环或二手 IO 模块。

## 5. 阶段计划(详细勾选见 TODO.md)

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 装机 + RT 内核 | cyclictest 基线数据入库 |
| P1 | 隔离核 + SCHED_FIFO 验证 | 隔离核上跑 RT 线程,抖动对比数据 |
| P2 | EtherCAT 主站(IgH 或 SOEM)+ 真实从站跑通 PD 交换 | 1ms 周期稳定,无丢帧 |
| P3 | OpenPLC Runtime + Editor,跑通一个 ST 小程序 | LED/变量按逻辑动作 |
| P4 | **自定义 hardware layer 打通 OpenPLC ↔ EtherCAT PD** | 输入模块→ST 逻辑→输出模块闭环 |
| P5 | 全链路抖动测试 + 结论报告 | 最坏延迟数据 + 路线④产品化决策建议 |

## 6. 风险与提醒

- 🔴 **ELECTRON_RUN_AS_NODE 陷阱(已踩)**:从 Codex/VSCode 等 Electron 应用的终端启动 Editor 会继承 `ELECTRON_RUN_AS_NODE=1`,Editor 变纯 Node 静默退出(exit 9);**桌面/资源管理器启动正常**,脚本启动需从子进程环境移除该变量。
- 🔴 **RT 调优是 AI 替代性最低的环节**:IRQ 亲和、内存锁定、缓存预热都要真机实测迭代,预留人工调试时间;
- 🟡 OpenPLC v4 较新且活跃开发中(Autonomy Logic),API 可能变动;**锁定 commit/镜像版本并记录**;
- 🟡 公司代理拦截 release-assets.githubusercontent.com → 下载 release 用 `gh release download`(走 api.github.com);
- 🟡 IgH 编译对内核版本敏感:先锁定内核版本再装主站,内核升级后需重新编译模块;
- 🟡 隔离核配置后,该核对普通任务不可用,SSH/监控进程别被 isolcpus 影响(默认就不会,验证一下);
- 🟢 Windows 工程机这边(本仓库)继续路线①②主线,两边互不阻塞;阶段成果回传本仓库 `route4-rtpreempt-openplc/`。

## 7. 交接状态

| 项 | 状态 |
|---|---|
| 路线决策 | D9/D12 → 追加 D13/D14:逻辑层升级 OpenPLC v4;开发项目 = FreePLCDemo |
| Linux 开发机 | ✅ 就绪(2026-08-12 实测):Ubuntu 22.04.5、内核 6.12.100-rt20(PREEMPT_RT 激活)、隔离核 5,11、governor 默认 powersave(测试前切 performance) |
| cyclictest 基线 | ✅ v1 已测:max 182µs(T0@普通核,-i200 -l1M,无 -q,loadavg 4.4);数据存 FreePLCDemo/data/;-q 复测入 FreePLCDemo TODO |
| EtherCAT | ✅ IgH 1.6.9 + io_master 1kHz 运行中(既有 PreemptRt 系统,见 `../PreemptRt/HANDOVER.md`);⚠ 从站柜当前未上电(link=false) |
| OpenPLC | ✅ v3 已装(弃修);➡ 转 v4(/media/administrator/D/openplc-runtime,未安装)。**安装后监听 8443/HTTPS**;Editor 连接:LAN 发现或 IP 直连 → create-user(首个=admin)→ login |
| 代码 | FreePLCDemo 项目已派生(ai-repo-skeleton 模板,独立仓库) |
| Editor(Windows) | ✅ v4.2.11 装好并运行过(FreePlc);启动陷阱见 §6;⚠ 公司网络下 release 下载走 gh API |
| 阻塞项 | 从站柜上电(用户操作) |
| 下次会话第一步 | 安装 OpenPLC v4(install.sh 或 Docker)→ 防火墙放行 8443 → **Windows Editor 连接测试(create-user/login)** → 从站柜上电验证健康三元组 → P4 集成设计(shm 直读 + 喂狗机制) |
