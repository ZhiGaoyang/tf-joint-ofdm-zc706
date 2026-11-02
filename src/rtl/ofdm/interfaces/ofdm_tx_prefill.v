`timescale 1ns/1ps
`default_nettype none
// One configured burst per shared reset; PHY publishes its locked quota once.
// Keep both run inputs asserted after lock until shared reset, including done.
module ofdm_tx_prefill #(
  parameter integer FIFO_DEPTH = 1024,
  parameter integer PREFILL_PAIRS = 512
) (
  input wire arst, phy_clk, tx_clk, run_phy, run_tx,
  input wire [15:0] cfg_frames,
  input wire source_fault_phy,
  input wire [31:0] s_axis_tdata,
  input wire s_axis_tlast,
  input wire [7:0] s_axis_tuser,
  input wire s_axis_tvalid,
  output wire s_axis_tready,
  input wire [1:0] request_tx,
  output wire [31:0] dac_i_tx, dac_q_tx,
  output wire [1:0] dac_last_tx,
  output wire [7:0] dac_user0_tx, dac_user1_tx,
  output wire response_tx, underflow_tx,
  output wire ready_phy, ready_tx,
  output reg prefilled_phy,
  output wire active_tx,
  output reg done_tx, aborted_tx,
  output wire pair_valid_tx, fault_phy, fault_tx,
  output wire partial_pending_phy,
  output wire [31:0] sample_count_phy, pair_count_phy, partial_drop_count_phy,
  output wire [31:0] bad_user_count_phy,
  output reg [31:0] frames_queued_phy, frames_retired_tx, pairs_retired_tx,
  output wire [31:0] underflow_count_tx, request_count_tx, request_mismatch_count_tx
);
  wire reset_phy, reset_tx;
  wire adapter_fault_phy, adapter_fault_tx;
  reg controller_fault_phy, controller_fault_tx;
  reg [15:0] captured_frames_phy, captured_frames_tx;
  reg [31:0] final_frame_index_tx;
  reg [31:0] preterminal_index_tx;
  reg terminal_frame_tx;
  reg [1:0] stable_edges_phy;
  reg locked_phy, locked_tx, armed_tx, attempted_tx;
  reg config_sent_phy, config_received_tx;
  wire [15:0] config_data_tx;
  wire config_full_phy, config_empty_tx, config_ready_phy, config_ready_tx;
  wire config_write = locked_phy && !config_sent_phy && config_ready_phy &&
                      !config_full_phy && !fault_phy;
  wire config_read = !config_received_tx && config_ready_tx && !config_empty_tx;
  reg [3:0] prefill_settle_tx;
  wire prefill_sync_tx, source_fault_sync_tx;
  wire config_changed_phy = locked_phy && (cfg_frames != captured_frames_phy);
  wire legal_frames = cfg_frames >= 16'd1 && cfg_frames <= 16'd32;
  wire legal_geometry = PREFILL_PAIRS >= 1 && PREFILL_PAIRS <= FIFO_DEPTH;
  wire accept_sample = s_axis_tvalid && s_axis_tready;
  wire accepted_eof = accept_sample && partial_pending_phy && s_axis_tuser[1] &&
                      !(|s_axis_tuser[7:2]);
  wire adapter_run_phy = run_phy && locked_phy && !fault_phy &&
                        (frames_queued_phy < captured_frames_phy);
  wire adapter_run_tx = run_tx && locked_tx && config_received_tx;
  // Describe the published transport word for its whole owning TX cycle.
  // A newly live fault blocks future reads and invalidates the complete burst;
  // it must not erase an already emitted word before its retirement edge.
  wire valid_registered_pair = attempted_tx && response_tx && !underflow_tx && !reset_tx;
  wire odd_registered_eof = valid_registered_pair && dac_user0_tx[1];
  wire terminal_pair = pair_valid_tx && dac_user1_tx[1] &&
                       terminal_frame_tx;
  // Gate the NEXT read using CURRENT registered DAC metadata before its edge.
  assign active_tx = armed_tx && run_tx && ready_tx && !reset_tx && !fault_tx &&
                     !done_tx && !aborted_tx && !terminal_pair && !underflow_tx;
  assign pair_valid_tx = valid_registered_pair && !dac_user0_tx[1];
  assign fault_phy = !reset_phy && (controller_fault_phy || adapter_fault_phy ||
                    source_fault_phy || config_changed_phy || (locked_phy && !run_phy));
  assign fault_tx = !reset_tx && (controller_fault_tx || adapter_fault_tx ||
                   source_fault_sync_tx || (locked_tx && !run_tx));

  xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .RST_ACTIVE_HIGH(1))
    phy_reset (.src_arst(arst), .dest_clk(phy_clk), .dest_arst(reset_phy));
  xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .RST_ACTIVE_HIGH(1))
    tx_reset (.src_arst(arst), .dest_clk(tx_clk), .dest_arst(reset_tx));
  xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(0), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0))
    prefill_cdc (.src_clk(phy_clk), .src_in(prefilled_phy), .dest_clk(tx_clk), .dest_out(prefill_sync_tx));
  // Register the combined fault before CDC; local PHY admission stays immediate.
  xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(1), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0))
    fault_cdc (.src_clk(phy_clk), .src_in(fault_phy), .dest_clk(tx_clk), .dest_out(source_fault_sync_tx));

  // A real asynchronous mailbox transfers one coherent image after PHY lock.
  // TX never uses the live PHY configuration bus in a destination control cone.
  ofdm_async_fifo #(.WIDTH(16), .DEPTH(32)) config_mailbox (
    .arst(arst), .wr_clk(phy_clk), .rd_clk(tx_clk), .din(captured_frames_phy),
    .wr_en(config_write), .rd_en(config_read), .dout(config_data_tx),
    .full(config_full_phy), .empty(config_empty_tx),
    .ready_wr(config_ready_phy), .ready_rd(config_ready_tx), .reset_wr(), .reset_rd()
  );

  // Never revoke a held source VALID. Adapter run/ready owns ingress quota.
  ofdm_tx_adapter #(.FIFO_DEPTH(FIFO_DEPTH)) adapter (
    .arst(arst), .phy_clk(phy_clk), .tx_clk(tx_clk),
    .run_phy(adapter_run_phy), .run_tx(adapter_run_tx), .active_tx(active_tx),
    .cfg_mask(2'b11), .cfg_bypass(1'b0),
    .s_axis_tdata(s_axis_tdata), .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .request_tx(request_tx),
    .bypass_i_tx(32'b0), .bypass_q_tx(32'b0),
    .dac_i_tx(dac_i_tx), .dac_q_tx(dac_q_tx), .dac_last_tx(dac_last_tx),
    .dac_user0_tx(dac_user0_tx), .dac_user1_tx(dac_user1_tx),
    .response_tx(response_tx), .underflow_tx(underflow_tx),
    .ready_phy(ready_phy), .ready_tx(ready_tx), .partial_pending_phy(partial_pending_phy),
    .invalid_phy(adapter_fault_phy), .invalid_tx(adapter_fault_tx),
    .sample_count_phy(sample_count_phy), .pair_count_phy(pair_count_phy),
    .partial_drop_count_phy(partial_drop_count_phy), .bad_user_count_phy(bad_user_count_phy),
    .underflow_count_tx(underflow_count_tx), .request_count_tx(request_count_tx),
    .request_mismatch_count_tx(request_mismatch_count_tx), .config_error_count_tx()
  );

  always @(posedge phy_clk or posedge reset_phy) begin
    if(reset_phy) begin
      captured_frames_phy <= 0; stable_edges_phy <= 0; locked_phy <= 0;
      config_sent_phy <= 0;
      controller_fault_phy <= 0; prefilled_phy <= 0; frames_queued_phy <= 0;
    end else begin
      if(config_write) config_sent_phy <= 1;
      if(!locked_phy) begin
        if(!run_phy && ready_phy) begin
          captured_frames_phy <= cfg_frames;
          if(cfg_frames != captured_frames_phy) stable_edges_phy <= 1;
          else if(stable_edges_phy < 2) stable_edges_phy <= stable_edges_phy + 1'b1;
        end
        if(run_phy) begin
          locked_phy <= 1;
          if(!legal_frames || !legal_geometry || stable_edges_phy < 2 ||
             cfg_frames != captured_frames_phy) controller_fault_phy <= 1;
        end
      end
      if(source_fault_phy || adapter_fault_phy || config_changed_phy ||
         (locked_phy && !run_phy)) controller_fault_phy <= 1;
      if(accepted_eof) frames_queued_phy <= frames_queued_phy + 1'b1;
      if(locked_phy && !fault_phy &&
         (pair_count_phy >= PREFILL_PAIRS || frames_queued_phy == captured_frames_phy))
        prefilled_phy <= 1;
    end
  end

  always @(posedge tx_clk or posedge reset_tx) begin
    if(reset_tx) begin
      captured_frames_tx <= 0; locked_tx <= 0; config_received_tx <= 0;
      final_frame_index_tx <= 32'hffffffff;
      preterminal_index_tx <= 32'hfffffffe; terminal_frame_tx <= 0;
      controller_fault_tx <= 0; armed_tx <= 0; attempted_tx <= 0; prefill_settle_tx <= 0;
      done_tx <= 0; aborted_tx <= 0; frames_retired_tx <= 0; pairs_retired_tx <= 0;
    end else begin
      attempted_tx <= active_tx && (request_tx == 2'b11);
      if(config_read) begin
        captured_frames_tx <= config_data_tx;
        // Preserve the promoted 32-bit subtraction, including quota zero.
        final_frame_index_tx <= {16'd0, config_data_tx} - 32'd1;
        preterminal_index_tx <= {16'd0, config_data_tx} - 32'd2;
        terminal_frame_tx <= config_data_tx == 16'd1;
        config_received_tx <= 1;
        if(config_data_tx < 16'd1 || config_data_tx > 16'd32 || !legal_geometry)
          controller_fault_tx <= 1;
      end
      // Lock run immediately, even while waiting for the coherent quota image.
      if(!locked_tx && run_tx) locked_tx <= 1;
      // Pinned XPM FWFT has Gray/output-register/RAM/FSM stages beyond flagCDC4.
      // Eight local settling edges cover first-word visibility even for one pair.
      // This is a startup delay only, never occupancy-based RF throttling.
      if(locked_tx && config_received_tx && run_tx && ready_tx && prefill_sync_tx && !fault_tx &&
         !done_tx && !aborted_tx) begin
        if(prefill_settle_tx < 8) prefill_settle_tx <= prefill_settle_tx + 1'b1;
        else armed_tx <= 1;
      end
      if(pair_valid_tx) begin
        pairs_retired_tx <= pairs_retired_tx + 1'b1;
        if(dac_user1_tx[1]) begin
          frames_retired_tx <= frames_retired_tx + 1'b1;
          // Update on the same edge as the counter, before any next-frame pair.
          terminal_frame_tx <= frames_retired_tx == preterminal_index_tx;
        end
      end
      if(terminal_pair && !fault_tx) begin
        done_tx <= 1; armed_tx <= 0;
      end
      if(fault_tx || underflow_tx || odd_registered_eof) begin
        controller_fault_tx <= 1; aborted_tx <= 1; armed_tx <= 0; done_tx <= 0;
      end
    end
  end
endmodule
`default_nettype wire
