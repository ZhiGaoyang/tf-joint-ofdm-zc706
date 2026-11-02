# 上板流程、运行脚本与实测输出

板上实测所用镜像：`BOOT.BIN` SHA256 `0b3ce7eeea7f894b6f3a78f1794465933a33c3fef5b2c5e881dddede35b03e64`（VERSION 寄存器 0x20261025），PS 软件为 `src/ps/` 中的版本（`lean_adapt.py` babb3986、`lean_nc.py` 3d8b9919）。

## 上板步骤

1. **生成启动镜像**：把比特流 `system_top.bit`（`build/README.md` 第 6 步输出）与 Kuiper 镜像中的 `fsbl.elf`、`u-boot_zynq_zc706.elf` 放在同一目录，复制 `boot/zynq.bif`，执行 `bootgen -image zynq.bif -arch zynq -o BOOT.BIN`。赛方 Vivado 工程包中附有板上使用的 `boot.bin`。
2. **SD 卡**：使用 ADI Kuiper 2023_R2 Patch 1，按 ADI 说明配置为 ZC706 + ADRV9009（BOOT 分区使用 `zynq-zc706-adv7511-adrv9009/` 中的 `devicetree.dtb` 与 `uImage`），替换 BOOT 分区中的 `BOOT.BIN`（先备份原文件）。`fsbl.elf` 与 `u-boot_zynq_zc706.elf` 在同一目录的 `bootgen_sysfiles.tgz` 中。
3. **射频连接**：TX1（J303）→ 合路器 RF1；TX2（J304）→ 合路器 RF2（DDS 单音干扰源）；合路器 COM → RX1（J201）。散热风扇需远离板卡与射频线（靠近时会在接收端引入脉冲干扰，见 `measurements/s2_spikes.log`）。
4. **部署与运行**：把 `src/ps/` 下全部文件与 `scripts/demo_live.sh` 复制到板上 `/root/lean`，运行 `sh demo_live.sh`：依次演示固定 QPSK 对照、联合策略运行中开关单音、首帧前已有单音三段，终端逐窗显示单音状态、屏蔽组、调制方式、正确帧数与窗口吞吐（`ASCII=1 sh demo_live.sh` 为英文标签）。

## 目录

| 路径 | 内容 |
|---|---|
| `boot/zynq.bif`、`boot/boot_packaging.json` | 启动镜像的 bootgen 配置；板上镜像的生成记录与各组成文件 SHA256 |
| `scripts/demo_live.sh` | 三段演示脚本（与 `src/ps/demo_view.py` 配合） |
| `scripts/experiment/` | 生成正式对比实验命令文件的脚本，以及实际下发到板上的命令文件 |
| `measurements/frozen_s2_v22.json` | 正式实验运行前写入的预登记文件：判据、脚本与命令文件的 SHA256 |
| `measurements/s2_s3_run.commands`、`s2_s3_run.log` | 正式实验的串口命令与完整日志（含电平核对、仅 OFDM 长测 12,800 帧 0 误码） |
| `measurements/raw_s2s3/` | 正式实验全部运行的逐窗 JSONL 记录（无干扰衰减轨迹 `s2s3e1_*`、单音干扰 `s2s3e2_*`）；为满足命名规则，文件名已改为小写（命令文件与日志中为原始大小写，如 `s2s3e2_P22_L3_QJS_1.jsonl`） |
| `measurements/raw_demo/demo_record_20261031.tar.gz` | 演示录制运行的逐窗记录（A 固定 QPSK 对照、B 运行中开关单音、C 首帧前已有单音） |
| `measurements/s2_demo_try3.*`、`s2_record_check.log`、`s2_demo_level.log` | 演示运行、录制后核对与同条件电平检查 |
| `measurements/s2_dds_read.*`、`s2_dds_sel.*` | 上电后 DDS 设置读回：两个单音发生器默认 39.999985 MHz、幅度 0.25（16.32 MHz 档位第二单音的来源） |
| `measurements/s2_spikes.log`、`s2_noise_fanoff.log`、`s2_noise_fanon.log` | 纯底噪抓取：风扇靠近时的脉冲干扰，以及关闭/移远风扇后的对照 |

由这些原始记录复算技术文档中的数据：`python -I -B data/final_numbers.py`（参考值 `data/reference_results.json`）。日志中的构建主机名已替换为 `build-host`。
