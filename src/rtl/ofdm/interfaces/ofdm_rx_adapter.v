`timescale 1ns/1ps
`default_nettype none
// Set cfg_mask while stopped for >=2 rx_clk edges after local reset release.
// ready_* reports FIFO/reset readiness only; configuration is not handshaked.
module ofdm_rx_adapter #(parameter integer FIFO_DEPTH = 512) (
  input wire arst, rx_clk, phy_clk, run_rx, run_phy,
  input wire [1:0] cfg_mask, rf_valid,
  input wire [15:0] rf_i, rf_q,
  input wire rf_last,
  input wire [7:0] rf_user,
  output wire [31:0] m_axis_tdata,
  output wire m_axis_tlast,
  output wire [7:0] m_axis_tuser,
  output wire m_axis_tvalid,
  input wire m_axis_tready,
  output wire ready_rx, ready_phy,
  output reg fault_rx,
  output wire invalid_phy,
  output wire fault_phy_raw,
  output reg [31:0] seen_count_rx, accepted_count_rx, lost_count_rx,
  output reg [31:0] overflow_count_rx, mismatch_count_rx, config_error_count_rx
);
  wire reset_rx, reset_phy, full, empty;
  wire [40:0] fifo_out;
  reg [1:0] mask_rx;
  reg config_locked_rx, config_fault_rx;
  wire config_changed = config_locked_rx && (cfg_mask != mask_rx);
  wire source_event = run_rx && (mask_rx == 2'b11) && (|rf_valid);
  wire input_ok = (rf_valid == 2'b11) && (rf_user[7:2] == 0);
  wire enqueue = source_event && input_ok && !fault_rx && !config_changed && ready_rx && !full;
  wire fault_sync_phy;

  ofdm_async_fifo #(.WIDTH(41), .DEPTH(FIFO_DEPTH)) samples (
    .arst(arst), .wr_clk(rx_clk), .rd_clk(phy_clk),
    .din({rf_user, rf_last, rf_q, rf_i}), .wr_en(enqueue),
    .rd_en(m_axis_tvalid && m_axis_tready), .dout(fifo_out), .full(full), .empty(empty),
    .ready_wr(ready_rx), .ready_rd(ready_phy), .reset_wr(reset_rx), .reset_rd(reset_phy)
  );
  // A sticky single-bit fault crosses separately from immutable queued samples.
  // Consumers must discard their partial frame and request shared reset/flush.
  xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(0), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0))
    fault_cdc (.src_clk(rx_clk), .src_in(fault_rx), .dest_clk(phy_clk), .dest_out(fault_sync_phy));
  assign invalid_phy = !reset_phy && fault_sync_phy;
  assign fault_phy_raw = fault_sync_phy;
  assign m_axis_tvalid = ready_phy && run_phy && !empty;
  assign {m_axis_tuser, m_axis_tlast, m_axis_tdata} = fifo_out;

  always @(posedge rx_clk or posedge reset_rx) begin
    if (reset_rx) begin
      mask_rx <= 0;
      config_locked_rx <= 0;
      config_fault_rx <= 0;
      fault_rx <= 0;
      seen_count_rx <= 0;
      accepted_count_rx <= 0;
      lost_count_rx <= 0;
      overflow_count_rx <= 0;
      mismatch_count_rx <= 0;
      config_error_count_rx <= 0;
    end else begin
      if (!config_locked_rx) begin
        mask_rx <= cfg_mask;
        if (run_rx) begin
          config_locked_rx <= 1;
          if (cfg_mask != 0 && cfg_mask != 3) begin
            fault_rx <= 1;
            config_fault_rx <= 1;
            config_error_count_rx <= config_error_count_rx + 1;
          end
        end
      end
      if (config_changed && !config_fault_rx) begin
        config_fault_rx <= 1;
        fault_rx <= 1;
        config_error_count_rx <= config_error_count_rx + 1;
      end
      if (source_event) begin
        seen_count_rx <= seen_count_rx + 1;
        if (enqueue) accepted_count_rx <= accepted_count_rx + 1;
        else begin
          lost_count_rx <= lost_count_rx + 1;
          fault_rx <= 1;
          if (!fault_rx && !config_changed) begin
            if (!input_ok) mismatch_count_rx <= mismatch_count_rx + 1;
            else overflow_count_rx <= overflow_count_rx + 1;
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
