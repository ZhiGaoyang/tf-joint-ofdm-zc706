# 仿真与验证

本目录是一个自包含的验证工程：Python 黄金模型、向量生成与日志检查器、SystemVerilog 测试台、xsim 运行脚本、主机测试与联合决策参考实现。被测 RTL 在 `../src/rtl/ofdm`，FFT/IFFT 行为模型放在 `../src/ip/sim`（见 `../src/ip/README.md`）。以下命令均在本目录（`sim/`）下执行。

| 目录 | 内容 |
|---|---|
| `models/` | 浮点参考模型：`ofdm/`（帧编解码、同步、均衡）、`ofdm_nc/`（子载波组屏蔽帧） |
| `scripts/model/` | RX 向量生成（`nc_rxs_vectors.py`、`rxs_vectors.py`）、RX 日志检查器 `nc_rxs_check.py`、同步方案扫描 `m0_sync_sweep.py` |
| `scripts/rtl/` | xsim 运行脚本 `run_nc_*.ps1`、TX 网格与度量模块向量生成、映射头文件生成 `gen_nc_map.py` |
| `scripts/analysis/` | 屏蔽帧检测定时偏差的模型复现（`timing_by_mask.py`、`timing_cause.py`） |
| `tests/rtl/ofdm_nc/` | 测试台：TX 帧网格、逐载波度量、RX 核心、TX→RX 环回、开发核心整体 |
| `tests/bringup/`、`tests/ofdm_nc/` | 板上 PS 脚本（使用模拟寄存器）、模型与检查器的主机测试 |
| `reference/` | 联合决策的主机参考实现（`innovation_joint/`）与标定表（`innovation_a/`） |
| `results/` | 已有仿真结果：`final_rxs02`（RX 核心 11 个场景）、`final_loop02`（TX→RX 环回 6 个场景）、`final_lean02`（开发核心）、`grid_nc01`（TX 帧网格 154 用例）、`cmetric04`/`cancel_green01`（度量模块）；名称含 `red` 的目录与 `rxs_run02`、`loop_run02` 为修复前的失败记录，原样保留；`repo_layout_check_20261102` 为在本仓库目录结构下重新运行下列命令的记录 |

## 主机测试（不需要 EDA）

```powershell
python -B -m pytest -q
python -B reference/innovation_joint/test_joint_policy.py
python -I -B scripts/rtl/gen_nc_map.py --check
```

## RTL 仿真（Vivado 2023.2 xsim）

```powershell
$vh = 'D:\Xilinx\Vivado\2023.2'                       # 按本机修改
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtl/run_nc_grid_sim.ps1 -Work work/nc_grid -VivadoHome $vh
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtl/run_nc_unit_sims.ps1 -Work work/nc_unit -VivadoHome $vh
$env:PYTHONPATH = (Get-Location).Path
python -m scripts.model.nc_rxs_vectors --output work/nc_rxs_vec
python -m scripts.model.rxs_vectors --output work/rxs_vec_v02
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'scripts/rtl/run_nc_rxs_sim.ps1' -Work 'work/nc_rxs' -Vectors @('work/nc_rxs_vec','work/rxs_vec_v02') -Backoff 16 -VivadoHome '$vh'; exit `$LASTEXITCODE"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'scripts/rtl/run_nc_txrx_sim.ps1' -Work 'work/nc_loop' -Cases @('3,256,0,2,128,7,16,0,0') -VivadoHome '$vh'; exit `$LASTEXITCODE"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtl/run_nc_lean_sim.ps1 -Work work/nc_lean -VivadoHome $vh
```

每个脚本要求 `-Work` 目录不存在，只有全部场景通过时退出码为 0。RX 核心全部场景约 30 分钟（`-Scenarios` 可选部分场景），开发核心约 13 分钟。
