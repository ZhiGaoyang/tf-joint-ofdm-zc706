> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 复审说明：F1–F11 修复是否到位

日期：2026-10-26。请求方：项目团队。实现方：Claude。
上一轮：审查说明 `report/review/round1_brief.md`，审查报告 `report/review/round1_findings.md`，实现方答复 `report/review/round1_response.md`（必读，含每项的复现、修复与证据目录）。

审查方式与上一轮相同：**只读**。唯一允许写入的文件是复审结果 `report/review/round2_findings.md`；探针与日志只写到 `build/review_probes/` 下新建的 `rereview_*` 目录；一次只运行一个 Vivado/xsim 作业；不碰开发板、串口、SD。

## 1. 请回答的问题

1. **逐项判定 F1–F11**：已解决 / 部分解决 / 未解决，并给出依据。最直接的验证方式是用上一轮自己的探针对修复后的代码重跑：
   - F1：`build/review_probes/metric_timeout01` 的场景（读等待逻辑已改，核心在超时时置 `m_rd_cancel` 并置 0x054[9]，见下文文件）；实现方的定向测试为 `tests/rtl/ofdm_nc/tb_nc_cmetric_cancel.sv`（`build/ofdm_nc/cancel_red01` 为修复前逻辑 FAIL，`cancel_green01` 为修复后 PASS）。
   - F2：`build/review_probes/metric_probe01` 的场景；实现方在 `scripts/rtl/nc_cmetric_vectors.py` 中加入两组定向序列（`cmetric03_red` 修复前 FAIL，`cmetric04` 修复后 PASS）。
   - F3：0x060 位域；`build/ofdm_nc/final_lean02/lean.log` 中 `rx_last=00800080`、`00070007`。
   - F4–F7：`build/review_probes/ps_probe01`、`ps_fixed02` 的场景。
   - F8、F9：手册命令。实现方在本机实测这两组 shell 命令时被一个安全 hook 以"反向 Shell"误拦两次，未绕过，因此**没有实测**，只做了语义推导；如你的环境允许，请用假文件实测（不碰板卡）。
   - F10：`build/review_probes/rx_probe01` 的两份变异日志，修复后检查器应返回问题。
   - F11：环回测试台记分板；`build/ofdm_nc/final_loop02/*.log` 中的 `RXL_SCOREBOARD` 行。
2. **修复本身是否引入新问题**，重点：
   - F1：`rd_cancel` 与 `rd_valid`、新请求之间的时序（取消在超时的下一拍到达度量模块；新请求最早在 R 通道握手之后发出），是否仍存在旧响应被新事务接收或新请求被吞掉的窗口；RX 复位路径；超时标志的置位与清除（写 0x054 bit 9）。
   - F2：`take` 现在在 `clear` 当拍也为 0（`!clear`），是否会丢掉不该丢的输入；在途元素的写回与计数是否都被清零覆盖。
   - F3：新拼接的 32 位与 0x060 文档字段是否完全一致（复位值、candidate 0/1/2、blind_over）。
   - F4/F7：`no_viable` 规则（所有候选与当前状态预期为 0 时：QPSK，取帧长允许的最大"最差 k 组"掩码）是否合理，是否可能在度量恢复后卡在 `no_viable`；`link_lost` 清零掩码是否会让后续决策抖动。
   - F5：清理失败时的异常语义（主流程成功而清理失败时抛 `RuntimeError`；主流程已失败时保留原异常并写 `cleanup_failure` 记录），是否有遗漏的清理路径。
   - 板上脚本读到超时标志时报错退出（`lean_nc.read_metrics`），在 `lean_adapt.run` 中是否会被正确记为 failure 并执行清理。
3. **复审时发现的其他问题**（如有），同样分高/中/低。

## 2. 改动记录

每处修改都由下列脚本以"原文 → 新文"的精确替换完成（每段原文必须恰好出现一次），可直接阅读脚本核对改了什么：

| 脚本 | 涉及 |
|---|---|
| `build/stage1_nc/fix_review_rtl.py` | F1/F2/F3：`ofdm_rxs_cmetric.v`、`ofdm_rxs_decode.v`、`ofdm_rxs_core.v`、`ofdm_development_core.v` |
| `build/stage1_nc/fix_review_ps.py` | F4–F7、日志口径、参考实现 inf：`lean_nc.py`、`joint_policy.py`、`lean_adapt.py` |
| `build/stage1_nc/fix_review_docs.py` | F8/F9：两份运行手册；设计 §3.3；BRINGUP-025 补注 |
| `build/stage1_nc/update_docs_after_review.py` | 新镜像与脚本 SHA 同步到手册、阶段 1 报告第 7 节、答复文档、设计报告源文件 |

另有少量直接编辑（未经上述脚本）：`scripts/model/nc_rxs_check.py`（F10，`complete()` 与重复检查）、`tests/rtl/ofdm_nc/tb_nc_txrx_loop.sv`（F11 记分板）、`scripts/rtl/nc_cmetric_vectors.py`（F2 定向序列，随机清零限制在 26000 周期之前）、`tests/rtl/ofdm_nc/tb_nc_lean_core.sv`（F1/F3 检查与突发中改写 0x048）、`scripts/board/lean_nc.py`（超时标志检查、清零时写 0x201）、`tests/rtl/ofdm_nc/tb_nc_cmetric.sv`（接 `rd_cancel(1'b0)`），以及各测试文件中新增的用例；测试假寄存器把 0x054 视为命令寄存器（写入不回读）。

## 3. 复审对象（当前 SHA256 前 16 位）

| 文件 | SHA |
|---|---|
| `rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v` | `96347291bd9d17a9` |
| `rtl/ofdm_nc/rxs/ofdm_rxs_decode.v` | `8403d1d3e0b30b28` |
| `rtl/ofdm_nc/rxs/ofdm_rxs_core.v` | `44e4b6dcf8a716e1` |
| `rtl/ofdm_nc/lean/ofdm_development_core.v` | `d5ba9310f402d9f1` |
| `scripts/board/lean_nc.py` | `3ff86a33e816f2b2` |
| `scripts/board/lean_adapt.py` | `1c7ec81e5876b15e` |
| `build/innovation_joint/joint_policy.py` | `103349f020437210` |
| `scripts/model/nc_rxs_check.py` | `79cd9545a3fa0391` |
| `scripts/rtl/nc_cmetric_vectors.py` | `047d32f4eca30711` |
| `tests/rtl/ofdm_nc/tb_nc_txrx_loop.sv` | `72e2897d38506c08` |
| `tests/rtl/ofdm_nc/tb_nc_lean_core.sv` | `533725dc9479ebe8` |
| `tests/rtl/ofdm_nc/tb_nc_cmetric_cancel.sv` | `479d35928a92d767` |
| `tests/rtl/ofdm_nc/tb_nc_cmetric.sv` | `5cc8b2cf2c38e559` |
| `docs/innovation/stage2_board_runbook.md` | `8b63eea45f264151` |
| `docs/innovation/stage0_board_runbook.md` | `61e0a19be1e92ed0` |
| `docs/innovation/joint_adaptation_design.md` | `87a5be8291418828` |
| `tests/ofdm_nc/test_nc_rxs_check.py` | `e96c91f7f47fa647` |
| `tests/bringup/test_lean_nc.py` | `ebfe8893d28dac71` |
| `tests/bringup/test_lean_adapt_nc.py` | `4cc2982728e640f5` |
| `build/innovation_joint/test_joint_policy.py` | `dc9e4f3f6f89c23e` |

## 4. 实现方已有的验证（供核对，不必全部重跑）

- 主机：`python -B -m pytest -q -p no:cacheprovider tests/ofdm_nc tests/bringup`（134 通过）；`python -B build/innovation_joint/test_joint_policy.py`（21 通过）。
- 仿真（最终源码，运行前后源文件哈希复核未变）：`build/ofdm_nc/final_rxs02`（RX 11/11）、`final_loop02`（环回 6/6）、`final_lean02`（开发核心 LEAN_PASS）；`cmetric04`、`cancel_green01`。各 15–20 分钟，如需重跑请用新目录并逐个运行。
- 实现：`build/ofdm_nc/core_synth03`、`build/ofdm_nc/platform_impl02`（WNS +0.029 ns、WHS +0.035 ns，全部约束满足；CDC 与复现版逐行相同；DRC 新出现 2 条 PDRC-61）。新开发 BOOT `build/devboot/dev_nc_20261026/BOOT.BIN`，未上板。
- 根目录全量 pytest：失败加错误 33 项，与基线数量相同；其中 1 项换成了另一个测试，原因是已知的 tkinter 偶发找不到 `init.tcl`（该测试单独运行通过）。

## 5. 输出格式

写入 `report/review/round2_findings.md`：

1. F1–F11 判定表：编号 / 判定（已解决、部分解决、未解决）/ 依据（重跑的探针或代码位置）/ 备注。
2. 新发现（如有）：编号 N1、N2…，字段同上一轮（严重程度、文件:行号、问题、触发条件、依据、建议）。
3. 审查过但未发现问题的部分；没有审查到的部分。
