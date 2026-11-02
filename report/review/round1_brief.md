> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 代码审查说明：子载波组屏蔽（NC）与时频联合策略

日期：2026-10-26。请求方：项目团队。实现方：Claude（2026-10-25 完成）。
审查方式：**只读审查**。请不要修改任何源文件、测试、文档或构建产物；唯一允许写入的文件是审查结果 `report/review/round1_findings.md`。如需运行测试或仿真，只能把输出写到 `build/review_probes/` 下新建的目录。不要操作开发板、串口或 SD 卡。

## 1. 背景（先读这些）

- 工程：ZC706 + ADRV9009 上 122.88 MSPS 的 QPSK/16QAM OFDM 收发系统，PL 主时钟 200 MHz。128 点 FFT，CP 32，88 个数据载波加 8 个导频。
- 创新扩展"时频联合自适应"：A 为 PS 侧调制自适应（OLLA），B 为干扰感知的子载波组屏蔽。88 个数据载波按有符号顺序分 11 组、每组 8 个，最多屏蔽 3 组；屏蔽组在帧头和载荷符号中发 0。帧头放在前 64 个未屏蔽载波上，字节 10–11 回显掩码。接收端按候选掩码 {上一帧掩码、盲检掩码、0} 依次尝试。
- 设计文档：`docs/innovation/b_subcarrier_mask_design.md`（B，§2–§6 最相关）、`docs/innovation/joint_adaptation_design.md`（§3、§7.1）。
- 实现与验证记录：`docs/innovation/stage1_nc_rtl_report.md`（必读，含已发现的问题及处理方式）。
- 板上运行手册（待执行）：`docs/innovation/stage2_board_runbook.md`。
- 开发约束：设计文件为 Verilog-2001（`.v`），测试台为 SystemVerilog（`.sv`）；工具 Vivado 2023.2（`D:\Xilinx\Vivado\2023.2\bin`，不要用 PATH 里的 2019.1）；板上 Python 为 3.9。

## 2. 审查对象

### 2.1 RTL（`rtl/ofdm_nc/`，均为 `rtl/ofdm/` 同名文件的修改副本，模块名不变）

用下面的命令只看改动（两个文件的换行符与原文件不同，必须加 `--strip-trailing-cr`）：

```
diff -u --strip-trailing-cr rtl/ofdm/<子目录>/<文件> rtl/ofdm_nc/<子目录>/<文件>
```

| 文件 | SHA256 前 16 位 | 改动行数 | 内容 |
|---|---|---|---|
| `txs/ofdm_tx_framer_v2.v` | `08c78c0bd581b4a2` | 75 | 掩码锁存、可变几何、9 步除法、帧头字节 10–11、故障判断 |
| `phy/ofdm_carrier_loader.v` | `1cf476230f608568` | 68 | 写侧按组跳过、读侧屏蔽 bin 置 0 |
| `rxs/ofdm_rxs_decode.v` | `c9b75fa4299c63c4` | 190 | 候选掩码状态机、盲检流水线、可变除数与符号数越界、载荷只取未屏蔽载波、度量输出 |
| `lean/ofdm_development_core.v` | `62ca0f6d9553be3f` | 81 | 0x048–0x06C 寄存器、TX_GO 锁存掩码、度量读窗口与 AXI 等待 |
| `rxs/ofdm_rxs_core.v` | `142764e53c785bfc` | 31 | 透传与度量模块实例化 |
| `txs/ofdm_frame_grid_v2.v`、`ofdm_tx_frame_v2.v`、`ofdm_tx_rf_frame_v2.v` | — | 4–7 | 只透传 `cfg_mask` |
| `rxs/ofdm_rxs_cmetric.v`（新） | `03334fa7eefd9c9a` | 148 | 逐载波度量：6 级流水读改写、BRAM、清零、AXI 读仲裁 |
| `phy/ofdm_nc_map.vh`（生成） | `dbece355ae63bb96` | 225 | 由 `scripts/rtl/gen_nc_map.py` 从模型生成，可用 `--check` 校验 |

### 2.2 模型、PS 与联合策略

| 文件 | SHA256 前 16 位 | 内容 |
|---|---|---|
| `models/ofdm_nc/nc.py` | `42f784762229d99f` | 参考模型（帧编码/对齐解码/几何） |
| `build/innovation_joint/joint_policy.py` | `a85e1e43acf82623` | 联合决策主机参考实现 |
| `scripts/board/lean_nc.py` | `2ed05f992ac5a64f` | 板上：寄存器、度量换算、联合决策移植、OLLA |
| `scripts/board/lean_adapt.py` | `7b9e7ec1276125d3` | 板上主循环；NC 部分为 `--policy joint/--mask/--nc-metrics/--allow-fft-saturation`、`nc_preflight`、`run()` 中的 NC 分支与 `finally` |

### 2.3 测试与检查脚本（判断"验证是否真的在验证"）

- 模型与 PS：`tests/ofdm_nc/test_nc_model.py`、`tests/bringup/test_lean_nc.py`、`tests/bringup/test_lean_adapt_nc.py`、`build/innovation_joint/test_joint_policy.py`
- 仿真：`tests/rtl/ofdm_nc/*.sv`；向量与检查：`scripts/rtl/nc_grid_vectors.py`、`scripts/rtl/nc_cmetric_vectors.py`、`scripts/model/nc_rxs_vectors.py`、`scripts/model/nc_rxs_check.py`；运行脚本 `scripts/rtl/run_nc_*.ps1`

## 3. 请重点回答的问题

### 3.1 正确性与安全（RTL）

1. 解码器能否在任何情况下把错误数据当作正确帧发布（误收）？特别是：候选循环中 `hbytes` 与 `cand_mask` 是否始终对应；盲检结果在候选 1 使用时是否一定已就绪；去重逻辑是否会漏掉应试的候选。
2. 符号数计算：`div_den`（16G/32G）、9 位商、`nsym_full > 191` 判定在所有合法与非法长度、掩码组合下是否正确；超长时 fetch 与解码器状态是否干净复位。
3. `masked_now` 与 `ord` 计数：载荷符号中被屏蔽载波是否严格不推进 LFSR、不计入 `carriers_left` 和擦除计数；最后一个符号的填充载波是否处理正确。
4. 组帧器：9 步恢复除法在 R0 ≤ 4143、D = 字节数 << 8 时是否无溢出；`Q > 187` 故障时状态机是否停在安全状态；帧头字节 10–11 是否进入 CRC。
5. 载波装载器：`next_group` 在 `wj == 7` 时是否一定是新 `wg` 的值；掩码只在复位时锁存的前提在核心里是否总成立（TX_GO → 64 拍复位 → 释放）。
6. 度量模块：读改写的冒险分析（同址间隔 ≥ 88 拍的假设在实际解码器输入流中是否成立，包括头符号两份副本、帧头失败中途退出的帧）；清零期间在途写回；AXI 读在流水线持续占用时是否可能饿死。
7. 开发核心：读窗口的 `r_wait` 能否把 AXI 读通道卡死（RX 复位、度量块复位、超时路径）；`arready` 与写通道的交互；寄存器复位值与文档是否一致。
8. 时钟域：NC 新增信号是否全部在 200 MHz `clk` 域（整平台 CDC 报告与原版逐行相同，请从代码角度确认没有遗漏）。

### 3.2 PS 与板上安全

9. `nc_preflight` 是否在任何 NC 路径下都先于第一次发射执行；`finally` 中恢复掩码 0 是否在所有异常路径下都会执行，是否可能掩盖原始异常。
10. 不加 NC 选项时，行为与日志格式是否与修改前完全一致（修改前副本：`build/stage0a/lean_adapt_before_nc_790d4af3.py`）。
11. `group_metrics` 的头符号回退：以 QPSK 参考换算头符号度量、已屏蔽组视为被破坏，这两点是否会导致掩码只增不减或来回抖动。
12. 阶段 2 手册中的板上命令是否有会造成误操作的地方（寄存器值、单音功率上限、回滚步骤）。

### 3.3 联合决策

13. `survival` 的暴露量折算、`candidates` 只屏蔽最差 k 组、L_max 可行性过滤、迟滞（调制 5%、仅掩码 1%）在边界情况下是否合理；有无可能选出非法组合或陷入不可恢复状态。
14. 板上移植与参考实现是否真正等价（测试只覆盖了随机场景与若干定向用例）。
15. OLLA 只在 16QAM 窗口更新偏移、联合策略中不用预测项，这与 A 的实测结论（`joint_adaptation_design.md` §7.1）是否一致。

### 3.4 验证充分性

16. 哪些重要行为没有被任何测试覆盖？例如：突发中途改写 0x048、盲检门限 0x050 的取值范围、度量冻结期间的读一致性、16QAM 下屏蔽组的头符号度量。
17. 测试中的放行与例外是否合理：单音场景放行 `long_plateaus`；环回测试台在换掩码前等待 TX 空闲；RX 测试用回退量 16。

## 4. 已知并已接受的限制（无需重复报告，除非发现其中有错误）

- 强单音（估计 JSR ≥ −5 dB）时屏蔽失效：检测与频偏估计被单音带偏，需要检测支路陷波（B2），不在本阶段范围。
- 屏蔽帧的检测定时偏晚（最多约 14 个样本），处理方式是 RX 回退量取 16（寄存器），代价是多径容限约 10 个样本。
- QPSK 屏蔽时帧长须不超过 2988 B（L_max），实验用 2048 B。
- 单音会使 FFT 饱和计数增加（单音集中在一个频点）；`--allow-fft-saturation` 只放行这一项。
- 未实现：训练校验排除组、导频忽略、导频误差库。
- 布线余量小（WNS +0.067 ns、WHS +0.010 ns），但全部约束满足。
- 根目录 pytest 有 33 项与本次改动无关的旧失败（V0.1 帧格式哈希固定、RTL 文本固定、tkinter 环境），本次前后一致。

## 5. 可运行的检查（可选，输出只写到 `build/review_probes/`）

```
python -B -m pytest -q -p no:cacheprovider tests/ofdm_nc tests/bringup
python -B build/innovation_joint/test_joint_policy.py
python -I -B scripts/rtl/gen_nc_map.py --check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtl/run_nc_grid_sim.ps1 -Work build/review_probes/grid01 -Rtl nc
```

RX/环回/核心级仿真各需 15–20 分钟（`run_nc_rxs_sim.ps1`、`run_nc_txrx_sim.ps1`、`run_nc_lean_sim.ps1`，参数见文件头，`-Vectors` 等数组参数须用 `-Command` 方式传入）；如要运行，请同样使用 `build/review_probes/` 下的新目录，并且一次只运行一个 Vivado 作业。

## 6. 输出格式

写入 `report/review/round1_findings.md`，每条一行表格或一小节，包含：

| 字段 | 说明 |
|---|---|
| 编号 | F1、F2… |
| 严重程度 | 高（可导致误收、总线卡死、板上误操作或错误决策）/ 中（特定条件下功能错误或性能损失）/ 低（可读性、可维护性、文档不一致） |
| 位置 | 文件:行号 |
| 问题 | 一两句话 |
| 触发条件 | 具体输入、状态或时序 |
| 依据 | 代码推理、运行结果或文档出处；推测的请标明"推测" |
| 建议 | 修改方向（不需要给出补丁） |

最后请单列"审查过但未发现问题的部分"和"没有审查到的部分"，便于判断覆盖范围。实现方会逐条复现或反驳，确认后再修改，并记录结果。
