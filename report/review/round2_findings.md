> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# F1–F11 只读复审

日期：2026-10-26。依据：`report/review/round2_brief.md`、实现方逐条答复及当前源码。旧审查报告与原始失败证据保持原样。

本轮仅写本报告和 `build/review_probes/rereview_*` 新目录。未修改产品源码、测试、运行手册或既有构建产物；无开发板、UART、SD 操作。三个小型 xsim 作业串行执行，未运行综合、布局布线或完整 RX 长仿真。

## 结论

**F1–F11 的原始缺陷均判定已解决，判定范围是原触发机制及本轮列明的验证，不是全系统或上板放行。** F5 的原始“恢复衰减失败导致跳过清掩码”已消除，但更广的异常优先级仍有 N3。F9 的 BOOT 备份覆盖已消除，脚本备份和部署失败后的重启仍分别有 N2/N1。

新增 **2 项中、2 项低**：部署失败后的无条件重启、脚本备份缺少重入保护、异常诊断自身失败覆盖主异常、寄存器文档滞后。建议实际部署前先处理 N1/N2；N3/N4 属有界后续工作，无依据要求因此重跑全部 PHY 回归。

### F1–F11 判定表

| 编号 | 判定 | 依据 | 备注 |
|---|---|---|---|
| F1 | 已解决 | `rtl/ofdm_nc/lean/ofdm_development_core.v:377-385,415-417`、`rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v:149-157` 增加 cancel。上一轮探针按新读控制接线重跑，第二次 PAY 读取由错误的 65533 变为正确的 0；补 93 组端口释放/响应背压组合通过。 | 原 cmetric RTL + 核心读控制摘录，不是新跑整核心。既有 `final_lean02` 证据另行复核。详见下文取消时序说明。 |
| F2 | 已解决 | `rtl/ofdm_nc/rxs/ofdm_rxs_cmetric.v:53-54,110-114,142-145`。原清零碰撞探针仅适配新增 cancel 端口后重跑：HDR=0、PAY=0、非零 RAM 字=0，CLEAR_CONTRACT_PASS。 | `!clear` 停止清零起始拍的新输入符合丢弃该清零窗口度量的语义，不影响解码器数据通路。 |
| F3 | 已解决 | `rtl/ofdm_nc/rxs/ofdm_rxs_decode.v:189-190` 补保留 bit 11。独立解析拼接的 32,768 组字段检查通过，既有 `final_lean02/lean.log` 完整字 00800080、00070007 正确。 | candidate 2 的位域取值已检查，不等于动态接受 candidate 2 已仿真；复位文档错误见 N4。 |
| F4 | 已解决 | `scripts/board/lean_nc.py:176-180` 及参考实现同步检查回退长度。4096 B 原探针现在从 16QAM/0x080 回到 QPSK/0，恢复输入后能重选 16QAM/0x080。 | 清掩码仅在保留掩码的 QPSK 装不下长度时发生；10 个长度的失联/恢复序列检查通过。 |
| F5 | 已解决（原场景） | `scripts/board/lean_adapt.py:467-483` 独立尝试各项清理。主流程/恢复衰减/清掩码的 8 种成败组合通过：原主异常优先，主流程成功但清理失败则抛 RuntimeError。 | 正常日志和诊断条件下成立；日志/诊断/解冻再失败的扩展缺口单列 N3，未宣称“所有异常均已处理”。 |
| F6 | 已解决 | `scripts/board/lean_adapt.py:303-304` 参数解析阶段排斥 joint+fixed。fixed=0/1 均实际退出 2，未构造 Core 或创建运行日志。 | 不再悄悄把固定调制对照变成自适应。 |
| F7 | 已解决 | `scripts/board/lean_nc.py:186-191`、参考实现及设计 §3.3 定义 no_viable。四组损坏时，2048 B 返回 QPSK/0x007，4096 B 返回 QPSK/0；恢复后可离开 no_viable。 | 是明确的零收益恢复规则，不声称最多屏蔽三组能够消除四组损坏。实际 JointOllaPolicy/raw metrics 路径及 delta=-4 dB 也检查恢复。 |
| F8 | 已解决 | 阶段 0 手册 4 处及 `docs/innovation/stage2_board_runbook.md:59-62` 均紧接 Python 保存 rc。提取八条实际命令，在本机 Bash 用假日志/mock Python 重跑，失败均保留 RC=7，成功对照均 RC=0。 | 旧成功 summary 存在也不会把失败 RC 变成 0；第 65 行增加本次 completed summary 要求。 |
| F9 | 已解决（BOOT 备份） | `docs/innovation/stage2_board_runbook.md:45,51` 首次建立备份、重入只校验且不覆盖，备份与暂存均核对完整 SHA。假文件实测首次/重试/坏暂存/坏备份/回滚分支符合要求。 | 正确校验并未解决后续无条件 reboot 或脚本备份问题，见 N1/N2；未操作真实 BOOT。 |
| F10 | 已解决 | `scripts/model/nc_rxs_check.py:44-61` 的 OK/ANY 共用完整字段/比较位数检查，并拒绝重复成功记录。上一轮 wrong_mcs/no_comparison 两份原变异日志用当前 CLI 重跑均真实退出 1，问题明确指向 frame 1303。 | 追加重复 ANY 同样被拒；11 份 final_rxs02 原场景日志重放仍通过。 |
| F11 | 已解决 | `tests/rtl/ofdm_nc/tb_nc_txrx_loop.sv:109-116,177-180` 检查 ID 范围、重复和完整集合。独立复核 final_loop02 六份日志中的 26 个预期 ID，均恰好一次。 | 重复在 bad 中计数，虽 missing_or_repeated 不单独累计同一 ID 的第二次记录，最终 PASS 仍被阻止。本次没有重新启动环回 EDA。 |

### 本轮直接执行与复用的证据

| 项目 | 结果 | 证据目录或文件 |
|---|---|---|
| 当前短 SHA 身份 | 说明中 20 项匹配；审查前保存完整 SHA | `build/review_probes/rereview_host_01/source_pins.json` |
| 模型/bringup 主机测试 | 134 passed，真实退出 0，约 2.10 秒 | `build/review_probes/rereview_host_01/pytest.log`、`pytest_exit.txt` |
| 联合策略参考测试 | 21 tests，真实退出 0 | `build/review_probes/rereview_host_01/joint.log`、`joint_exit.txt` |
| 原 F2 定向 RTL 探针 | PASS，native/launcher 0，另核对 PASS 标记且无 Fatal | `build/review_probes/rereview_metric_clear_01/` |
| 原 F1 探针适配新协议 | PASS，第二次读 0，超时标志为 1 | `build/review_probes/rereview_metric_timeout_01/` |
| F1 取消边界矩阵 | 93 组 PASS：连续占用终点 60..90，各配 3 种 RREADY 释放方式；新 AR 尽早接入，核对响应归属及超时标志 | `build/review_probes/rereview_metric_edges_01/` |
| PS 失联、恢复、清理与新异常注入 | 探针真实退出 0，2,413 个断言；其中 1,100 个策略窗口比较；额外 OLLA 恢复 12 个断言 | `build/review_probes/rereview_ps_20261026_01/results.json`、`olla_recovery.json` |
| F3/F10/F11 独立核查 | 探针父退出 0；预期被拒的 F10 CLI 子进程真实退出 1 | `build/review_probes/rereview_checks_20261026_01/result.json`、`parent.json` |
| F8/F9 本机命令验证 | Bash 主探针退出 0，正/负分支结果分别保留 | `build/review_probes/rereview_docs_20261026_01/probe.log`、`assertions.json` |
| 既有长仿真复用 | final_rxs02/final_loop02/final_lean02 的 16/25/31 个 source 清单项分别全部匹配当前文件，保存的阶段退出均为 0 | 上述 rereview_checks 结果；没有将日志重放写成新执行长仿真 |

三个小型 xsim 的 `stages.json` 保存原生逐阶段退出码，`result.json` 独立保存语义判定。与上一轮不同，本轮三个结果确实均有 PASS 标记且无 Fatal，未只凭 native=0 判定通过。

## 新发现

### N1：安装失败后顺序执行代码块仍会重启

- 严重程度：中。
- 位置：`docs/innovation/stage2_board_runbook.md:45-46`。
- 问题：安装行内部的校验链已阻止错误复制，但随后打印 INSTALL_RC，再无条件执行 `sync; reboot`。实际执行完整代码块时，校验失败仍继续重启；复制中途失败时还可能带着不完整 BOOT 重启。
- 触发条件：整块顺序执行，暂存 SHA/备份 SHA 校验失败，或安装步骤返回非零。人工逐行检查并停下可避免，但代码块本身没有失败门控。
- 依据：将该原始命令的路径和 SHA 替换为本地假文件，并把 sync/reboot 替换为 mock，`F9_FULL_BLOCK_BAD_STAGE` 实际输出 `INSTALL_RC=1` 后仍出现 `MOCK_SYNC`、`MOCK_REBOOT`。见 `build/review_probes/rereview_docs_20261026_01/probe.log`。复制中途失败的后果是代码推理，未破坏真实文件或重启任何机器。
- 建议：安装结果保存为变量，只有验证成功分支才允许重启；失败保留原退出码并结束该流程。F9 的备份保护继续保留，无需推倒重做。

### N2：脚本备份步骤缺少目录准备与重入保护

- 严重程度：中。
- 位置：`docs/innovation/stage2_board_runbook.md:49`。
- 问题：`cp -p lean_adapt.py backup_before_stage2/lean_adapt_790d4af3.py` 假设目标目录已存在，且重试会覆盖同名旧脚本备份。BOOT 备份已解决，但脚本回滚副本仍有同类缺口。
- 触发条件：首次部署目录尚不存在；或更新到新 lean_adapt.py 后因回执/检查失败重做备份步骤。
- 依据：本机假文件实测缺目录时 cp 退出 1；创建目录首次成功；将工作脚本换成“新版本”后再次执行，备份 SHA 改变且内容等于新脚本。见 `build/review_probes/rereview_docs_20261026_01/script_backup_probe.log`。没有改动真实板上脚本。
- 建议：显式建立目录；旧备份已存在时只验证预期版本而不覆盖；备份成功和身份正确后再上传。阶段零已使用的非覆盖做法可作为参考。

### N3：诊断、清理日志或解冻自身失败仍可替换主异常

- 严重程度：低，异常可观测性与残留状态问题；不是 F5 原始清掩码动作再次被跳过。
- 位置：`scripts/board/lean_adapt.py:458-463,479-483`；`scripts/board/lean_nc.py:75-80`。
- 问题：独立清理动作已有 try/except，但写 cleanup_failure 未隔离；失败诊断的 core.rd/snapshot 也可能抛异常；frozen_metrics 的解冻 finally 可能遮蔽读取异常。因此“清理错误绝不隐藏原始错误”的注释仍比实现范围宽。
- 触发条件与证据：①窗口错误后衰减恢复错误，再遇 cleanup 日志写失败，顶层变为 `OSError('cleanup log write failed')`；②窗口错误后诊断读取失败，JSONL 只有 config、没有 failure；③读到 metric bit9 抛超时后，解冻写失败，failure 只记录解冻错误，0x04C 保持 0x07000000。均由主机 FakeCore/日志故障注入复现，见 `build/review_probes/rereview_ps_20261026_01/results.json` 的 cleanup_logging_failure、diagnostic_read_failure、timeout_unfreeze_failure。
- 限定：这些探针中 TX mask 都已清零，原异常仍在 Python `__context__`，不是完全丢失。诊断读取与解冻路径是既存代码，cleanup 日志分支是本轮新增；没有把全部问题归因于这次修复。正常日志条件的 timeout 主异常及清理已通过。
- 建议：诊断与清理日志作为独立尽力操作，保持首要异常的传播；对解冻失败明确记录冻结状态未恢复。日志介质本身失效时不要承诺仍能写出完整 JSONL，可保留次级错误通道。

### N4：B 设计寄存器表与实际复位/超时语义未同步

- 严重程度：低。
- 位置：`docs/innovation/b_subcarrier_mask_design.md:238,241`。
- 问题：表中 0x060 复位字仍为 0；实际 last_src=3，修复后整个字是 **0x00003000**。0x054 仍写 128 拍清零且遗漏新 bit9；实际清 384 个 RAM 字，接受 clear 的起始边沿另计，模块描述为 385 拍。
- 触发条件：按该寄存器表制定复位回读或清零/读超时处理流程。
- 依据：`rtl/ofdm_nc/rxs/ofdm_rxs_decode.v:190,326-327`、`rtl/ofdm_nc/lean/ofdm_development_core.v:409,438,442`，以及 F3 独立字段探针。现有 core 文件头和 Python 注释较新，但被审查文档仍互相矛盾。
- 建议：同步 0x060 复位字、0x054 busy/粘滞超时/写 1 清除、真实清零长度；区分已实现三库与设计中可选的 PILOT 库。

## 审查过但未发现问题的部分

- **取消与下一次读取交接**：超时边沿 t 核心置 RVALID、m_rd_cancel；t+1 度量模块收到取消，清 pending/issued 并将 rd_valid 拉低。即使 RREADY 已为 1，下一 AR 最早 t+2 握手，新 m_rd_req 最早 t+3 到度量模块，因此新请求不与取消同拍。t 或 t+1 产生的旧响应不会被新 r_wait 接走。93 组矩阵覆盖释放端口接近超时边界及响应背压，未观察到原错配或吞请求。
- **RX 复位与标志**：静态核对 core 的 rx_core_arst 使等待退出、度量模块 reset 清空 pending/issued；新接口层层透传 cancel。普通超时置 sticky bit9、写 0x054 bit9 清除，Python clear_metrics 写 0x201，read_metrics 读到 bit9 后报错。异常矩阵验证该错误进入 run 的 failure 并执行清理；若恢复衰减另失败，正常日志条件下仍保留 timeout 为主异常。并发边界未穷举，见下一节。
- **清零与在途更新**：clear 起始拍不再 take 或增加计数，随后 clearing 期间 RAM 清零优先于在途写；开始边沿即便有上一元素 write-back，之后也被对应地址清零覆盖。原精确重合探针已转绿。该动作丢弃清零窗口内的度量，不对 OFDM 接收流增加背压。
- **F3 新位域**：保留 bit11/bit15、candidate 字段和 blind_over 均与注释一致；复位 candidate=3 是“尚未接受”，所以 0x3000 合理，错误在旧文档的复位字。
- **no_viable 和 link_lost**：最长合法 worst-k 掩码规则在 2048/4096 B 以及其他边界长度合法，当前与参考一致；有可行正收益时重新走通常的迟滞比较，恢复试验没有停在 no_viable。输入反复丢失/恢复可引起规则要求的切换，未据此声称自主振荡或把新驻留机制列为必需修复。
- **异常优先级原目标**：当窗口成功且清理失败时实际抛 RuntimeError；窗口失败、清理任意失败但诊断/日志可用时保留窗口异常并记录 cleanup_failure。每个清理动作均尝试执行，包括第一项失败后的清掩码。
- **验证器修复有效性**：两份原变异日志确实被当前 CLI 拒绝，真实退出 1；普通原日志未被误拒；F11 对重复与外来 ID 累积 bad，最后检查完整集合。不是仅增加打印标记而不参与 PASS。
- **部署命令核心修复**：八条 rc 保存语句均用实际 shell 运行而非仅文本推断；BOOT 校验/备份复用/回滚校验在本地假文件上通过正反测试。NC BOOT 与两个脚本的现有主机 SHA 与手册所列一致，但未声称这些文件已在板上部署。

## 没有审查到的部分

- 未重跑 final_rxs02/final_loop02/final_lean02 三个长仿真；复用依据是源清单匹配、原始退出收据、日志/记分板重核。未重新进行整平台时序/CDC/DRC 验收；WNS +0.029 ns、WHS +0.035 ns、新 PDRC-61 等属于实现方本轮记录，仍应按其报告边界解释。
- 三个小 RTL 探针使用原 cmetric 与摘录读控制，未把完整 AXI 总线、真实 CPE 与 RX 复位组合纳入新仿真。RX reset 与 rd_valid 同拍时实现会优先返回零，而置标志条件只看 !m_rd_valid；bit9 清除与置位同拍则后面的 W1C 赋值优先。这两种优先级已从代码识别，尚未做整核影响验证，也未将其直接判作新增硬件故障。
- 未穷举所有冻结中途的在途度量快照一致性；candidate 2 动态成功接受、盲检阈值等值/极值等实现方承认的覆盖缺口仍保留。32,768 组字段算术检查不代替动态状态机覆盖。
- PS 故障注入使用假寄存器与假 IIO，不证明所有真实硬件或文件系统故障都可恢复；非法/非有限外部配置值未全面穷举。
- 命令验证使用本机 Bash，路径和 SHA 换成本地假文件，python/sync/reboot 使用 mock；未执行真实板卡 shell、挂载 SD、断电或上传。最终上板条件仍需用户确认。
- 复审没有重新扩展全项目 pytest 或历史 33 项失败调查，也没有把失败数量相同作为基线一致的证明。

本报告给出修改方向而不附产品补丁。由实现方核对 N1–N4 后决定处置；建议先收敛部署与报告层面的问题，继续复用已验证、源码未变的功能证据。
