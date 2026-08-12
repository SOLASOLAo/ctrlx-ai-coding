# TODO.md — 路线④ PREEMPT_RT + IgH + OpenPLC

> 优先级 🔴 高 / 🟡 中 / 🟢 低;完成后勾选并把数据/结论写回 HANDOVER.md §7。

## P0 · 环境(机器到手即做)
- [ ] 🔴 安装 Ubuntu 24.04 LTS(或 Debian 12)
- [ ] 🔴 RT 内核:Ubuntu Pro realtime kernel 或自编 ≥6.12(CONFIG_PREEMPT_RT=y)
- [ ] 🔴 rt-tests:cyclictest 基线(max 延迟,记录 CPU 型号/内核版本)
- [ ] 🟡 BIOS:关 C-State / Spread Spectrum,记录设置项

## P1 · 隔离核
- [ ] 🔴 GRUB:isolcpus/nohz_full/rcu_nocbs + nosoftlockup
- [ ] 🔴 SCHED_FIFO RT 线程跑在隔离核,对比抖动数据
- [ ] 🟡 IRQ 亲和脚本(网卡 IRQ → 隔离核)

## P2 · EtherCAT 主站
- [ ] 🔴 选型落地:先 SOEM 探路 或 直接 IgH(记录理由)
- [ ] 🔴 编译安装主站(锁定内核版本)
- [ ] 🔴 接真实从站(TrainingStation IO 模块),1ms PD 交换稳定

## P3 · OpenPLC
- [ ] 🔴 OpenPLC_v3 runtime 安装(install.sh linux)
- [ ] 🔴 OpenPLC Editor 写 ST 小程序并下装运行
- [ ] 🟡 记录 runtime 周期机制(与 EtherCAT 周期对齐方式)

## P4 · 集成(核心工作量)
- [ ] 🔴 自定义 OpenPLC hardware layer ↔ IgH/SOEM PD 映射
- [ ] 🔴 闭环测试:输入模块 → ST 逻辑 → 输出模块
- [ ] 🟡 IO 映射配置方式(文件/工具)初版

## P5 · 结论
- [ ] 🔴 全链路最坏延迟/抖动报告
- [ ] 🔴 路线④产品化决策建议(写入 docs/SESSION_LOG.md)
- [ ] 🟢 HMI 对接预研(路线公共底座)

## 已完成
- [x] HANDOVER + TODO 建立(2026-08-12)