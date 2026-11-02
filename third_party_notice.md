# 第三方组件说明

本文件说明本仓库涉及的第三方材料及其处理方式，不是法律意见。第一方材料（`src/rtl/`、`src/ps/`、`build/`、`sim/`、`board/`、`data/` 中的自写文件，以及 `skill/`、`report/`）采用 MIT 许可证，见 `license.txt`。

## ADI HDL 平台（Analog Devices）

- 来源：https://github.com/analogdevicesinc/hdl ，分支 hdl_2023_r2-kuiper-p1，提交 2156ac7e874a1dc321d9f64a325009fafe563419，未修改。本仓库不复制 ADI 源码，构建时按该提交获取（见 `build/README.md`）。
- `src/platform/` 中的板级顶层、约束与 BD 种子取自上述 ADI 参考设计（`projects/adrv9009/zc706`），并加入了第一方边界模块；ADI 许可证原文保留在 `src/platform/licenses/`。
- 各 ADI 模块按其源文件头部声明授权：JESD204 链路层核心为 ADIJESD204 许可证（GPLv2，另有商业许可），其余平台组件为 ADIBSD 或 GPLv2 二选一。分发含 JESD204 核心的比特流或启动镜像时，须按 GPLv2 提供整个工程的源码；本作品第一方源码采用与 GPLv2 兼容的 MIT 许可证。
- 致谢：The design and implementation of the JESD204 HDL Core used in this project is copyright (c) 2016-2023, Analog Devices, Inc.

## AMD/Xilinx

- `src/ip/` 只含 Fast Fourier Transform v9.1 的 IP 配置（`.xci`）与第一方接口桩；由 Vivado 生成的网表与仿真模型不在本仓库中，获取方式见 `src/ip/README.md`。
- 平台中的 MIG、AXI 互连、DMA、FIR 等 IP 由构建脚本在使用者本地用其 Vivado 生成；XPM 库由 Vivado 安装提供。

## 不随本仓库分发的二进制

平台壳检查点、布线检查点、比特流、启动镜像 `BOOT.BIN` 以及 FSBL/U-Boot（取自 ADI Kuiper 2023_R2 Patch 1 镜像 `zynq-zc706-adv7511-adrv9009/bootgen_sysfiles.tgz`，U-Boot 为 GPL-2.0，源码见 https://github.com/analogdevicesinc/u-boot ）不放入公开仓库；它们随提交给赛方的 Vivado 工程包提供，启动镜像各组成文件的 SHA256 见 `board/boot/boot_packaging.json`。
