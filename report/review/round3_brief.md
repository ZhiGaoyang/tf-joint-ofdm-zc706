> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 第三轮复审说明：N1–N4 修改是否到位

日期：2026-10-26。请求方：项目团队。实现方：Claude。
前两轮：`report/review/round1_*.md`、`report/review/round2_*.md`。本轮只针对复审报告中的新发现 N1–N4 及其修改；实现方答复见 `report/review/round2_response.md`（必读）。

规则同前：**只读**。唯一允许写入的文件是 `report/review/round3_findings.md`；探针与日志写到 `build/review_probes/round3_*` 新目录；一次只运行一个 xsim/Vivado 作业；不碰开发板、串口、SD。RTL、bitstream 与开发 BOOT 本轮未改动，无需重跑仿真或实现。

注意：实现方正在把定稿文件**复制**进 `ofdm_submission/`（打包），不会修改下表中的工作区文件；提交包中的副本不在本轮范围内。

## 1. 请回答的问题

1. 逐项判定 N1–N4：已解决 / 部分解决 / 未解决，并给出依据。建议沿用上一轮自己的探针（`build/review_probes/rereview_docs_20261026_01`、`rereview_ps_20261026_01`）对修改后的文件重跑：
   - N1：`docs/innovation/stage2_board_runbook.md` 第 3 节安装块——复制后再按完整 SHA 校验 `/boot/BOOT.BIN`；结果存入 `rc`；只有 `rc=0` 才 `sync; reboot`，否则打印 `NO_REBOOT_INSTALL_FAILED`。
   - N2：同节脚本备份块——`mkdir -p`、备份只建一次、已存在时按完整 SHA 校验不覆盖、`SCRIPT_BACKUP_RC=0` 后才允许上传。
   - N3：`scripts/board/lean_adapt.py` 的 `run()` 异常与清理段、`scripts/board/lean_nc.py` 的 `frozen_metrics()`；新增测试 `test_failed_diagnostics_do_not_replace_the_window_error`、`test_failed_cleanup_logging_does_not_replace_the_window_error`（`tests/bringup/test_lean_adapt_nc.py`）、`test_timeout_error_is_kept_when_unfreezing_also_fails`（`tests/bringup/test_lean_nc.py`）。
   - N4：`docs/innovation/b_subcarrier_mask_design.md` §4 寄存器表 0x054、0x060 两行及表后"实现说明"。
2. 修改本身是否引入新问题。重点：
   - N1：`[ "$rc" -eq 0 ] && { sync; reboot; } || echo NO_REBOOT_INSTALL_FAILED` 在 `reboot` 自身返回非 0 时会误打印 NO_REBOOT（实现方已知，认为无害），是否还有其他问题；校验失败后"先执行回滚"的指引是否会在 BOOT 未被改写时造成多余操作。
   - N3：`except BaseException` 中吞掉日志写入异常（`pass`）是否会在某些情况下掩盖不该掩盖的错误；`frozen_metrics` 读失败时解冻失败被吞掉、冻结留到下一次 `rx_cfg`——`lean_adapt.run` 的下一次运行开始时是否一定会解除冻结。
   - N4：文档中写明的两个 RTL 优先级窗口（读等待期间 RX 复位不置超时标志；置位与清除同拍时清除优先）作为已知限制、不改 RTL 的决定是否可以接受；如认为必须修改，请说明依据与风险。
3. 本轮发现的其他问题（如有），分高/中/低。

## 2. 改动记录

| 脚本 | 涉及 |
|---|---|
| `build/stage1_nc/fix_rereview_runbook.py` | N1、N2 |
| `build/stage1_nc/fix_rereview_ps.py` | N3 |
| `build/stage1_nc/fix_rereview_docs.py` | N4；运行手册中的脚本 SHA；第一方文档中审查者称谓改为"独立审查者"（文件名与证据路径不变） |

另有直接追加的测试（见第 1 节）。

## 3. 复审对象（当前 SHA256 前 16 位）

| 文件 | SHA |
|---|---|
| `docs/innovation/stage2_board_runbook.md` | `2223c6a58a67c846` |
| `scripts/board/lean_adapt.py` | `4055c2446c966cbc` |
| `scripts/board/lean_nc.py` | `a746ee8aae748bfb` |
| `tests/bringup/test_lean_adapt_nc.py` | `0bc48ed0be7a12f2` |
| `tests/bringup/test_lean_nc.py` | `a3492ed26e523462` |
| `docs/innovation/b_subcarrier_mask_design.md` | `05a17d320dfc60db` |
| `report/review/round2_response.md` | `c0e1cbf403205182` |

## 4. 实现方已有的验证

- `python -B -m pytest -q -p no:cacheprovider tests/ofdm_nc tests/bringup`：137 通过；`python -B build/innovation_joint/test_joint_policy.py`：21 通过。
- N3 的 3 个新测试在修改前均失败（实现方本地），修改后通过。
- 两个板上脚本的 Python 3.9 语法检查通过。

## 5. 输出格式

写入 `report/review/round3_findings.md`：N1–N4 判定表（编号 / 判定 / 依据 / 备注）；新发现（M1、M2…，字段同前）；审查过但未发现问题的部分；没有审查到的部分。
