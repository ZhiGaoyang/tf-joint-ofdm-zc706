# Platform Source Preparation

状态：源文件和 10 处资产路径已整理；**platform_bd09 已在新目录通过 Vivado BD 装配、验证、保存及强制重开检查，保留工具注记。核心暂用接口占位模块；未启动 IP 输出生成、综合、布局或布线。**

## Contents

- `inputs/`：实际板级顶层、辅助模块、已验收边界模块、四份 XDC、ROM／FIR／MIG 数据文件。共享 FIR 约束与原官方文件一致。
- `seed/system.bd`：原 physical02 的输入 BD，不是当前候选运行拓扑。保留原始内容以供明确迁移，禁止把它直接称为当前上板工程。
- `seed/legacy_core_stub.v`：原 shell 综合的核心接口占位文件，后续需要核对当前核心端口，不是 OFDM 实现。
- `seed/legacy_boundary.v`：旧边界版本，仅用于来源对照，不加入新平台源文件。
- `inputs_inventory.json`：131 个叶组件记录，其中 15 个 module reference、116 个 vendor IP；记录 10 个资产字段及确切 TX 时钟网。
- `licenses/`：保留的原 ADI 许可证文本，不是整个提交树的统一许可或全部 IP 的再分发批准。

## Local Preparation

```powershell
$root = (Resolve-Path '.').Path   # repository root
python -B "$root/build/stage_platform_inputs.py" --root "$root/src" --out "$root/work/platform_inputs01"
if ($LASTEXITCODE -ne 0) { throw 'Platform input preparation failed' }
```

此命令只复制输入并更改清单中已列出的文件路径，要求输出目录不存在；不调用 Vivado。已在维护工程的独立 `build/submission_repro_20261024/platform_inputs01` 运行通过。原种子文件不变，暂存 BD 的其余 JSON 数据与原件一致。

## Required Native Steps

1. 以固定 ADI 库和 Vivado 2023.2 创建独立平台项目；原历史 IP 缓存不作为隐式依赖。
2. 更新 module reference，核对当前核心接口及地址不变。匹配当前已验收边界源码，新增 `tx_clk` 并接到已有 `ofdm_core/tx_clk` 所属的 `adrv9009_tx_device_clk` 网。
3. 将原种子的 `DEV_TX_ENABLE=0` 设置为已验收开发镜像使用的 `1`。这不是新增运行模式，而是还原原流程中由 Tcl 执行的配置步骤。
4. 保留全部板级约束及 XPM scoped 约束；先验证 BD、保存并重新打开核对，再预算 IP 生成、综合和最终实现。

初始 `platform_inputs01` 暂存状态为 `PLATFORM_INPUTS_LOCALIZED_NOT_BD_VALIDATED`。后续独立项目已更新 module reference 和边界连接，当前结果见下文；不要把初始种子或后续局部验证直接当作整平台综合通过。

## BD-Only Entry

`build/run_platform_bd.ps1` provides an explicit, fresh-project entry. The
accepted current core header matches the historical shell stub, including
interface attributes, after ignoring whitespace and output storage type.
The stub is intentionally used here: this stage checks platform wiring, not
the implementation of the OFDM core.

```powershell
$root = (Resolve-Path '.').Path   # repository root
$staged = "$root/work/platform_inputs01"
$work = "$root/work/platform_bd01"
$library = "$root/work/adi_library01/source/library" # Complete packaging first.
# Set VIVADO_HOME and ADI_HDL_ROOT explicitly for this machine.
& "$root/build/run_platform_bd.ps1" -VivadoHome $env:VIVADO_HOME `
  -AdiRoot $env:ADI_HDL_ROOT -AdiLibrary $library `
  -Staged $staged -Work $work -PreflightOnly
if ($LASTEXITCODE -ne 0) { throw 'BD preflight failed' }
# After reviewing resources, omit -PreflightOnly to run Vivado.
```

The runner checks the pinned ADI commit and tracked source state, staged input
identities, and core header before launching. It disables the IP synthesis
cache, refreshes the two module references, restores DEV_TX_ENABLE=1, connects
the boundary TX clock to the existing core TX clock net, and compares existing
connections, user port shapes and address segments across propagation. It then
requires all effective cell/bus configuration and connected-pin widths to
reach a fixed point and match after forced reopening. Unconnected vendor query
members are not treated as physical ports. Snapshots are detached from native
Vivado object handles before later propagation.
`AdiRoot` verifies the pinned source checkout; `AdiLibrary` selects the actual
catalog. When specified, a missing library is an error, not a fallback to
`AdiRoot/library`. Native checks require an exclusive project repository and
each ADI definition XML inside the selected library before and after reopening.
Without `AdiLibrary`, the older explicit-checkout library mode remains supported.
The existing four XDC inputs and XPM library selection are retained; synthesis
and routed scoped-constraint effectiveness are later checks.

Budget basis: historical BD open 157 seconds, first validation 124 seconds,
peak 1.6 GiB. Allow 6-10 minutes and at least 2.5 GiB free for this BD-only
operation. This is not the larger memory budget for synthesis or routing.
The script rejects existing output directories and another running EDA process.
Native logs and true native/parent exits remain in the selected work directory.
No IP generation, synthesis, place, route or board command is dispatched.

## Preserved Native Failures

- `platform_bd05`: first forced validation and save succeeded, but the subsequent
  full reopen comparison failed. Parent/native exits are both 1.
- `platform_bd06`: reused that saved project in a separate directory, forced
  validation after reopening, then failed the full snapshot comparison again.
  Parent/native exits are both 1; this is not a completed reproduction.
- All 1,570 stable connection/address/user-interface rows match. All 837 common
  component parameters match the historical validated BD except the 10 intended
  asset paths; no component parameters were added or removed.
- DEV_TX_ENABLE is 1 and the new boundary TX clock joins the existing core TX net.
- Remaining differences include 14 added and 1,157 removed unconnected vendor
  interface-member query objects, plus five address pins changing from 32 to 30
  bits under `axi_hp0_interconnect/s00_couplers`. S00 is connected to
  `axi_hdmi_dma/m_src_axi`, not the OFDM core. Historical corresponding FIFO and
  protocol-converter XCI files specify 32 bits. Whether the difference is solely
  native query/propagation state or affects generated products remains open.
- Next action is limited to this HDMI DMA to HP0 address-width propagation and
  its generated-IP configuration. Do not modify OFDM RTL, relax the comparison,
  or launch whole-platform synthesis to hide this difference.

Earlier failures are retained: Windows path handling in Tcl glob, native cache
permission value `disable` versus the documentation's `disabled`, and comparing
unresolved vendor pins to propagated pins. These are historical results; the
current fresh-directory entry is recorded below.
Selected original logs/results and the actual remaining delta are under
`evidence/reproduction/`; full generated projects stay outside the submission.

## Current Native Result

`platform_bd09`: parent/native exits 0/0, 346.45 seconds, status
`BD_CONTRACT_VALIDATE_REOPEN_PASS_WITH_NOTES`. The 1,570 stable connection rows
match exactly; the 16,637-row effective contract matches across consecutive
forced validations and after save/reopen. The IP status report lists 110 IP,
all Up-to-date. Eleven targeted host tests pass. This does not establish IP
output generation, license clearance, synthesis or routed timing acceptance.

ADI DMA post-propagation derives 30 address bits from its zero-offset 1 GiB
HP0 mapping. The historical DMA already emitted 30 bits; historical system HDL
padded two zeros into the old 32-bit converter. Fresh propagation also changes
the downstream FIFO/converter configuration to 30 bits. This real configuration
change remains subject to generated-product checks, not assumed netlist or
hardware equivalence. See `bd_address_root_cause.json` and `bd09_result_summary.json`
under `evidence/reproduction/`. Actual IP/bus configuration or connected-width
changes after stabilization still cause the entry to fail.

## Selected Generated Outputs

The HDMI DMA and its HP0 FIFO/protocol converter were generated in an isolated
standalone project from copied BD09 XCI files (`platform_ip_width02`, native and
parent 0/0, 23.65 seconds). All five relevant generated read-address ports are
30 bits, and the instance address parameters are 30. Original accepted XCI and
BD files are unchanged. This resolves the selected generated-width question;
it is not full-platform synthesis or netlist/hardware equivalence.

The first output-generation attempt escaped its selected directory due to an
additional XCI runtime `OUTPUTDIR` field. Its native exits remain 0/0 but its
scope check is FAIL. The successful attempt localizes both output-path fields
and checks effective output directories before generation. Full output trees
remain outside the submission; selected logs and results are retained under
`evidence/reproduction/`. Full BD generation is still pending.

## Clean ADI Library Recipe

The new entry exports tracked sources from the pinned ADI checkout, excluding
its local generated packages. It does not rebuild the official board project.

```powershell
$root = (Resolve-Path '.').Path   # repository root
$work = "$root/work/adi_library01"  # Must not already exist.
python -B "$root/build/prepare_adi_library.py" --adi-root $env:ADI_HDL_ROOT --out $work
if ($LASTEXITCODE -ne 0) { throw 'Clean ADI source preparation failed' }
$plan = Get-Content "$work/plan.json" -Raw | ConvertFrom-Json
$pilot = @('interfaces','jesd204/interfaces','util_cdc','util_axis_fifo','axi_dmac')
$vivado = Join-Path $env:VIVADO_HOME 'bin/vivado.bat'
# Check Vivado 2023.2, >=2.5 GiB free and no other EDA process before launch.
# Allow 3-6 minutes for the pilot; measured maintenance run was 82.51 seconds.
Push-Location $work
try {
    & $vivado -mode batch -source "$root/build/package_adi_library.tcl" `
      -log "$work/pilot.log" -journal "$work/pilot.jou" `
      -tclargs "$work/source" "$work/pilot" @pilot
    if ($LASTEXITCODE -ne 0) { throw 'ADI packaging pilot failed' }
} finally { Pop-Location }
$remaining = @($plan.order | Where-Object { $_ -notin $pilot })
# After pilot verification and resource review, reuse these outputs and pass
# @remaining with a new receipt directory to the same Tcl. Do not repeat @pilot.
```

This Tcl packages explicit paths, checks expected artifacts and rejects existing
component.xml outputs instead of overwriting them. Keep true native exits and
logs when running. The maintained source export has a recovered plan after a
preserved Intel/Xilinx-name selection failure. Its five-step pilot passed. The
remaining 18 steps were initially blocked before launch by the memory gate,
then completed after memory recovered: native/parent 0/0, 343.21 seconds. The
23 required steps total 425.72 seconds and produce 21 component packages plus
two interface sets. All package file and ADI subcore references resolve. This
is packaging completion for this platform's ADI dependencies, not full-library
BD binding, BD output generation or synthesis acceptance.

Next bind the independent BD explicitly to this exported `source/library` path.
Do not silently keep the old checkout library as a catalog fallback. Verify
the new catalog/BD binding, then measure costly representative generators
before a full BD-output batch.

## Clean-Library BD Binding Accepted

The fresh `platform_bd10` entry used explicit `AdiLibrary` pointing only to the
new tracked-source export. Parent/native exits are 0/0, 286.64 seconds. Before
validation and after save/reopen, all 17 ADI component types used by the BD
resolve to definition XML within that library, and those XML files match the
accepted packaging hashes. No old checkout-library fallback was selected.

The complete effective contract and stable connection records are byte-identical
to the previous accepted `platform_bd09` result. A preliminary real catalog
check also resolved all 21 exported component packages, native exit0/15.36s.
The 16 affected runner/helper tests pass, including missing-library, external
definition and extra-old-repository negatives. Original host failures remain.

This accepts clean-library BD assembly/validation/save/reopen with notes only.
The core is still an interface stub; no new IP products, synthesis, routed timing
or hardware acceptance is granted. See `bd10_result_summary.json` and retained
native logs under `evidence/reproduction/`. The next step remains expensive
representative FIR/JESD/MIG generation before budgeting the full output batch.
