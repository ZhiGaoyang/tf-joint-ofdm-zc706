> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# NC 子载波屏蔽与联合策略只读审查

日期：2026-10-26。范围：`report/review/round1_brief.md`。

仅新增本报告及 `build/review_probes/` 下的审查探针、日志。未修复产品源码、测试、设计文档或既有产物，未访问板卡、串口、SD。审查说明列出的 11 项短 SHA 均与实际文件匹配。原报告的布线、CDC、板测结论未作为本次重新验收结果。

## 结论与证据等级

发现 11 项应交实现方复现或处置的问题，均按特定条件下影响评为中；没有据此宣称已出现 RTL 坏载荷 CRC 误收或 AXI 永久卡死。优先处理部署回滚/退出码、异常清理、策略返回值合法性，以及度量读取事务归属。报告所列功能问题与验证器缺陷分开，不用验证器缺陷反推实际硬件已经出错。

| 检查 | 本次结果 | 证据 |
|---|---|---|
| 模型与 bringup 主机测试 | 122 passed，pytest 退出 0，约 3.30 秒 | `build/review_probes/host_20261026_01/pytest.log`、`pytest_exit.txt` |
| 联合策略参考测试 | 18 tests，退出 0 | `build/review_probes/host_20261026_01/joint.log`、`joint_exit.txt` |
| 生成映射一致性 | NC_MAP_CHECK PASS，退出 0 | `build/review_probes/host_20261026_01/map.log`、`map_exit.txt` |
| 原始 cmetric RTL 清零边界定向仿真 | **语义 FAIL**：RAM 全零但 HDR 计数为 1 | `build/review_probes/metric_probe01/sim.log`、`result.json` |
| 原始 cmetric + 核心读等待逻辑摘录定向仿真 | **语义 FAIL**：第二次读收到第一次地址的数据；不是完整核心联测 | `build/review_probes/metric_timeout01/sim.log`、`result.json` |
| TX/RX 定宽算术转录 | 各覆盖 32,776 个 G/MCS/长度组合；TX 还遍历 232 个合法掩码与随机停顿握手 | `build/review_probes/tx_arithmetic_20261026_01/probe.log`、`build/review_probes/rx_probe01/result.json`；这是软件转录，非 RTL 穷举证明 |
| PS 边界/异常注入 | 复现失联非法配置、清理遗漏、固定调制被改变等 | `build/review_probes/ps_probe01/results.json`、`build/review_probes/ps_fixed02/results.json` |

注意：两项 RTL 定向仿真均打印 `$fatal`，但本机 xsim 原生退出码及原始 launcher 退出码仍为 0。`stages.json`/`parent_exit.txt` 如实保存 0；`result.json` 独立记录 semantic_result=FAIL、semantic_exit=1。原生进程成功退出与功能断言通过是两件事，未将这两个失败计作 PASS。两个小仿真串行执行，未运行综合/布局布线或 15–20 分钟的完整 RX 仿真。

## Findings

### F1：超时读未取消底层请求，下一次读取可能接走旧响应

- 严重程度：中。
- 位置：`rtl/ofdm_nc/lean/ofdm_development_core.v:374-380,409-411`；`rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v:76,141-145`。
- 问题：核心 64 拍超时后返回零并释放 AXI 读通道，但 cmetric 的 `rd_pending` 仍保留旧请求。此时新请求会被底层忽略，随后旧 `rd_valid` 又可满足新一轮 `r_wait`，造成地址与数据错配。
- 触发条件：非冻结状态下，流水读连续占用端口超过 64 拍；第一个度量读超时，第二个读在旧响应产生前进入。端口接口允许连续 88 个不同 ord，满足同址间隔要求；CPE 在解码器背压期间可积攒 FIFO 数据，但实际整核何时形成足够长的连续段，本次未跑整核时序轨迹确认。
- 依据：原 cmetric RTL + 核心相同读等待控制摘录仿真，连续送 ord=0..87，在第 8 个载波请求 HDR[0]，第 78 个载波请求 PAY[0]。第一响应为超时零，第二响应为 **65533**，而 PAY[0] 从未写入，应为零。日志 `build/review_probes/metric_timeout01/sim.log`。该探针证明协议在此输入时序下失配，不声称完整平台实测已经触发。
- 建议：超时与底层请求生命周期一起处理，例如取消/排空旧请求后再接新事务，或明确返回归属；同时给出真实输入流的最大仲裁等待界限。补超时→立即换地址再读、RX 复位中读两类测试。仅延长常数不解决一般的旧响应归属问题。

### F2：清零脉冲与符号计数更新同拍，清零后计数不为零

- 严重程度：中。
- 位置：`rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v:104-108,132-138`。
- 问题：`clear` 分支先对符号计数赋零，但同一 always 后面的 `c3_last && !clearing` 使用旧 clearing 值，并以非阻塞赋值覆盖清零。RAM 清完而分母计数保留，随后 PS 换算的 EVM/擦除率会偏低。
- 触发条件：`clear && !clearing && c3_v && c3_last` 同拍，例如接收完整头符号最后一个元素在流水中时清零；没有要求软件只在空闲清零的硬件约束。
- 依据：真实原 cmetric RTL 定向仿真，完整按序输入 88 个头载波后对齐该边沿，等待 clear_busy 结束：`CLEAR_EDGE_OBS hdr=1 pay=0 nonzero_words=0`。日志 `build/review_probes/metric_probe01/sim.log`。既有随机向量未覆盖这一精确重合。
- 建议：为清零建立优先级，明确丢弃/排空在途度量的策略；补清零与各流水级最后元素重合的测试。当前 PS 通常在突发前清零，故此项不等于每次实验都会发生。

### F3：NC_RX_LAST 拼接少一位，诊断位域错位

- 严重程度：中。
- 位置：`rtl/ofdm_nc/rxs/ofdm_rxs_decode.v:189`。
- 问题：拼接宽度为 31 位，漏掉 last_ok 上方的保留 bit 11。实际 last_src 位于 [12:11]、blind_over 位于 13、blind_mask 位于 [25:15]，与接口的 [13:12]、14、[26:16] 不一致。
- 触发条件：读取 0x060 或按文档字段解析 RXS_NC/RXL_STATUS；非零候选来源或盲检掩码可立即显现。
- 依据：`build/ofdm_nc/final_rxs01/nc_switch.log:25` 首次通过 mask=128，却显示 src=0、blind=64；代码实际为 blind candidate 1、盲检 mask=128。探针结果见 `build/review_probes/rx_probe01/result.json`。现有核心测试主要核对低 11 位，漏掉高位。
- 建议：按接口显式补齐保留位，验证完整 32 位及各字段的复位值、candidate 0/1/2 和 blind_over。此问题影响诊断，不等价于内部候选选择错误。

### F4：完全失联回退绕过帧长可行性过滤

- 严重程度：中。
- 位置：`scripts/board/lean_nc.py:167-172`；`build/innovation_joint/joint_policy.py:130-132`。
- 问题：全部 SNR 为 None 时直接返回 QPSK 并保留 mask，跳过正常候选的 L_max 约束。
- 触发条件：4096 B、16QAM、mask=0x080 是合法状态；下一窗口无任何度量时返回 QPSK/0x080，该组合 L_max=3736 B。
- 依据：`build/review_probes/ps_probe01/results.json` 的 outage 连续决策为 `(1,{7},switch)` → `(0,{7},link_lost)`。下一窗口会触发 TX framer 故障。参考实现有相同错误，因此“移植与参考相等”没有检出。阶段二既定 2048 B 命令不触发该长度边界。
- 建议：所有返回路径统一保证 `(调制, 掩码, 长度)` 合法，明确无度量时合法的恢复状态；测试从可行 16QAM 屏蔽态进入失联及恢复。

### F5：恢复衰减异常会跳过恢复零掩码

- 严重程度：中。
- 位置：`scripts/board/lean_adapt.py:458-463`。
- 问题：finally 先恢复 IIO 衰减，再清 0x048；第一项抛异常时第二项不执行。后续无 NC 参数的运行不写 0x048，会继承遗留屏蔽。
- 触发条件：已写非零 mask，启用衰减轨迹，退出时 IIO 恢复失败。
- 依据：主机 FakeCore 注入窗口 RuntimeError 与恢复 OSError 后，0x048 仍为 128；顶层传播变成 OSError，原窗口异常仍在 Python `__context__` 中。见 `build/review_probes/ps_probe01/results.json` 的 cleanup。并非声称原异常完全丢失。
- 建议：各清理动作独立保证尝试执行，首要异常与清理异常分别记录；补双重失败测试，不只测试窗口失败、清理成功。

### F6：joint 模式接受 --fixed，但第二窗口起会改变调制

- 严重程度：中。
- 位置：`scripts/board/lean_adapt.py:299-309,370,420-424`。
- 问题：joint 分支优先于 `a.fixed is None`，无条件采用策略下一调制，违反 fixed 的既有语义；可能让固定调制对照臂名实不符。
- 触发条件：`--fixed 0 --policy joint` 与有效标定文件，良好信道。
- 依据：用现有 FakeCore 运行三个窗口，实际传输模式为 `[0,1,1]`，见 `build/review_probes/ps_fixed02/results.json`。阶段二当前列出的各臂没有此冲突组合。
- 建议：硬件访问前明确报参数冲突，或实现真正固定调制、仅调掩码的语义；补 CLI 与主循环联动测试。

### F7：全部候选零分时维持 16QAM，与已声明的断链策略不符

- 严重程度：中。
- 位置：`scripts/board/lean_nc.py:171-179`；`build/innovation_joint/joint_policy.py:134-142`；`docs/innovation/joint_adaptation_design.md:164`。
- 问题：至少四组为 DESTROYED_DB 时，最多屏蔽三组，所有候选及当前状态分数均为零；严格增益比较 `0 > 0` 不成立，保持当前 16QAM，而设计 §7.1 声明此情况按断链回 QPSK。
- 触发条件：先在干净信道进入 16QAM，随后四组触发擦除/损坏判据，且仍有度量。
- 依据：`build/review_probes/ps_probe01/results.json` 的 four_erased 返回 `(1,{},hold)`。与 F4 不同：本项有度量、返回组合合法，只是未执行声明的零可行收益回退。
- 建议：实现方明确决定全零分时的行为并使代码与设计一致，同时保留 F4 的长度约束。不主张 QPSK 一定能救回四组损坏，也不将本项描述为永久不可恢复。

### F8：板上冒烟命令保存的是 tail 退出码

- 严重程度：中。
- 位置：`docs/innovation/stage2_board_runbook.md:58-64`。
- 问题：`python ...; tail ...; echo XXX_RC=$?` 的 `$?` 属于 tail。Python 失败、日志可读时仍可显示 RC=0；重跑独占日志名失败时，甚至会展示上一次的成功 summary。
- 触发条件：Python 失败但 JSONL 已存在，或重复使用旧日志名。
- 依据：本机 shell 以失败命令替代 Python 后运行相同排列，打印 `SM0Q_RC=0`；不涉及板卡。shell 语义与第 64 行以 RC=0 验收相冲突。
- 建议：紧跟 Python 保存其退出码，再打印日志；验收还需核对本次完成记录和运行身份。不要用 tail 成功代替实验成功。

### F9：重复部署会覆盖手册指定的 CDC 回滚备份

- 严重程度：中。
- 位置：`docs/innovation/stage2_board_runbook.md:44,50`。
- 问题：安装行每次都无条件将当前 BOOT 覆盖到固定名称的 CDC 备份，缺少“已存在则验证而不覆盖”的分支。
- 触发条件：首次替换 NC 成功后，因串口回执缺失、重启/检查失败而重复执行安装行。此时当前 BOOT 已是 NC，备份将被 NC 覆盖。
- 依据：命令静态推导；第 50 行从同一备份名回滚，结果仍是 NC。并未上板复现；黄金卡仍是独立恢复途径，不是所有回滚材料丢失。
- 建议：首次备份使用不覆盖语义；再次执行先验证既有备份的完整 CDC SHA。安装与回滚前分别验证来源身份，失败即停止该步骤。

### F10：ANY 接收场景放行字段错误或未比较的 OK 记录

- 严重程度：中，验证器缺陷。
- 位置：`scripts/model/nc_rxs_check.py:53-55`。
- 问题：ANY 只检查成功记录的 BER、长度和 mask，漏掉 MCS、实际比较位数；与文件头“禁止损坏的 OK 记录”不符。
- 触发条件：ANY 场景出现 reason=0，但 MCS 错误或 cmp=0。
- 依据：在原通过的 nc_tone 日志 frame 1303 上独立变异 mcs=0→1 或 cmp=144→0，两次检查都返回 problems=[]。见 `build/review_probes/rx_probe01/result.json` 及该目录两份变异日志；第二位审查者也独立复现。原日志保留原样。
- 建议：ANY 仅放宽是否必须成功；每个 OK 记录复用普通 OK 的完整字段和比较位数断言，并检查重复成功记录。该发现不证明 RTL 已经误收。

### F11：环回 PASS 缺少帧 ID 唯一性与完整集合检查

- 严重程度：中，验证器缺陷。
- 位置：`tests/rtl/ofdm_nc/tb_nc_txrx_loop.sv:105-107,168`。
- 问题：按 ID 选择突发掩码后累计 ok，最终只比较总成功条数。重复一个正确 ID、遗漏同突发另一个 ID，仍可能 PASS。
- 触发条件：总成功条数正确、每条字段/PRBS 比较正确，但实际收到的 ID 多重集合与发出集合不同。
- 依据：测试台判定的静态代码推理；未发现实际 RTL 重复发布，也未注入整链 RTL 故障复现。
- 建议：增加预期 ID 的范围、唯一性及最终完整性 scoreboard；不需要为此重跑所有不受影响组件。

## 审查过但未发现问题的部分

- 问题 1：在配置稳定、上游遵守完整 88 载波符号契约时，cand_mask 先锁存，下一拍才选 hbytes；CRC 覆盖前 12 字节含 mask echo。candidate 0 总先执行 CRC/字段检查，给盲检最后两拍留足余量；candidate 去重未发现遗漏。F3 是输出打包问题，不是这些内部控制失配。
- 问题 2：RX 使用 16 步恢复除法、9 位商，G=8..11、MCS=0/1、长度 0..4096 的定宽转录符合数学结果。原始 16 位长度先检查 <=4096；超 191 符号反馈零、清上下文并回 RUN，fetch 在边界停止；未发现非法高位长度截断后进入载荷的路径。
- 问题 3：masked_now 抑制 take_payload/want_payload，因此不推进 LFSR、carriers_left 或载荷擦除计数；有效数据结束后的填充仍可进入度量。解码器本身输出帧状态而非通用载荷发布接口，本次未作超出该接口的“字节发布”保证。
- 问题 4：TX R 最大 4143，D 最大 11264，D 超过 8191 时比较必假，低位截取不触发错误减法；9 位商足够。Q>187 后 fault 阻止启动；帧头 10–11 字节纳入 CRC。
- 问题 5：loader 的 next_group 在第八次握手使用前已有更新余量；核心仅在 TX_GO 更新 tx_mask_burst，随后保持 64 拍复位。突发中写 0x048 只改下一次锁存值；wrapper 未另开时钟域。
- 问题 6：实际度量源按完整符号顺序输出，头副本结束后才进入下一份；头 CRC 失败是在第二份完整头之后判定。未发现正常流下同址在 RMW 未完成时再次更新的冲突。clear 期间 write port 优先清零、在途写被覆盖，观察到的缺陷是 F2 计数优先级。freeze 仅停止新 take，不立即撤销在途项。
- 问题 7：r_wait 有 64 拍或 RX reset 退出路径，RVALID/RDATA 在响应背压时保持，写通道独立；未发现新增永久总线等待。有限超时不代表数据归属正确，见 F1。新增寄存器主要复位值匹配实现报告；cmetric 文件头“128 拍清零”是过时注释，实际为 384 个 RAM 地址。
- 问题 8：新增 mask/threshold/metric/diagnostic 信号从 core 的 clk 寄存器出发，经 TX PHY/RX core 同一个 clk 处理；度量读口也在该域。未从代码看到新增直接跨 tx_clk/rx_clk 的 NC 数据路径。此结论是源码连线审查，不是独立重跑物理 CDC。
- 问题 9：joint、显式 mask（含 0）、nc-metrics 都在第一次发射前执行 nc_preflight。allow-fft-saturation 单独使用不触发 NC 预检，可用于非 NC 单音实验；不将其视为漏检。清理异常边界见 F5。
- 问题 10：相对 `build/stage0a/lean_adapt_before_nc_790d4af3.py`，无 NC 参数时原决策/发射/守卫路径保持；“日志逐字完全一致”不成立，因为 config.args 新增默认字段且脚本 SHA 改变。窗口未自动增加 NC 字段，建议作为兼容性说明。
- 问题 11：头符号强制 QPSK 参考，header-only 回退选择 QPSK 标定；已有掩码在无载荷观测时视为未知并保持屏蔽符合设计。有载荷时零参考可测解除屏蔽条件，未发现必然只增不减。1% 迟滞不等于所有长度/帧数条件下保证快速解除或无抖动。
- 问题 12：回退量/增益寄存器位域和 CTRL=10 与实现一致，单音功率参数与其引用的阶段零规则一致；本次未独立核验模拟前端的功率容限。退出码和回滚重入问题见 F8/F9。
- 问题 13–15：普通有限输入下 exposure、候选、评分和迟滞的移植与参考一致；OLLA 只用 16QAM CRC/truncated 更新且无预测项，符合 §7.1 主要调整。仍有 F4/F7 的公共策略漏洞。参考端对已屏蔽组 m=inf 发生 log10(0) 异常，板端则视为 destroyed，因此等价性应限定输入域；这不是板端更差。所谓“等同 S6”也不是逐项算法恒等，joint 未完全复制其平滑/时间更新等行为。
- 问题 17：仅单音场景放行 long_plateaus、换掩码前等待 TX 真空闲、回退量取 16，均有已接受边界依据；不因其为例外就判作错误。F10/F11 是这些测试之外独立的验收薄弱点。

## 没有审查到的部分与待补覆盖

- 未执行任何板测；尚未验证 NC 在真实射频上的功率、温度、恢复或收益。未重跑综合/布局布线、完整 RX/TX→RX/开发核心长仿真，未独立逐行比较原版与 NC 的完整物理 CDC 报告。
- F1 只有原度量 RTL 与读协议摘录的定向复现，尚缺真实 CPE→decoder→core 在连续流下的复现和最大仲裁等待测量。冻结后读取通常会快速腾出端口，因此不把 F1 描述为现有 frozen_metrics 每次必错。
- 未见 candidate 2 真正成功接受的定向验证（已查最终 RX suite 的 zero_hits 均为 0）；还应补 candidate/CRC/divider 中途复位、合法 CRC 配非法高位长度、盲检阈值恰等于组累加值、阈值 0/最大值的边界。
- 未见突发中改写 0x048 的核心定向测试；当前保证来自代码分析。未穷举屏蔽/最后填充载波的 usable=0 与标签异常输入；未对所有非法 AXI 主机序列作证明。
- 冻结时仍有在途度量，当前完整核心测试在突发完成后冻结；对中途冻结的 RAM/符号计数一致性、复位中度量读、clear 与读重合，还缺独立接口测试。也未证明 16 位擦除饱和在所有超长窗口中的语义。
- 模型/向量/参考实现存在共享来源，软件定宽转录与参考等价测试不是独立形式证明。现有非法 TX 几何测试只检查 fault，未同时检查零输出；环回等待 TX busy/quiet 的部分不在后置 timeout 内。
- 日志一致性备注：`scripts/board/lean_adapt.py:408` 记录 m_g 时未传 tx_mask，header-only 时已屏蔽组会记成数值，而策略使用带掩码的未知值处理。实际策略决策不因此改变，但分析日志时应区分两者。
- 阶段二最终生成命令清单、ABBA 展开、轮次及外部硬件接线尚未提供给本次审查；只审查已有运行手册文本。

建议实现方先逐条复现 F1–F11，保留有异议项的反证；确认后再修改。测试补充优先对应已证实失败和边界，复用源码未变的既有结果，无需立即再跑全项目验收。
