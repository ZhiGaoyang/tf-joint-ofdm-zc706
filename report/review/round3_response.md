> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 对第三轮复审 M1–M3 的答复

日期：2026-10-26。复审报告：`report/review/round3_findings.md`（N1、N3 已解决，N2、N4 部分解决；新增 3 项低）。实现方：Claude。处理方式同前两轮：脚本类先写失败的测试，文档类按复审实测场景在本地替换路径后复现。

| 编号 | 结论 | 处理 | 验证 |
|---|---|---|---|
| M1 备份准备失败可能误报 `SCRIPT_BACKUP_RC=0`（低） | 成立 | `docs/innovation/stage2_board_runbook.md` 脚本备份块改为一个子 shell 内的完整条件链：`cd /root/lean && mkdir -p … && S="…"（固定目标）&& { [ -e "$S" ] \|\| cp -p …; } && sha256sum -c`，变量加引号，整体返回值存入 `rc` 后打印；随后 `ls -l` 绝对路径确认备份位置 | 本地临时目录替换路径后实测：首次 0、重试（新脚本不覆盖旧备份）0、cd 失败 1、mkdir 失败且 shell 预存 `S=elsewhere.py` 1、坏备份 1 |
| M2 复位窗口描述过宽（低） | 成立 | `docs/innovation/b_subcarrier_mask_design.md` §4 实现说明改为精确条件：r_wait 中 `rx_core_arst` 与 `m_rd_valid` 同拍有效时数据置 0 但 bit9 不新置位（原值保持）；只有复位无响应时照常置位。区分"源码判读确认的 RTL 语义"与"未测量的硬件发生率"；写明 `rf_tx_arst`/`rf_rx_arst` 可异步到来、"RX 正在运行"不能排除该窗口；写入使用前提与残余风险，以及何种验收要求下必须改 RTL | 文本复核，对照 `rtl/ofdm_nc/lean/ofdm_development_core.v:71、226、380–385、409` |
| M3 `main()` 关闭日志失败覆盖主异常（低） | 成立 | `scripts/board/lean_adapt.py` `main()`：`run()` 抛出时，`log.close()` 失败只打印到 stderr，重新抛出原异常；正常完成时 `close()` 的错误照常传播（不隐藏落盘失败） | 新增 2 个测试：主异常保留（修复前失败、修复后通过）；成功路径 close 失败仍抛 `OSError`（修复前后均通过，防止过度吞错）。`tests/bringup` + `tests/ofdm_nc` 139 项、联合策略参考实现测试通过 |

复审的两条附带建议也已处理：

- N1 后续：安装块的重启改为显式 `if` 分支，安装失败打印 `NO_REBOOT_INSTALL_FAILED`，重启命令本身失败打印 `REBOOT_CMD_FAILED_INSTALL_OK`；手册注明判定安装只看 `INSTALL_RC`。本地用模拟 reboot 验证两个分支。
- 一致性：安装块中 CDC 备份路径变量 `$B` 也加了引号（目标是固定字面量，行为不变）。
- N3 注释：`scripts/board/lean_nc.py` `frozen_metrics` 的说明收紧为"冻结在下一次 NC 运行进入窗口准备并成功写 `rx_cfg(freeze=False)` 时解除"。

两个 RTL 窗口按复审的有条件接受处理：不改 RTL、不重开 EDA；运行手册第 1 节通用规则新增度量读取前提（单控制者、串行、读取期间不切换 RX/不复位/不并发清标志；已知复位或 RF/JESD 重新初始化的窗口作废重采），结论中不宣称自动故障检测已闭合。

板上脚本新 SHA：`lean_adapt.py` `4b377ee4…`，`lean_nc.py` `ddb9a0b9…`（运行手册已同步）。RTL、bitstream 与开发 BOOT（`0b3ce7ee…`）未变，不需要重跑 PHY 回归或实现。
