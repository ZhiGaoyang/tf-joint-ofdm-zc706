> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 第三轮只读复审：N1–N4

日期：2026-10-26。依据：[第三轮说明](report/review/round3_brief.md)及[实现方答复](report/review/round2_response.md)。范围仅为 N1–N4 修改、直接相关的异常边界及两个 RTL 优先级窗口的保留决定；提交包副本不在范围内。

## 1. 结论与逐项判定

本轮未发现高或中严重度的新问题。确认原安装失败重启、备份正常路径、三类异常覆盖和寄存器表问题均有实质修复。剩余三个低严重度发现列于下节，其中 M3 是既有调用层残留，并非本轮新增回归。

**可保留当前 RTL 用于受控实验，但属于带边界接受，不是复位故障容错通过。** 不建议仅为这两个窗口立即重开综合和实现；依据是当前串行软件流程与可限定的使用边界，而非“概率很小”或“时序余量小所以忽略正确性”。详见第 3 节。

| 编号 | 判定 | 依据 | 备注 |
|---|---|---|---|
| N1 | 已解决 | [运行手册第 45–47 行](docs/innovation/stage2_board_runbook.md:45)在复制、sync、目标完整 SHA 校验后保存安装 rc，并据其决定是否重启。替换为本地假文件后实测首次安装、重装，以及坏暂存、坏备份、复制失败、复制返回成功但内容损坏、sync 失败。所有安装失败场景均未调用模拟 reboot。 | reboot 自身失败会打印不准确的 NO_REBOOT_INSTALL_FAILED；已复现。这是诊断歧义，未重新打开“安装失败仍重启”缺陷。 |
| N2 | 部分解决 | [第 55 行](docs/innovation/stage2_board_runbook.md:55)正常路径已建目录、仅首次创建备份、复用时验证完整 SHA。首次、重试、坏备份场景均符合预期，重试未覆盖旧脚本。 | 前置 cd/mkdir 失败仍可能得到 SCRIPT_BACKUP_RC=0，见 M1。上传是手册中的下一人工步骤，不是同一命令块中的自动受控操作。 |
| N3 | 已解决，限定原三处机制 | [run 异常与清理段](scripts/board/lean_adapt.py:458)和 [frozen_metrics](scripts/board/lean_nc.py:75)保留主异常；三个新增测试通过，独立注入也确认诊断失败、清理日志失败、超时后解冻失败均保留预期主错误。主流程正常而清理失败仍抛出错误。 | “下一次运行一定解冻”不是准确保证，见第 3 节。调用方 main 的 close 仍有残留异常覆盖，见 M3；不将其描述为本轮新引入。 |
| N4 | 部分解决 | [寄存器表第 238、241 行](docs/innovation/b_subcarrier_mask_design.md:238)已正确写入 bit9、384 字/约 385 拍、三个已实现库、0x00003000 及保留位；与当前 RTL 一致。 | 新增限制说明中的第一种触发条件过宽，见 M2。保留 RTL 的决定与文档精度分开评价。 |

## 2. 新发现及残留边界

### M1：脚本备份的目录准备失败未纳入最终成功判据

- 严重度：低；归属：N2 修复块的残留边界。
- 位置：[stage2_board_runbook.md:55](docs/innovation/stage2_board_runbook.md:55)。
- 触发：`cd /root/lean` 失败后，分号使后续命令继续；或 mkdir 失败时 `S` 没有重新赋值，后续使用当前 shell 中已有的 S。
- 实测一：模拟目标目录不存在，但当前目录有期望 SHA 的旧脚本，命令仍打印 SCRIPT_BACKUP_RC=0，备份实际建立在错误目录。
- 实测二：mkdir 返回 8，shell 预存 `S=elsewhere.py` 且该文件 SHA 正确，仍打印 SCRIPT_BACKUP_RC=0；指定备份目录及文件均未建立。
- 影响：操作员仅按手册要求检查 SCRIPT_BACKUP_RC 时，可能误认为指定位置的回滚脚本已准备好。正常目录准备和重试路径未发现破坏旧备份的问题。
- 最小建议：使用一个受控子 shell 或完整条件链，将 cd、mkdir、固定目标赋值、首次复制和 SHA 校验纳入同一返回值；引用变量；只在这个整体返回 0 后允许上传。无需修改任何 RTL。
- 证据：[shell_results.json](build/review_probes/round3_host_02/shell_results.json)中的 `script_cd_fail`、`script_mkdir_fail_stale_S`；对应目录保存从当前手册提取并替换路径/哈希后的实际 shell 脚本与 stdout/stderr。不是只靠人工推断。

### M2：新增说明把“响应有效与复位同拍”泛化成了所有等待读期间复位

- 严重度：低；归属：N4 新增说明的准确性。
- 位置：[b_subcarrier_mask_design.md:252](docs/innovation/b_subcarrier_mask_design.md:252)；对照 [ofdm_development_core.v:380–385](rtl/ofdm_nc/lean/ofdm_development_core.v:380)。
- 事实：`rx_core_arst=1` 且 `m_rd_valid=0` 时，代码会返回 0，并执行 cancel 与超时标志置位。真正漏置位窗口是 r_wait 中 **rx_core_arst 与 m_rd_valid 同拍有效**：数据被复位条件改为 0，但 `if (!m_rd_valid)` 不成立。如果 bit9 原来已置位，它仍保持原值；另有 W1C 同拍时还应考虑清除优先。
- 影响：现说明会误导复位测试预期，也容易让“PS 只在 RX 运行时读取”被误解为已经排除此窗口。RF 复位源仍可异步到来，见第 3 节。
- 最小建议：只修正文档为精确的同时有效条件，并区分已确认的 RTL 语义与尚未测量的硬件发生率。不要求因此修改 RTL。
- 证据：上述当前源码直接判读；对应四个 RTL 与上一轮绑定版本完全一致。本轮未启动 RTL 仿真，不把此判读写成新的仿真通过。

### M3：CLI 最外层关闭日志失败仍会成为最终异常

- 严重度：低；归属：N3 的既有调用层残留，不是新修复引入。
- 位置：[lean_adapt.py:316–320](scripts/board/lean_adapt.py:316)。
- 触发：run 已抛出主异常，main 的 finally 无条件调用 `log.close()`；close 在刷新缓冲时也抛出 I/O 错误。
- 实测：模拟 run 抛出 `RuntimeError('primary run failure')`、close 抛出 `OSError('close flush failed')`，最终抛出的是 OSError；RuntimeError 保留在 `__context__`。因此没有丢失 Python 异常链，也没有变成成功退出，但“主异常总是最终传播”的承诺仍未覆盖 CLI 整体。
- 最小建议：正常完成时仍传播 close 错误；已有主异常时将 close 失败作为附加诊断，保留主异常。不要用无条件吞掉 close 错误的方式把成功路径的落盘失败隐藏。
- 证据：[ps_results.json](build/review_probes/round3_host_02/ps_results.json)的 `main_close_failure`。该探针只替换 run 和日志对象，不构造真实 Core，不访问板卡。

## 3. 专项问题与可接受边界

**N1：重启表达式与回滚。** `[ "$rc" -eq 0 ] && { sync; reboot; } || echo ...` 中，reboot 非 0 的确会误报为安装失败。本地注入结果为 INSTALL_RC=0、MOCK_REBOOT_FAILED、NO_REBOOT_INSTALL_FAILED。这个提示不够准确，建议以后用明确的 if 分支分别记录安装与重启失败；当前人工操作时应以保存的 INSTALL_RC 和启动 ID 核验区分，不用整段 shell 的最终退出码判安装成功。末尾 echo 会使多个失败探针的 shell 退出码为 0，本报告保留这些真实退出码，依据内部 rc、模拟调用和文件内容判断行为。

安装块内已有复制后的 sync 和目标 SHA 校验；第二次 sync 处于 `{ sync; reboot; }` 分号顺序中，不单独阻断 reboot。当前已验证镜像且之后无新写入的流程中，未据此发现新的内容完整性缺口；若将此块改作自动部署工具，应采用每步明确退出码的结构。

当前回滚指引实际写的是“**若 /boot/BOOT.BIN 可能已被部分写入**”，不是任何校验失败都无条件回滚。坏暂存或坏备份在复制前被挡住时，活动 BOOT 未被修改，没有必要为此强制恢复并重启。复制失败或写后校验失败时才需要恢复已验证的备份。回滚块本身仍是既有流程，本轮没有执行真实回滚或扩展审查其所有故障模式。

**N3：吞掉附属日志异常是否合理。** 当前改法是合理的异常优先级：外层捕获 BaseException 后会重新抛出主异常，内层只捕获 Exception；不是把主错误吞掉。独立探针对 RuntimeError、KeyboardInterrupt、SystemExit 主异常配合诊断/失败日志错误，确认原异常对象保持；普通 window/summary 写日志失败仍导致运行失败；无主异常而恢复及清理日志失败时仍抛 RuntimeError。故未发现该修改把真实失败转换成成功。二次 KeyboardInterrupt/SystemExit、进程强杀、机器掉电不属于“附属异常永不替换主异常”的保证。

**N3：解冻恢复是有条件的。** 当前流程在 NC 窗口开始时执行 `set_tx_mask → rx_cfg(freeze=False) → clear_metrics → window`。它不是函数入口处无条件解冻。

- 超时并解冻写失败：原超时异常保留，RX_CFG 可留在 0x07000000；该次运行失败，不发布这一组度量供策略决策。
- 随后普通非 NC 运行：没有 NC 寄存器写入，冻结仍保留。实测模拟窗口可完成，这不意味着度量已恢复；非 NC 策略本来也不读取这些库。
- 随后 NC 运行且到达首个窗口准备步骤：发起窗口前写成 0x03000000，已确认恢复次序。
- 如果下一次 NC 运行在版本预检、日志、衰减配置或 MMIO 等前置步骤失败，就尚未解冻；独立探针复现衰减回读不匹配时仍保持冻结且未调用 window。若解冻写继续失败，同样不应宣称恢复。
- 建议把 [lean_nc.py:80–81](scripts/board/lean_nc.py:80)的“every run start”说明收紧为“下一次成功进入 NC 窗口准备并成功写 rx_cfg 时解除”。保留失败、不继续使用旧度量的现状可接受，不需要为了普通非 NC 运行而强行新增寄存器写入。

**RTL 窗口一：复位与度量响应同拍。** 条件及具体错误见 M2。在该边沿，真实读数可能被替换成 0 而 bit9 不新置位；这影响度量有效性，不能把这一数值当正常低误差样本。单控制者且软件不在度量读取期间复位/关 RX，可以避免软件自身制造这个窗口，但不覆盖全部复位来源：[modem_arst](rtl/ofdm_nc/lean/ofdm_development_core.v:71)包含 rf_tx_arst、rf_rx_arst，[rx_path_arst](rtl/ofdm_nc/lean/ofdm_development_core.v:226)再叠加软件复位和 RX 关闭。因此“RX 正在运行”不是排除此窗口的充分证明。本轮没有证明现有 PS 脚本能检测每一次瞬态 RF 复位。

**RTL 窗口二：置位和 W1C 同拍。** [超时/取消置位](rtl/ofdm_nc/lean/ofdm_development_core.v:385)与后面的 [W1C](rtl/ofdm_nc/lean/ofdm_development_core.v:409)同一 always 块更新同一寄存器，后者优先。当前 NC 软件顺序是窗口开始时清除，窗口结束时冻结读取所有度量并检查标志；本进程没有在度量读取中途发清除。单控制者、串行 MMIO 完成且没有并行读写者时，保留此优先级可接受。若未来添加异步读取/后台维护/多进程控制，就需重新评估，不能继续沿用本轮的串行假设。

**保留决定：有条件接受。** 当前阶段不强制改 RTL、不因此重开 EDA。实验前提应明确为单控制者、读度量期间不切换 RX/复位、不并发清除标志；已知发生复位或 RF/JESD 重初始化的窗口必须作废并重新初始化/采集。对未观测到的瞬态 RF 复位仍有残余风险，不能宣称自动故障检测已经闭合。若交付验收要求“任意复位碰撞都被硬件标记”或无人值守故障恢复，这个保留决定就不适用，应专门修复并做有边界的验证。+0.029 ns 是实现成本背景，不是忽略错误的技术依据；该时序数字本轮仅引用实现方材料，未重测。

## 4. 证据、未发现问题与未覆盖范围

- 受影响测试：[pytest.log](build/review_probes/round3_host_01/pytest.log)，`test_lean_adapt_nc.py` 和 `test_lean_nc.py` 共 **30 passed in 0.21s**，实际退出码 0。包含实现方新增的三个 N3 测试。本轮没有为脚本修改重跑全 PHY 或全项目验收。
- 命令：`python -B -m pytest -q -p no:cacheprovider --basetemp=build/review_probes/round3_host_01/tmp tests/bringup/test_lean_adapt_nc.py tests/bringup/test_lean_nc.py`，工作目录为 `D:/FPGA_COMPETITION`，设置 PYTHONDONTWRITEBYTECODE=1。
- 独立 Shell 探针：[probe_shell.py](build/review_probes/round3_host_02/probe_shell.py)、[结果](build/review_probes/round3_host_02/shell_results.json)。14 场景检查完成，探针父进程退出 0；其中故意制造的失败与假成功均保留真实输出，不把父进程 0 解释为所有生产操作成功。原命令从本轮手册提取，仅替换本地路径与假文件 SHA；所有 sync/reboot 都被本地函数替代，未触及真实系统重启。
- 独立 Python 探针：[probe_ps.py](build/review_probes/round3_host_02/probe_ps.py)、[结果](build/review_probes/round3_host_02/ps_results.json)。12 个结果场景完成，父进程退出 0；覆盖主异常保持、成功路径清理失败、日志错误、冻结恢复和 main.close 残留。真实板卡 Core/测量/IIO 被假对象替换；假测量数值不是 RF 或吞吐证据。
- 探针历史：首个 Shell 探针因 Windows 路径键使用反斜杠导致 KeyError，真实退出 1，保留于 [round3_host_01/shell.log](build/review_probes/round3_host_01/shell.log)。修正探针路径键为 as_posix 后在新目录重跑。首个 PS 探针完成并退出 0，但故意损坏的 CloseFails 对象在析构时再次输出异常；第二版显式调用基类 close 释放假对象，保持被测异常机制原样。未把探针自身问题归到项目源码。
- 已复核且未见对应缺陷：正常备份重试不覆盖；坏备份不被接受；安装后实际内容受 SHA 校验；错误安装不重启；原 N3 三处主异常保持；clear 长度、已实现库、NC_RX_LAST 复位/保留位与当前源码对应。
- 本轮 brief 指定的 7 个文件 SHA 前缀均匹配，前后全 SHA 一致：[source_pins.json](build/review_probes/round3_host_01/source_pins.json)、[source_unchanged.json](build/review_probes/round3_host_02/source_unchanged.json)。与本轮相关的 4 个 RTL 全 SHA 与上一轮一致：[rtl_reuse.json](build/review_probes/round3_host_02/rtl_reuse.json)。复用上轮结果，不重开仿真。
- 未覆盖：真实 Linux/SD 文件系统故障与掉电、真实串口部署、板上 MMIO 排序、RF 复位碰撞频率、提交包副本、全项目回归、bitstream/BOOT 重建及真实布局布线。本轮没有修改生产源码/测试/手册、没有操作板卡，没有启动 xsim/Vivado。
- 唯一写入范围：本报告及 `build/review_probes/round3_host_01`、`build/review_probes/round3_host_02` 新探针目录。原失败记录与既有产物保持原样。
