# vivado_bd_state_check：用落盘的 BD/XCI 配置判断 Block Design 是否被改变

类型：校验脚本 + 踩坑清单。脚本：`compare_bd_state.py`（与 `build/compare_bd_state.py` 为同一文件），只用 Python 3.11 标准库，不调用 Vivado。

## 适用场景

复制、迁移或在新机器上重建 Vivado IP Integrator 工程后，需要确认 IP 配置、端口、地址映射没有被工具悄悄改掉，例如重新生成输出产物、升级 IP 仓库路径、交给别人复现之前。适用于任意 BD 工程，与 OFDM 无关。

## 踩坑：不要用新会话中的 `get_property` 字符串做门禁

本项目最初在 Tcl 里把所有 `CONFIG.*` 属性读成字符串，与已验收的快照逐字比较。在新的 Vivado 会话里，同一个配置会被读成不同的字符串：

| 读回差异 | 实际情况 |
|---|---|
| `FREQ_HZ 100000000` → `1e+08` | 新会话执行 `validate_bd_design` 后，以 `%g` 形式输出同一数值 |
| `PCW_S_AXI_HP0_FREQMHZ 100` → `100.0` | 同上 |
| `PCW_FTM_CTI_IN0 DISABLED` → `<Select>` | 读回的是已禁用参数（`enabled:false`）的占位值 |

两次运行（`platform_outputs01` attempt01/retry02）都因此在生成之前退出 1，真实配置并没有变化。此外，第一次运行时 Vivado 已经改写了复制来的工程：删除了 19 个互连内部子 IP 的 XCI，把 15 个 module-reference XCI 写回了未传播的状态。第二次运行沿用这个工程，等于没有在干净副本上重试。

## 用法

1. 从已验收的工程复制一份新副本，只复制 `.xpr` 和 `.srcs`。每次运行都用新目录，失败的目录不要重复使用。
2. 在 Vivado 中完成 `validate_bd_design`、`generate_target all`、`save_bd_design`。
3. 用落盘文件做门禁：

   ```powershell
   python -B compare_bd_state.py --reference <accepted_project> --candidate <new_project> --out <fresh>.json
   # exit 0 = PASS, 1 = FAIL；报告中逐条列出失败项和各类备注
   ```

规则：IP 集合、VLNV/版本、全部参数的 `value` 和 `enabled`、端口宽度/方向、整个 BD JSON（连接、地址）必须一致。以下几类只记为备注，并在报告中逐条列出：

- 两边都是普通十进制数、且精确相等（`1e+08` 与 `100000000`）；十六进制等其他字符串仍要求逐字相同；
- 同一个值旁边的簿记字段（`resolve_type`、`value_src` 等）；
- 两边都是 `enabled:false` 的参数取值变化（model 参数仍严格比较）；
- BD 中只在一侧出现、且值等于参考 XCI 落盘值的组件参数。

最后两条规则是在看到 `platform_outputs02` 的失败之后才加上的。加规则之前先做了硬件层面的核对，见下文；首次 FAIL 的报告保留在 `evidence/reproduction/platform_outputs02_state_v1_fail.json`。

## 已验证效果

| 检查对象 | 结果 |
|---|---|
| 已验收工程与自身比较 | PASS，131/131 个 XCI |
| 被 Vivado 改写过的 outputs01 副本 | FAIL，33 项：19 个 XCI 缺失；module-ref 的 `CLK_DOMAIN` 为空，`ofdm_core` AXIS 的 `FREQ_HZ` 从 200 MHz 退回到 100 MHz |
| outputs02 完整生成后（新规则） | PASS：196 处数值写法、8 个禁用参数、290 个 BD 回显参数，全部单独列出 |
| 25 项单元测试 | 通过，其中包括 1 Hz 频率变化、枚举变化、`enabled` 变化、十六进制、缺 IP、端口宽度、地址偏移等负例 |

对那 8 个禁用参数的硬件核对：本次生成的 `ps7_init.c/.h/.tcl`、`ps7_init_gpl.*` 与历史上已上板平台的生成结果逐字节相同；PS7 综合封装只在属性注释中的 `FREQ_HZ` 写法和续行位置上不同；XDC 约束行集合相同（`evidence/reproduction/platform_outputs02_ps7_vs_physical02.json`）。

## 失效条件

- 只在 Vivado 2023.2 的 JSON 格式 XCI（`xilinx.com:schema:json_instance:1.0`）和 JSON 格式 `system.bd` 上验证过；旧版 XML 格式 XCI 不支持。
- 它比较的是配置，不是网表。配置一致不代表综合结果完全一致，后者仍需看综合/实现报告。
- 禁用参数规则依赖 Vivado"禁用参数不参与生成"这一行为。本项目只对 PS7 的 FTM_CTI 做过硬件核对；遇到其他 IP 的 `disabled_param` 备注时，应同样检查生成产物。
- 位置字段只按名字忽略（`gen_directory`、`OUTPUTDIR`、`SHAREDDIR`）。如果工具版本新增了其他路径字段，会被当作失败报出来，需要人工判断，不要直接加白名单。
