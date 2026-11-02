# vivado_bram_template：块 RAM 没有被推断出来时的识别与改写

类型：踩坑记录 + 代码模板。

## 适用场景

用 Verilog 写读改写（统计、直方图、累加器阵列）或带多个访问来源的存储器，希望映射到块 RAM 的任何 Xilinx 7 系列 / UltraScale 设计。

## 现象与来源

| 现象 | 本项目中的实际记录 |
|---|---|
| 写了 `(* ram_style = "block" *)`，综合仍改用 LUTRAM，资源比预估多出约 1,270 LUT | `build/ofdm_nc/core_synth01.log`：`WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" set for RAM ".../cmetric/mem_reg", trying to implement using LUTRAM`；层次报告中该模块 1,746 LUT（其中 1,056 LUTRAM） |
| 原因：读端口在 `if / else if` 中按两个不同来源选择地址，写端口也在同一个 always 中按条件选择地址和数据，综合器没有识别为简单双口 RAM | `build/stage1_nc/ofdm_rxs_cmetric_v1_lutram.v`（改写前的版本） |
| 改写为"写口、读口各自用独立的地址/数据/使能信号"后，映射为 1 个 RAMB18，模块降为 475 LUT | `build/ofdm_nc/core_synth02`；功能用同一组随机向量验证不变 |

## 用法

1. 综合后检查日志中是否有 `Synth 8-6849 Infeasible attribute ram_style`，以及层次报告里该模块的 LUTRAM 数。不要只看总资源。
2. 存储器访问改成下面的模板：先用组合逻辑把各来源的请求合成"一个写口、一个读口"，再在一个只做读写的 always 块里访问存储器。

```verilog
wire [8:0]  ra = pipe_read ? pipe_addr : axi_addr;     // 读口：按优先级选来源
wire        re = pipe_read || axi_pending;
wire        we = clearing || wb_valid;                 // 写口：清零或写回
wire [8:0]  wa = clearing ? clear_addr : wb_addr;
wire [31:0] wd = clearing ? 32'd0 : wb_data;
always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    if (re) port_a <= mem[ra];                         // 寄存的读输出
end
```

3. 改写后用原来的测试向量重跑，确认功能逐字不变，再看综合结果。

## 已验证效果

- 本项目度量模块：LUT 1,746 → 475，LUTRAM 1,056 → 0，增加 1 个 RAMB18；单元测试 30,023 个周期、1,631 次读与最终 386 个字前后一致（`build/ofdm_nc/cmetric02`）。

## 失效条件与边界

- 只在 Vivado 2023.2、XC7Z045 上验证过一个案例。
- 模板适用于"一读一写"；真正需要两个独立读口时要用真双口模板，或复制存储器。
- 读口有优先级时，低优先级来源可能长时间等不到读口，需要另行处理超时与响应归属（本项目在独立审查中被指出，后来加了取消读请求）。
