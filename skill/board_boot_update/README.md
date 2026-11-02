# board_boot_update：保留回滚的 Zynq 开发板 BOOT 更新与短测

类型：踩坑清单 + 操作流程模板。

## 适用场景

Zynq-7000 / Zynq MPSoC 开发板通过 SD 卡上的 `BOOT.BIN` 加载新 bitstream，并且只能通过串口或网络远程操作板卡的情况。与 OFDM 无关，ZC706、ZCU102、PYNQ 类板卡都适用（只在 ZC706 上实际验证过）。

## 流程

1. **板上状态先只读**：读取当前 `BOOT.BIN` 的 SHA256、启动 ID（`/proc/sys/kernel/random/boot_id`）、外设健康状况（本项目检查 IIO 设备数、JESD 链路、SYSREF 对齐）和温度。确认没有其他测试进程在运行。
2. **只传文件，不安装**：上传新镜像到暂存路径，比对板上 SHA 与主机 SHA。
3. **安装前设置温度门槛**：温度在上升或接近自定上限时就暂停，不要"先装上再说"。
4. **先备份再替换**：把板上当前 `BOOT.BIN` 复制为带日期的备份，核对备份和新镜像两者的 SHA 后再替换。主机上的回滚镜像和黄金 SD 不动。
5. **重启后用启动 ID 和 SHA 确认版本**：启动 ID 必须变化，板上 `BOOT.BIN` 的 SHA 必须等于新镜像。不要用 PL 寄存器中的版本号判断。
6. **短测加有限恢复**：有限窗口、有限帧数，温度超限自动停止；测试结束后把 RF 置于安全状态（RX 关闭、TX 复位）。
7. **回收原始记录**：把板上原始日志拷回主机并比对 SHA，再写结论。

## 来源（BRINGUP-024 实际经过）

| 观察 | 记录 |
|---|---|
| 串口传输 318 s 后温度从 70 °C 升到 74 °C，距离自定的 75 °C 实验上限只差 1 °C；暂停了安装，加强散热后才继续 | `docs/bringup/evidence/BRINGUP-024_status_cdc_candidate/result.json`（`STAGED_ONLY_THERMAL_MARGIN_HOLD`） |
| 恢复后复用已暂存且 SHA 一致的文件，没有重新传输 | 同目录 `README.md` |
| 两个版本的 PL 寄存器 ID/版本完全相同（`0x4f464442` / `0x20261022`），只看寄存器无法区分镜像 | `docs/release/cdc_20261024/README.md` |
| 无网络 IP，只能走串口；PowerShell 上传脚本成功跑完，但 `$LASTEXITCODE` 为空 | `result.json` 的 `upload_receipt_note` |

## 已验证效果

- 候选镜像安装后启动 ID 变化、SHA 一致；随后 12 个窗口 48 帧、1,312,768 位比较零误码，回滚镜像保留在板上 `/boot/BOOT_pf6_before_cdc_20261024.BIN`（`board_result.json`）。
- 全过程没有改动主机端的黄金 SD 和回滚材料。

## 失效条件

- 75 °C 是本项目自定的保守停止点，不是器件额定值；换板卡需要重新确定。
- 如果新镜像连 Linux 都启动不了，远程无法恢复，只能人工换卡或用 JTAG。这个流程只能降低风险，替代不了现场的回滚手段。
- 板上备份与主机回滚镜像需要定期核对 SHA；本流程不覆盖 SD 卡本身损坏的情况。
