`timescale 1ns/1ps
`default_nettype none
module ofdm_async_fifo #(
  parameter integer WIDTH = 41,
  parameter integer DEPTH = 512
) (
  input wire arst,
  input wire wr_clk,
  input wire rd_clk,
  input wire [WIDTH-1:0] din,
  input wire wr_en,
  input wire rd_en,
  output wire [WIDTH-1:0] dout,
  output wire full,
  output wire empty,
  output wire ready_wr,
  output wire ready_rd,
  output wire reset_wr,
  output wire reset_rd
);
  // Constant function keeps the wrapper compatible with Verilog-2001.
  function integer clog2;
    input integer value;
    integer remaining;
    begin
      remaining = value - 1;
      clog2 = 0;
      while (remaining > 0) begin
        remaining = remaining >> 1;
        clog2 = clog2 + 1;
      end
    end
  endfunction
  localparam integer COUNT_WIDTH = clog2(DEPTH) + 1;
  wire fifo_reset, wr_busy, rd_busy;
  xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .RST_ACTIVE_HIGH(1))
    wr_reset_sync (.src_arst(arst), .dest_clk(wr_clk), .dest_arst(reset_wr));
  xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .RST_ACTIVE_HIGH(1))
    rd_reset_sync (.src_arst(arst), .dest_clk(rd_clk), .dest_arst(reset_rd));
  // Shared arst must cover >=8 rising edges of each running owning clock.
  // Narrow asynchronous pulses may miss fifo_reset_sync and cannot flush it.
  // XPM FIFO rst is synchronous to wr_clk, including assertion. The local
  // async resets immediately suppress transactions while FIFO reset arrives.
  xpm_cdc_sync_rst #(.DEST_SYNC_FF(4), .INIT(1), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0))
    fifo_reset_sync (.src_rst(arst), .dest_clk(wr_clk), .dest_rst(fifo_reset));
  // Local resets assert asynchronously; foreign reset release never gates READY.
  assign ready_wr = !reset_wr && !fifo_reset && !wr_busy;
  assign ready_rd = !reset_rd && !rd_busy;
  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(DEPTH),
    .WRITE_DATA_WIDTH(WIDTH), .READ_DATA_WIDTH(WIDTH),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(4),
    .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"), .DOUT_RESET_VALUE("0"),
    .FULL_RESET_VALUE(0), .USE_ADV_FEATURES("0000"),
    .WR_DATA_COUNT_WIDTH(COUNT_WIDTH), .RD_DATA_COUNT_WIDTH(COUNT_WIDTH),
    .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(10), .SIM_ASSERT_CHK(1),
    .WAKEUP_TIME(0)
  ) fifo (
    .rst(fifo_reset), .wr_clk(wr_clk), .rd_clk(rd_clk), .din(din),
    .wr_en(wr_en && ready_wr && !full), .rd_en(rd_en && ready_rd && !empty),
    .dout(dout), .full(full), .empty(empty), .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
    .almost_full(), .almost_empty(), .prog_full(), .prog_empty(),
    .wr_data_count(), .rd_data_count(), .overflow(), .underflow(), .wr_ack(),
    .data_valid(), .sbiterr(), .dbiterr()
  );
endmodule
`default_nettype wire
