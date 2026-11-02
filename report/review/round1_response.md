> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 对 独立审查者 只读审查的逐条答复

日期：2026-10-26。审查报告：`report/review/round1_findings.md`。实现方：Claude。
处理原则：每项先复现（定向仿真、主机测试或明确的代码推理），再写出失败的测试，修复后转绿；失败记录保留。11 项全部确认成立，没有异议项。

| 编号 | 结论 | 复现 / 失败测试 | 修复 | 验证 |
|---|---|---|---|---|
| F1 读超时后旧响应错配 | 成立 | `tests/rtl/ofdm_nc/tb_nc_cmetric_cancel.sv` 在修复前逻辑上：第二次读（PAY[3]，应为 0）拿到第一次读 HDR[0] 的 65533，`build/ofdm_nc/cancel_red01` | cmetric 新增 `rd_cancel`；核心超时时取消底层请求，并置粘滞标志 0x054[9]；PS `read_metrics` 见标志即报错，`clear_metrics` 同时清标志 | `cancel_green01` PASS；核心仿真检查标志为 0 |
| F2 清零与计数同拍 | 成立 | 向量生成器加入定向序列（符号末元素后两拍清零），修复前 `cmetric03_red`：载荷符号计数 22，应为 20 | 清零开始拍起不再接收输入、不更新计数 | `cmetric04` PASS（同一组向量） |
| F3 NC_RX_LAST 位域错位 | 成立 | 代码拼接 31 位；`final_rxs01/nc_switch.log` 中 src/blind 显示错位 | 补齐保留位 [11] | 核心仿真检查完整 32 位（0x00800080、0x00070007） |
| F4 断链回退帧长不合法 | 成立 | `tests/bringup/test_lean_nc.py::test_outage_never_returns_an_illegal_length_combination` 及参考实现对应测试 | 断链时掩码在 QPSK 下装不下帧长就清零 | 测试通过 |
| F5 清理遗漏 | 成立 | `test_cleanup_steps_are_independent_and_the_window_error_propagates`（衰减恢复失败时掩码仍为 128） | 各清理步骤独立执行；原始异常优先；清理失败写 `cleanup_failure` 记录 | 测试通过 |
| F6 joint 与 --fixed 冲突 | 成立 | `test_joint_with_fixed_modulation_is_rejected_before_board_access` | 参数解析阶段报错 | 测试通过 |
| F7 全零分时保持 16QAM | 成立 | `test_no_viable_candidate_falls_back_to_qpsk_with_a_legal_mask`（2048/4096 B）及参考实现测试 | 全部候选与当前状态预期为 0 时：QPSK，取帧长允许的最大"最差 k 组"掩码，原因 `no_viable`；设计 §3.3 已补规则 | 测试通过 |
| F8 冒烟命令取 tail 的退出码 | 成立 | shell 语义（本地用假文件实测的命令被安全 hook 以"反向 Shell"误拦两次，未绕过） | 阶段 2 手册 4 处、阶段 0 手册 4 处改为 `rc=$?` 紧随 python；验收同时核对本次 summary；BRINGUP-025 补注 0d-1 的 `OPENQ_RC` 实为 tail 的退出码，该次运行的完成由同日志中的 summary 行证明 | 文本复核 |
| F9 重复部署覆盖回滚备份 | 成立 | 命令静态推导 | 备份只建一次；安装前校验备份为 CDC 候选、暂存为 NC 镜像（完整 SHA），回滚前再校验备份 | 文本复核 |
| F10 ANY 放行不完整记录 | 成立 | `tests/ofdm_nc/test_nc_rxs_check.py`（3 项红灯）；独立审查者 的两份变异日志修复前通过 | ANY 只放宽"是否必须成功"，成功记录与 OK 同样检查全部字段与比较位数，并拒绝重复 | 测试通过；两份变异日志被拒，原日志仍通过 |
| F11 环回缺少帧 ID 记分板 | 成立 | 测试台代码推理 | 每个发出的 ID 必须恰好成功一次，外来或重复 ID 计为错误，最后核对缺失 | 环回重跑（见下） |

附带处理：
- 日志一致性：`lean_adapt.py` 记录的逐组度量与策略使用同一口径（传入掩码）；有测试。
- 参考实现对已屏蔽组 m=inf 抛异常：改为视为被破坏，与板上版一致；有测试。
- `lean_adapt.py` 文件头关于"日志格式与旧版相同"的说法改为：行为相同，config 行多列出新参数。
- cmetric 文件头"128 拍清零"的过时注释已改为实际的 384 个字 / 385 拍。
- 假寄存器模型修正：0x054 为命令寄存器，写入值不回读（否则清零命令被误读为超时标志）。

## 覆盖缺口的处理

- 已补：突发进行中改写 0x048 只影响下一次 TX_GO（核心仿真）；度量读超时标志（核心仿真与 PS 测试）。
- 仍未覆盖、如实保留：候选 2（全零掩码）被实际接受的定向场景；盲检门限恰等于组累加值与极值；冻结期间在途度量的一致性；复位中读度量。这些不影响已有结论，但在报告中列为未覆盖。

## 最终源码回归

| 运行 | 结果 |
|---|---|
| `build/ofdm_nc/final_rxs02`（RX 核心，回退量 16） | 11/11 场景通过（NC 5 个 + 原版回归 6 个），检查器为修复后的 F10 版本 |
| `build/ofdm_nc/final_loop02`（TX→RX 环回） | 6/6 用例通过，记分板 6 项均"缺失或重复 = 0" |
| `build/ofdm_nc/final_lean02`（开发核心） | LEAN_PASS，failures=0；NC_RX_LAST 完整 32 位 0x00800080 / 0x00070007；超时标志 0；突发中改写 0x048 后本突发仍为 0x001，12/12 帧正确 |
| `build/ofdm_nc/cmetric04`、`cancel_green01` | 度量模块随机向量（含 F2 定向序列）与 F1 定向测试通过 |
| 主机测试 | 板上侧与模型 134 项、参考实现 21 项通过 |

三次仿真运行开始时记录的源文件哈希，运行后逐个复核未变。

重新综合 `build/ofdm_nc/core_synth03`：LUT 20641（+45），端口 476 与上一版相同。整平台实现 `build/ofdm_nc/platform_impl02`：WNS +0.029 ns、WHS +0.035 ns、WPWS +0.062 ns，全部约束满足，0 布线错误；CDC 49 个时钟对与复现版逐行相同；DRC 新出现 PDRC-61 两条（与原版 PDRC-62/63 同类的 LUT O5 悬空提示），DPOP-1 为 12 条。新开发 BOOT `build/devboot/dev_nc_20261026/BOOT.BIN`（`0b3ce7ee…`），未上板；审查前的 `dev_nc_20261025` 已标注作废。
