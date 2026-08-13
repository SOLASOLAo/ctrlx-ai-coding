# TODO.md — 路线④ PREEMPT_RT + IgH + OpenPLC

> 优先级 🔴 高 / 🟡 中 / 🟢 低;完成后勾选并把数据/结论写回 HANDOVER.md §7。
> **2026-08-12 起:剩余执行项已移植到 FreePLCDemo/TODO.md,本清单只保留路线级视图。**

## P0 · 环境
- [x] 🔴 安装 Ubuntu(实际 22.04.5 LTS,非 24.04,无碍)
- [x] 🔴 RT 内核:自编 6.12.100-rt20,CONFIG_PREEMPT_RT 激活(/sys/kernel/realtime=1)
- [x] 🔴 rt-tests:cyclictest 基线 v1(max 182µs@普通核;数据在 FreePLCDemo/data/;-q 复测见 FreePLCDemo TODO)
- [x] 🟡 C-State 限制:intel_idle.max_cstate=1 + processor.max_cstate=1(GRUB 层);BIOS 层设置项未逐项核对

## P1 · 隔离核
- [x] 🔴 GRUB:isolcpus=5,11 / nohz_full=5,11 / rcu_nocbs=5,11 / irqaffinity=0-4,6-10 / nosoftlockup 未加(待评估)
- [x] 🔴 SCHED_FIFO RT 线程跑隔离核:io_master 实证(核5,FIFO 98,1kHz,lat_us≈65µs);正式对比数据并入 P5 报告
- [x] 🟡 IRQ 亲和:GRUB irqaffinity 已配,irqbalance 未运行(无需脚本)

## P2 · EtherCAT 主站
- [x] 🔴 选型落地:**IgH 1.6.9**(直接上,未走 SOEM 探路——内核已锁定,DC 支持好)
- [x] 🔴 编译安装主站(内核 6.12.100-rt20 锁定)
- [x] 🔴 真实从站 1ms PD 交换:20 站 Beckhoff 配置已验证(PreemptRt 系统);⚠ 柜断电中,复验并入 FreePLCDemo 闭环测试

## P3 · OpenPLC
- [x] 🔴 OpenPLC_v3 runtime 安装(已装;service 损坏,根因 .venv 符号链接被 Windows 破坏;**弃 v3**)
- [ ] 🔴 **D13 变更:改用 OpenPLC v4**(安装/跑通 ST 程序 → 见 FreePLCDemo/TODO.md P3′)
  - 连接要点(2026-08-13 查明):**HTTPS 8443 + JWT**(create-user 首个=admin,无 Web UI);Editor 可 UDP LAN 发现;原生 install.sh 或 Docker(ghcr.io/autonomy-logic/openplc-runtime)
- [x] 🔴 Editor v4.2.11 装好(Windows FreePlc,NSIS 静默,启动验证过)(2026-08-13)
- [ ] 🟡 记录 runtime 周期机制(与 EtherCAT 周期对齐方式)→ 并入 FreePLCDemo P4 设计

## P4 · 集成(核心工作量)→ 全部见 FreePLCDemo/TODO.md
- [ ] 🔴 自定义 hardware layer ↔ io_master shm(不用 SOEM,D13)
- [ ] 🔴 闭环测试:输入模块 → ST 逻辑 → 输出模块
- [ ] 🟡 IO 映射配置方式初版

## P5 · 结论
- [ ] 🔴 全链路最坏延迟/抖动报告
- [ ] 🔴 路线④产品化决策建议(写入 docs/SESSION_LOG.md)
- [ ] 🟢 HMI 对接预研(路线公共底座)

## 已完成
- [x] HANDOVER + TODO 建立(2026-08-12)
- [x] 开发机环境盘点 + FreePLCDemo 项目派生(2026-08-12)
- [x] Windows 侧 Editor 安装 + Runtime v4 连接机制调研(2026-08-13)
