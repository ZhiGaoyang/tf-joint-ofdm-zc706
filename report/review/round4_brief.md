> 提交包副本：由开发工作区的原始审查记录转换，只改文件名、审查者称谓与路径；`build/review_probes/` 指工作区内的审查探针，未随包提供。

# 第四轮复审说明：M1–M3 修改是否到位

日期：2026-10-26。请求方：项目团队。实现方：Claude。
前三轮：`report/review/round1_*.md`、`report/review/round2_*.md`、`report/review/round3_*.md`。本轮只针对第三轮报告中的 M1–M3、两条附带建议（N1 重启分支、N3 注释）及其修改；实现方答复见 `report/review/round3_response.md`（必读）。

规则同前：**只读**。唯一允许写入的文件是 `report/review/round4_findings.md`；探针与日志写到 `build/review_probes/round4_*` 新目录；不碰开发板、串口、SD。RTL、bitstream 与开发 BOOT（`0b3ce7ee…`）未改动，本轮不需要运行仿真、综合或实现。提交包 `ofdm_submission/` 中的副本不在范围内。

## 1. 请回答的问题

1. 逐项判定 M1–M3：已解决 / 部分解决 / 未解决，并给出依据。建议沿用第三轮的探针（`build/review_probes/round3_host_02` 的 `shell_results.json`、`ps_results.json` 对应场景）对修改后的文件重跑：
   - M1：`docs/innovation/stage2_board_runbook.md` 第 3 节脚本备份块（第 57 行）——子 shell 内 `cd && mkdir -p && S="…" && { [ -e "$S" ] || cp -p …; } && sha256sum -c`，整体返回值存入 `rc` 后打印 `SCRIPT_BACKUP_RC`。请至少重跑 `script_cd_fail`、`script_mkdir_fail_stale_S`，以及首次、重试不覆盖、坏备份三个正常/异常场景。
   - M2：`docs/innovation/b_subcarrier_mask_design.md` §4 表后"实现说明"（第 252 行），对照 `rtl/ofdm_nc/lean/ofdm_development_core.v` 第 71、226、380–385、409 行；以及运行手册第 1 节新增的"度量读取前提"（第 24 行）是否与第三轮"有条件接受"的前提一致。
   - M3：`scripts/board/lean_adapt.py` `main()`（第 317–327 行）；新增测试 `test_cli_log_close_failure_does_not_replace_the_run_error`、`test_cli_log_close_failure_after_success_is_still_an_error`（`tests/bringup/test_lean_adapt_nc.py` 末尾）。
2. 附带建议：
   - N1：安装块第 49 行改为 `if [ "$rc" -eq 0 ]; then sync; reboot || echo REBOOT_CMD_FAILED_INSTALL_OK; else echo NO_REBOOT_INSTALL_FAILED; fi`；第 46 行 `$B` 加了引号（固定字面量，行为不变）。
   - N3：`scripts/board/lean_nc.py` 第 80–81 行注释。
3. 修改本身是否引入新问题。重点：
   - M1：子 shell 不改变调用者的当前目录，之后的上传步骤使用绝对路径（`/root/lean/…`）是否足够；`ls -l` 确认行是否有误导。
   - M3：`except BaseException` 中先尝试 close、close 失败只写 stderr 后 `raise` 原异常；stderr 写入本身失败的情形（如 stderr 已关闭）会怎样，是否需要处理；`KeyboardInterrupt`/`SystemExit` 作为主异常时行为是否符合预期。
4. 本轮发现的其他问题（如有），分高/中/低。

## 2. 改动记录

| 来源 | 涉及 |
|---|---|
| `build/stage1_nc/fix_round3_docs.py` | M1、M2、N1 分支、运行手册度量读取前提、N3 注释 |
| 直接编辑 | M3（`lean_adapt.py` 的 `main()` 与新增 `import sys`）；运行手册第 37 行脚本 SHA；第 46 行 `$B` 引号；M3 两个测试 |

## 3. 复审对象（当前 SHA256 前 16 位）

| 文件 | SHA |
|---|---|
| `docs/innovation/stage2_board_runbook.md` | `a14d0e45cf551951` |
| `docs/innovation/b_subcarrier_mask_design.md` | `288eedc988e0c168` |
| `scripts/board/lean_adapt.py` | `4b377ee411043aac` |
| `scripts/board/lean_nc.py` | `ddb9a0b96c3dfc4e` |
| `tests/bringup/test_lean_adapt_nc.py` | `6bc18ab5e9073412` |
| `report/review/round3_response.md` | `671d448fad255196` |

## 4. 实现方已有的验证

- `python -B -m pytest -q -p no:cacheprovider tests/ofdm_nc tests/bringup`：139 通过；`python -B build/innovation_joint/test_joint_policy.py`：OK。
- M3 第一个新测试修改前失败（最终异常为 `OSError('close flush failed')`）、修改后通过；第二个测试修改前后均通过（防止成功路径吞掉 close 错误）。
- M1 条件链在本机临时目录替换路径后实测：首次 0、重试 0 且旧备份不变、cd 失败 1、mkdir 失败且预存 `S=elsewhere.py` 1、坏备份 1。N1 分支用模拟 reboot 验证：reboot 失败打印 `REBOOT_CMD_FAILED_INSTALL_OK`，rc 非 0 打印 `NO_REBOOT_INSTALL_FAILED`。
- 第 46 行 `$B` 加引号后未在本机重跑 shell 探针（本机安全软件拦截了该次本地 shell 模拟），请审查者覆盖。

## 5. 输出格式

写入 `report/review/round4_findings.md`：M1–M3 及两条附带建议的判定表（编号 / 判定 / 依据 / 备注）；新发现（P1、P2…，字段同前）；审查过但未发现问题的部分；没有审查到的部分。
