# 构建脚本与综合实现报告

## 脚本

| 文件 | 作用 |
|---|---|
| `core_synth.tcl` | OFDM 核心 OOC 综合（读 `src/rtl/ofdm` 与 `src/ip` 的网表），输出 `core.edf` 与报告 |
| `platform.tcl` | 把核心网表插入平台壳，布局布线，输出报告与比特流 |
| `stage_platform_inputs.py`、`run_platform_bd.ps1`、`validate_platform_bd.tcl` | 暂存平台输入，在新工程中建立并验证 Block Design |
| `run_platform_outputs.ps1`、`generate_platform_outputs.tcl`、`compare_bd_state.py` | 生成全部 IP 输出、wrapper 与编译顺序，并用落盘的 BD/XCI 文件核对配置 |
| `prepare_adi_library.py`、`package_adi_library.tcl` | 从固定提交的 ADI HDL 源码导出并打包所需 IP 库 |
| `synth_platform_shell.tcl` | 平台壳综合（OFDM 核心为黑盒） |
| `check_tool_version.tcl` | Vivado 版本检查 |
| `compare_rebuild.py` | 把重建结果与赛方工程包中的板上镜像结果逐项比对（含比特流配置数据） |

## 运行（PowerShell，于仓库根目录）

需要 `src/ip/README.md` 所列的 FFT/IFFT 网表，以及一个平台壳检查点 `system_top_shell.dcp`：可按第 1–4 步从 ADI 官方源码重建，也可直接使用随赛方 Vivado 工程包提供的版本（跳到第 5 步）。

```powershell
$root   = (Get-Location).Path
$vivado = 'D:\Xilinx\Vivado\2023.2\bin\vivado.bat'      # 按本机修改
$work   = 'D:\work_ofdm'                                 # 无空格、不存在的目录
git clone https://github.com/analogdevicesinc/hdl D:\adi_hdl
git -C D:\adi_hdl checkout 2156ac7e874a1dc321d9f64a325009fafe563419
```

| 步 | 内容 | 命令 |
|---|---|---|
| 1 | 从固定提交导出并打包 ADI 库 | 见 `src/platform/README.md` 的 "Clean ADI Library Recipe"（输出 `$work/adi_library01`） |
| 2 | 暂存平台输入，建立并验证 BD | `python -B build/stage_platform_inputs.py --root "$root/src" --out "$work/platform_inputs01"`；`build/run_platform_bd.ps1 -VivadoHome <Vivado 目录> -AdiRoot D:\adi_hdl -AdiLibrary "$work/adi_library01/source/library" -Staged "$work/platform_inputs01" -Work "$work/platform_bd01"` |
| 3 | 生成 IP 输出与 wrapper，核对落盘配置 | `build/run_platform_outputs.ps1 -VivadoHome <Vivado 目录> -BdProject "$work/platform_bd01/project" -AdiLibrary "$work/adi_library01/source/library" -Work "$work/platform_outputs01"`（`compare_bd_state.py` 判定 PASS 才算通过） |
| 4 | 平台壳综合（约 48 分钟） | `& $vivado -mode batch -source "$root/build/synth_platform_shell.tcl" -tclargs "$work/platform_outputs01/project/submission_platform.xpr" "$work/adi_library01/source/library" "$work/shell" 2` |
| 5 | OFDM 核心 OOC 综合（约 3 分钟） | `& $vivado -mode batch -source "$root/build/core_synth.tcl" -tclargs $root "$work/core"` |
| 6 | 插入核心、布局布线、比特流（约 13 分钟） | `& $vivado -mode batch -source "$root/build/platform.tcl" -tclargs "$work/core" "$work/impl" 4 "$work/shell/system_top_shell.dcp" D:\Xilinx\Vivado\2023.2` |

第 4 步产生的 `submission_platform.xpr` 是平台 Block Design 的 Vivado 工程，可在 GUI 中查看。脚本无论时序如何都会写出比特流，使用前先确认 `routed_timing.rpt` 中负裕量为 0。

## 报告（`reports/`）

| 目录 | 内容 |
|---|---|
| `core_synth/` | 核心 OOC 综合：20,641 LUT、20,089 FF、14 BRAM、63 DSP |
| `platform_impl/` | 整平台布局布线：WNS +0.029 ns、WHS +0.035 ns、WPWS +0.062 ns，TNS 0；72,729 LUT（33.3%）、89,716 FF、67 BRAM、176 DSP；DRC、CDC、布线状态、各阶段 WNS/WHS（`summary.tsv`） |
| `rebuild_verification_20261102/` | 把赛方 Vivado 工程包解压到新目录后，仅用包内文件重建核心与整平台的日志和报告；`compare_result.txt` 显示时序、资源、布线状态与板上镜像一致，比特流配置数据逐字节相同 |
| `repo_layout_core_synth_20261102/` | 在本仓库目录结构下运行 `core_synth.tcl` 的结果，与 `core_synth/` 一致 |

报告与日志中的构建主机名已替换为 `build-host`。
