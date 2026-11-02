# 设计源码

| 目录 | 内容 |
|---|---|
| `rtl/ofdm/` | OFDM 核心全部 RTL（Verilog-2001，29 个设计文件，另含 `.vh` 头文件与 `.mem` 正弦表）。顶层 `lean/ofdm_development_core.v`；`txs/` 发射链（PRBS 源、组帧、映射、帧网格）、`phy/` 公共物理层模块（载波装载、IFFT、CP、信道均衡、CPE、映射表 `ofdm_nc_map.vh`）、`rxs/` 流式接收机（直流抑制、检测、环形缓存、取窗、FFT、信道估计、CPE、逐载波度量 `ofdm_rxs_cmetric.v`、解码）、`interfaces/` 跨时钟域与射频边界适配 |
| `ps/` | PS 侧 Python 软件（Kuiper Linux 上运行）：`lean_ctl.py` 寄存器访问与窗口测量，`lean_adapt.py` 窗口循环、发射前频谱感知与命令行入口，`lean_nc.py` 逐组度量与联合决策策略 `JointOllaPolicyV2`，`lean_stability.py` 健康检查，`demo_view.py` 演示显示，`lean_calibration_flat.json` EVM/误包率标定表 |
| `platform/` | 板级顶层 `inputs/system_top.v`、边界模块、XDC 约束、BD 种子 `seed/system.bd`、平台输入清单与 ADI 许可证（取自 ADI 参考设计 `projects/adrv9009/zc706`） |
| `ip/` | FFT/IFFT IP 配置与接口桩，见 `ip/README.md` |

板上运行命令示例（在 `/root/lean`）：`python3 lean_adapt.py --policy joint2 --sense --calibration lean_calibration_flat.json --olla-target 0.05 --windows 60 --frames 16 --len 2048 --allow-fft-saturation --log run.jsonl`。完整上板步骤见 `../board/README.md`。
