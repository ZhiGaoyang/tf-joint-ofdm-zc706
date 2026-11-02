# 本仓库目录结构下的验证记录（2026-11-02）

把本仓库复制到新目录，按 `src/ip/README.md` 放入 FFT/IFFT 网表与行为模型后，在 `sim/` 下按 `sim/README.md` 的命令依次运行：TX 帧网格、逐载波度量模块单元仿真、TX→RX 环回（屏蔽 1 组场景 `3,256,0,2,128,7,16,0,0`）、RX 核心（`nc_tone`、`nc_switch`、`clean_mixed` 三个场景）、开发核心整体仿真（Vivado 2023.2 xsim）。
`summary.txt` 为各项退出码与耗时（同一轮还在仓库根目录运行了 `build/core_synth.tcl`，见 `build/reports/repo_layout_core_synth_20261102/`），其余文件为各项的控制台输出与结果记录。全部退出码为 0。
