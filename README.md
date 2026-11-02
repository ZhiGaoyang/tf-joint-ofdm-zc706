# 时频联合自适应 OFDM 收发系统（tf-joint-ofdm-zc706）

ZC706（XC7Z045）+ ADRV9009 上的 122.88 MSPS OFDM 实时收发系统。收发物理层在 PL 内以 200 MHz 流式运行（128 点 FFT、32 点 CP、88 个数据子载波分 11 组、QPSK/16QAM）；PL 在正常通信中逐子载波统计判决误差，PS 每个测量窗口联合选择调制方式与屏蔽的子载波组（最多 3 组），掩码随帧头发送、由接收端盲识别，首帧前由发射前频谱感知设定初始掩码。

技术文档：`report/design_report.pdf`。

## 主要结果（板上实测，单板有线射频环回）

| 项目 | 结果 | 证据 |
|---|---|---|
| 整平台时序 / 资源 | WNS +0.029 ns，WHS +0.035 ns，TNS 0；72,729 LUT，176 DSP | `build/reports/platform_impl/` |
| 无干扰长测 | 12,800 帧 × 4096 B，419,430,400 比较位 0 误码 | `board/measurements/s2_s3_run.log` |
| 单音干扰（21.6 MHz，未参与策略设计，JSR −26 至 −6 dB） | 不屏蔽的固定 QPSK 有 4 档丢帧 77%–100%；本系统 5 档误包率 ≤0.83%（上述 4 档 ≤0.1%），窗口吞吐 48–62 Mbit/s | `board/measurements/raw_s2s3/` |
| 干扰反应 | 单音出现后 1 个窗口（约 4 ms）内完成屏蔽并恢复，消失后 3 个窗口解除 | `board/measurements/raw_demo/` |
| 可复现性 | 从源码重建（加上随赛方工程包提供的 FFT 网表与平台壳），比特流配置数据与板上镜像逐字节相同 | `build/reports/rebuild_verification_20261102/` |

全部对比实验在运行前写入预登记文件（`board/measurements/frozen_s2_v22.json`），其中两项判据未满足（首窗 ≥15/16 帧、感知耗时 ≤0.30 s），如实记录在技术文档“板上单音干扰实验”一节。技术文档中的板上数据可由 `python -I -B data/final_numbers.py` 从原始记录复算，参考值见 `data/reference_results.json`。

## 目录结构

按赛题指南 3.3.5.4 的推荐结构组织，目录与文件名均为小写英文：

```
tf-joint-ofdm-zc706/
├── README.md       # 项目简介 + 复现步骤（本文件）
├── src/            # 设计源码：rtl/（Verilog RTL）、ps/（PS 侧 Python 软件）、platform/（板级顶层、约束、BD 种子）、ip/（FFT/IFFT 配置）
├── sim/            # 仿真与验证：测试台、仿真脚本、Python 黄金模型、主机测试、联合策略参考实现、仿真结果
├── build/          # 可复现的构建脚本 + 综合与实现报告（reports/）
├── board/          # 上板流程（boot/）、运行脚本（scripts/）与实测输出（measurements/）
├── data/           # 测试数据与参考结果：技术文档数据的复算脚本与参考值、模型扫描数据
├── skill/          # 技能包
│   └── README.md
└── report/         # 设计报告（PDF）+ 大模型协作与独立审查记录（review/）
```

根目录另有 `license.txt`（MIT）、`third_party_notice.md`（第三方组件与未随仓库分发的文件）、`.gitignore`、`.gitattributes`（所有文件按原字节保存，构建脚本与证据中的 SHA256 校验依赖原字节）。各目录的 `README.md` 说明其内容与用法。

## 环境

- Vivado 2023.2（所有 Tcl 入口检查版本）。ADI HDL 的 `hdl_2023_r2` 分支与 Kuiper 2023_R2 镜像是官方配套验证组合，平台 IP 按 2023.2 打包。XC7Z045 需要 Vivado Enterprise 或 ZC706 套件附带的器件许可。
- Python 3.11 及以上（主机测试需 pytest、numpy）；Windows 11 上验证，其他系统未验证。
- 运行目录不能含空格；每一步的输出目录必须不存在；一次只运行一个 Vivado 任务（整平台实现峰值约 6.6 GB 内存）。

## 复现步骤

1. **主机测试与数据复算**（不需要 EDA）：

   ```powershell
   cd sim; python -B -m pytest -q; python -B reference/innovation_joint/test_joint_policy.py; python -I -B scripts/rtl/gen_nc_map.py --check; cd ..
   python -I -B data/final_numbers.py
   ```

2. **仿真**：见 `sim/README.md`（需先按 `src/ip/README.md` 放入 FFT/IFFT 行为模型）。
3. **Vivado 构建**：见 `build/README.md`。核心综合约 3 分钟，整平台实现约 13 分钟；平台壳可从 ADI 官方源码重建（约 1 小时），或使用随赛方 Vivado 工程包提供的版本。预期 WNS +0.029 ns、72,729 LUT、176 DSP。
4. **上板**：见 `board/README.md`（生成 `BOOT.BIN`、SD 卡、射频连接、运行演示）。

## 限制

单板有线射频环回、收发共用本振、内置 PRBS 载荷；物理层未含前向纠错编码；干扰验证限于 DDS 单音与 JSR −27 至 −6 dB，JSR 约 −1 dB 时检测失效；整平台建立时间裕量 0.029 ns。详见技术文档“已知限制与适用范围”一节。

## 许可证

第一方代码采用 MIT 许可证（`license.txt`）。第三方组件与未随仓库分发的文件见 `third_party_notice.md`。
