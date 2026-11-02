# vivado_batch_exit：Windows 下 Vivado 批处理的真实退出码

类型：踩坑清单 + 脚本模板。

## 适用场景

在 Windows 上用 PowerShell 或 Python 驱动 Vivado/xsim 批处理（综合、IP 生成、仿真），需要"跑没跑成功"有可靠依据的任何题目。与本项目的 OFDM 设计无关。

## 现象与来源

| 现象 | 本项目中的实际记录 |
|---|---|
| `vivado -version` 打印出正确版本号，但进程返回 1 | `evidence/reproduction/status_cdc01_version.log`、`status_cdc01_stages.json`：版本阶段 exit 1，后续编译没有开始 |
| PowerShell 脚本成功跑完，但没有显式 `exit`，调用方读到的 `$LASTEXITCODE` 是空值而不是 0 | 板上证据 BRINGUP-024 `result.json` 的 `upload_receipt_note` |
| 日志中出现 PASS 字样，但进程实际以非零码退出（或者反过来） | `platform_outputs01` 两次运行：Tcl 打印了大量正常信息，最终 `exit 1` |
| 用 `powershell -File x.ps1 -TclArgs 'a','b'` 调用时，数组被合并成一个字符串 `a,b`，Tcl 只收到 1 个参数 | `build/submission_repro_20261024/core_synth01`：脚本按参数个数检查后拒绝执行，exit 1，耗时 8.7 s；改用 `powershell -Command "& x.ps1 -TclArgs @('a','b')"` |
| `vivado.bat` 外面又包了一层 `cmd`，内层 `vivado.exe` 的码可能被覆盖 | 各运行入口改为记录 `cmd /c` 的返回码，并与 Tcl 内部写出的结果文件同时检查 |

## 用法

1. 版本检查不用 `vivado -version`，改用一个只核对版本并显式 `exit 0/1` 的 Tcl（见 `check_tool_version.tcl`）。
2. 所有 Tcl 入口都以 `if {[catch {main} msg opts]} {puts stderr ...; exit 1}; exit 0` 结尾，不依赖隐式退出。
3. 调用方同时检查两样东西：进程返回码，以及 Tcl 在最后一步才写出的结果文件（例如 `native_result.json`）。缺任何一样都判失败。
4. PowerShell 脚本最后一行写 `exit $exitCode`；在 `finally` 中写出 `exit.json`（返回码、耗时、内存峰值），失败时也要写。
5. 失败的运行目录保留不删；修复后在新目录重跑，并在报告中写明前一次为什么失败。

模板：`run_template.ps1`（从本项目 `build/run_platform_outputs.ps1` 精简而来）。

## 已验证效果

- `status_cdc01` 的问题被准确定位为"版本命令返回码"，没有被误判成仿真失败；改用 `check_tool_version.tcl` 后，`status_cdc02` 的各阶段返回码均为 0，总耗时 233.2 s，见 `report/reproduction_20261024.md`。
- `platform_outputs01` 的两次失败都由返回码 1 加缺失的结果文件确认，没有被日志中的正常信息掩盖。

## 失效条件与边界

- 只在 Windows 11、Vivado 2023.2 上验证过。Linux 下 `vivado` 是 shell 脚本，行为可能不同，需要重新确认。
- 它只能证明"进程按脚本走完了"，不能证明设计正确。功能、时序结论仍需要检查报告内容。
- Vivado 在严重内存不足时可能被系统终止，此时同样拿不到结果文件。应在启动前检查空闲内存，而不是事后猜测原因。
