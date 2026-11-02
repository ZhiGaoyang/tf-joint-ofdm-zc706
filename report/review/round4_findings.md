> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 第四轮只读复审：M1–M3 与两条附带建议

日期：2026-10-26。依据：[本轮说明](report/review/round4_brief.md)、[实现方答复](report/review/round3_response.md)、[第三轮报告](report/review/round3_findings.md)。只审查指定修改及其直接影响，未扩展到联合策略算法、PHY 或提交包副本。

## 1. 判定

**M1、M2 及两条附带建议已解决；M3 部分解决。** 本轮只新增一项低严重度残留 P1：主流程、日志关闭和 stderr 写入连续失败时，stderr 异常仍会覆盖主异常。未发现高、中严重度问题。

| 编号 | 判定 | 依据 | 备注 |
|---|---|---|---|
| M1 备份条件链 | 已解决 | [运行手册第 57 行](docs/innovation/stage2_board_runbook.md:57)采用子 shell 内完整条件链、固定目标及变量引用。重跑五个指定场景：首次 0；重试 0 且旧备份不变；坏备份 1；cd 失败 1；mkdir 注入失败返回 8，即使父 shell 预存 S=elsewhere.py 也没有误报成功。 | 探针故意令 mkdir 返回 8，因此本轮对应 rc 为 8，不要求必须等于实现方报告中的 1；验收条件是保留真实非零错误。 |
| M2 复位说明及运行前提 | 已解决 | [B 设计第 252 行](docs/innovation/b_subcarrier_mask_design.md:252)已精确区分响应与复位同拍、无响应时复位、W1C 优先；[运行手册第 24 行](docs/innovation/stage2_board_runbook.md:24)明确单控制者、串行读取、读期间不切换 RX/软件复位/清标志、已知异常窗口作废重采及瞬态 RF 复位残余风险。 | 与第三轮有条件接受一致。没有新增硬件容错验收或实测发生率的主张。 |
| M3 main 异常处理 | 部分解决 | [lean_adapt.py:318–327](scripts/board/lean_adapt.py:318)在 stderr 正常时保留原异常；正常运行后的 close 错误仍传播。RuntimeError、KeyboardInterrupt 和 SystemExit(17) 均验证。 | stderr 已关闭或写入抛 OSError 时，新的 print 会在 bare raise 前失败，见 P1。 |
| N1 附带：安装/重启分开报告 | 已解决 | [第 46–49 行](docs/innovation/stage2_board_runbook.md:46)实际抽取命令并替换本地文件/哈希重跑；安装失败不调用模拟 reboot；安装成功但 reboot 返回 9 时仅报告 REBOOT_CMD_FAILED_INSTALL_OK，不再误报 NO_REBOOT_INSTALL_FAILED。 | `$B` 引号版本已覆盖。INSTALL_RC 与重启结果分开判断，整段最终 shell 退出码仍不代表安装成功，手册已说明。 |
| N3 附带：解冻注释 | 已解决 | [lean_nc.py:80–81](scripts/board/lean_nc.py:80)收紧为下一次 NC 运行进入窗口准备且成功写 rx_cfg(freeze=False) 后解除。对照 [run 的窗口准备](scripts/board/lean_adapt.py:413)，条件符合实际流程。 | 不再承诺任何运行一开始就无条件解冻；本项仅注释调整，不重跑上一轮完整解冻矩阵。 |

## 2. P1：stderr 写入失败再次覆盖主异常

- 严重度：低。归属：M3 修复引入的附属诊断路径缺少保护，不涉及联合调制/屏蔽决策算法。
- 位置：[lean_adapt.py:324–326](scripts/board/lean_adapt.py:324)。
- 触发：run 抛出主异常；log.close 抛出普通异常；随后 `print(..., file=sys.stderr)` 也失败。第 326 行的 bare raise 未执行。
- 实测：stderr 为已关闭的 StringIO 时，最终异常是 `ValueError('I/O operation on closed file')`；stderr.write 抛 OSError 时，最终异常是 `OSError('stderr write failed')`。两类 stderr 故障分别配合 RuntimeError、KeyboardInterrupt、SystemExit，共 6 个场景均未保留预期的顶层异常。
- 影响：原错误仍在 Python `__context__` 链中，不是彻底丢失；但 Ctrl+C 不再以原 KeyboardInterrupt 传播，SystemExit(17) 不再作为指定退出请求传播。没有把普通失败变成成功，但 CLI 错误类型和退出语义被附属日志改变。
- 对照：stderr 可写时，三类主异常保持原对象，SystemExit 的 code=17 保持；close 成功时不使用 stderr，三类主异常保持；run 成功而 close 失败时始终传播 close 的 OSError，不隐藏落盘错误。
- 最小建议：只在已有主异常的清理分支中，将 stderr 诊断也包成尽力而为的写入，捕获其普通 Exception 后仍执行外层 bare raise。不要改动成功路径的 close 错误传播，也无需调整策略、RTL 或启动 EDA。
- 对应验收：三类主异常 × stderr 正常/关闭/写失败 × close 成功/失败；另验证 run 成功时 close 成功/失败。要求主异常对象或 SystemExit code 保持，成功路径落盘失败仍报错。本轮矩阵为 24 场景、18 满足预期、6 失败，真实探针退出码 **1**。
- 证据：[probe_main.py](build/review_probes/round4_host_01/probe_main.py)、[main_results.json](build/review_probes/round4_host_01/main_results.json)、[main.log](build/review_probes/round4_host_01/main.log)、[main_exit.txt](build/review_probes/round4_host_01/main_exit.txt)。探针调用真实 main，替换 run、日志对象和 stderr，不打开板卡 Core。

## 3. 其余核查与边界

**M1 的子 shell 与上传目录。** 探针输出确认父 shell 的当前目录和原 S 保持不变，子 shell 内新赋的备份目标不会泄漏到父 shell。使用绝对目的路径 `/root/lean/lean_adapt.py`、`/root/lean/lean_nc.py` 上传足以避免依赖父 shell 目录。只读核对 [uart_push.ps1 参数](scripts/board/uart_push.ps1:4)及第 39 行发现：Dest 是必填参数且原样用于板上重定向，工具不会自动补 `/root/lean/`。

当前阶段 2 手册第 61 行只列两个文件名和工具名，没有列实际 `-Dest` 命令；阶段 0 [第 65 行](docs/innovation/stage0_board_runbook.md:65)已有绝对 Dest 的示例。因此结论是“传入上述绝对 Dest 即可”，不是“已验证阶段 2 真实上传采用了绝对路径”。建议执行时显式列出这两个 Dest；这属于操作明确性备注，不另立一个已复现的代码缺陷。本轮只读了上传工具相关几行，未执行工具或扩展为上传工具全面审计。

**ls 确认行。** [第 58 行](docs/innovation/stage2_board_runbook.md:58)使用绝对路径，位置正确；它只确认文件可列出，不证明 SHA 正确。坏备份探针得到 SCRIPT_BACKUP_RC=1、BACKUP_LS_RC=0，文件没有被覆盖。这与手册“只有 SCRIPT_BACKUP_RC=0 才允许上传”的门槛一致，不应拿最后一个 ls 成功替换 SHA 判定。探针保留两种返回码和真实 shell 总退出码；没有把 echo 导致的 shell 总退出 0 当作备份通过。

**N1 分支。** 当前引号版本覆盖首次安装、重复安装、坏暂存、坏备份、复制失败、复制假成功但目标损坏、sync 失败、reboot 失败。安装失败的各分支均不调用模拟 reboot；复制成功后仍校验目标完整 SHA，原备份未因重试被覆盖。分支内第二次 `sync; reboot` 仍是顺序执行，不把 sync 失败单独作为该分支的阻断条件；前面的安装链已经包含成功的 sync 与目标校验，这是第三轮已经说明的边界，本轮没有把它重新列为新问题。真实重启是否发生仍需启动 ID 核验，不能由 shell 回显代替。

**M2 源码对照。** [第 71 行](rtl/ofdm_nc/lean/ofdm_development_core.v:71)的 modem_arst 含 RF TX/RX 复位；[第 226 行](rtl/ofdm_nc/lean/ofdm_development_core.v:226)叠加软件复位和 RX 关闭；[第 380–385 行](rtl/ofdm_nc/lean/ofdm_development_core.v:380)在 reset 与 valid 同时为真时返回 0 而不新置 bit9；只有 reset 没有 valid 时置位并取消请求；[第 409 行](rtl/ofdm_nc/lean/ofdm_development_core.v:409)的后序 W1C 优先。文档的第一条应结合第二条阅读：原 bit9 保持也受同拍 W1C 的覆盖，不是忽略 W1C 的绝对保证。现说明已把两条放在一起，未发现新的语义冲突。

运行手册把已知复位、RF/JESD 重新初始化与守卫中止窗口作废重采，并明确未观测瞬态复位仍有风险，符合上一轮受控实验边界。这个约定没有新增自动复位检测机制；硬件任意复位碰撞检测和无人值守恢复仍不在已接受范围。

**新增测试自身的 warning。** 受影响两文件测试共 32 项通过，但有 2 个 PytestUnraisableExceptionWarning，来自新增 CloseFails 假日志对象在析构时再次调用故意抛错的 close。不是板上异常，也不改变本次 pytest 退出 0 的事实；应保留 warning，避免宣称“零警告”。若后续清理测试，可保留假对象引用并用基类 StringIO.close 收尾；不必因此扩展回归。本轮独立探针已如此处理假对象。

## 4. 证据与未覆盖范围

- 针对性测试：[pytest.log](build/review_probes/round4_host_01/pytest.log)，**32 passed, 2 warnings in 0.23s**，实际退出 0。命令为 `python -B -m pytest -q -p no:cacheprovider --basetemp=build/review_probes/round4_host_01/tmp tests/bringup/test_lean_adapt_nc.py tests/bringup/test_lean_nc.py`，工作目录 `D:/FPGA_COMPETITION`，PYTHONDONTWRITEBYTECODE=1。
- Shell：[probe_shell.py](build/review_probes/round4_host_01/probe_shell.py)、[shell_results.json](build/review_probes/round4_host_01/shell_results.json)、[shell.log](build/review_probes/round4_host_01/shell.log)。复用上一轮探针结构，提取本轮实际命令，14 场景检查通过，父进程退出 0；各假安装/备份故障自己的非零 rc 保留。全部文件为新目录中的假数据，sync/reboot 均为本地函数，没有执行真实系统重启。
- CLI 异常矩阵：24 场景中 6 个失败，父进程退出 1，未把失败改成通过。完整结果见第 2 节。现有两个实现方测试只覆盖 stderr 可写条件，所以它们通过与本轮新增失败不矛盾。
- 本轮 brief 的 6 个文件前缀匹配；完整 SHA 绑定见 [source_pins.json](build/review_probes/round4_host_01/source_pins.json)，复核未变见 [source_unchanged.json](build/review_probes/round4_host_01/source_unchanged.json)。相关 4 个 RTL 与第三轮绑定一致：[rtl_reuse.json](build/review_probes/round4_host_01/rtl_reuse.json)。未重跑未变算法/RTL 的既有结果。
- 未覆盖：板上 Python 3.9 运行、真实 Linux/SD 错误和掉电、真实 UART 上传/重启、实际 RF 复位发生率、MMIO 硬件排序、提交包副本、EDA、bitstream/BOOT 重生成与板上验证。本机测试使用 Python 3.13，未声称已经在板上复现 stderr 故障。
- 写入仅为本报告及 `build/review_probes/round4_host_01`。生产源码、原测试、运行手册、RTL、既有证据和启动材料保持原样。
