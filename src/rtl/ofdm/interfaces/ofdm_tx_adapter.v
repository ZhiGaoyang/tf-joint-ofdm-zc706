`timescale 1ns/1ps
`default_nettype none
// Set cfg_* while stopped for >=2 owning-domain edges after local reset release.
// Mode changes after either run locks configuration require shared reset.
module ofdm_tx_adapter #(parameter integer FIFO_DEPTH = 512) (
  input wire arst, phy_clk, tx_clk, run_phy, run_tx, active_tx,
  input wire [1:0] cfg_mask,
  input wire cfg_bypass,
  input wire [31:0] s_axis_tdata,
  input wire s_axis_tlast,
  input wire [7:0] s_axis_tuser,
  input wire s_axis_tvalid,
  output wire s_axis_tready,
  input wire [1:0] request_tx,
  input wire [31:0] bypass_i_tx, bypass_q_tx,
  output reg [31:0] dac_i_tx, dac_q_tx,
  output reg [1:0] dac_last_tx,
  output reg [7:0] dac_user0_tx, dac_user1_tx,
  output reg response_tx, underflow_tx,
  output wire ready_phy, ready_tx,
  output reg partial_pending_phy, invalid_phy,
  output wire invalid_tx,
  output reg [31:0] sample_count_phy, pair_count_phy, partial_drop_count_phy,
  output reg [31:0] bad_user_count_phy, underflow_count_tx, request_count_tx,
  output reg [31:0] request_mismatch_count_tx, config_error_count_tx
);
  wire reset_phy, reset_tx, full, empty;
  wire [81:0] fifo_out;
  reg [40:0] first_sample_phy;
  reg [1:0] mask_phy, mask_tx;
  reg bypass_phy, bypass_tx;
  reg locked_phy, locked_tx, config_fault_phy, config_fault_tx, fault_tx;
  wire changed_phy = locked_phy && ((cfg_mask != mask_phy) || (cfg_bypass != bypass_phy));
  wire changed_tx = locked_tx && ((cfg_mask != mask_tx) || (cfg_bypass != bypass_tx));
  wire bad_user = |s_axis_tuser[7:2];
  wire accept_sample = s_axis_tvalid && s_axis_tready;
  wire write_pair = accept_sample && partial_pending_phy && !bad_user;
  wire read_pair = run_tx && active_tx && (mask_tx == 3) && (request_tx == 3) &&
    !bypass_tx && !config_fault_tx && !changed_tx && ready_tx && !empty;
  wire source_invalid_tx;
  assign s_axis_tready = run_phy && (mask_phy == 3) && !bypass_phy && !invalid_phy &&
    !changed_phy && ready_phy && !full;
  assign invalid_tx = !reset_tx && (fault_tx || source_invalid_tx);
  ofdm_async_fifo #(.WIDTH(82), .DEPTH(FIFO_DEPTH)) pairs (
    .arst(arst), .wr_clk(phy_clk), .rd_clk(tx_clk),
    .din({s_axis_tuser, s_axis_tlast, s_axis_tdata, first_sample_phy}),
    .wr_en(write_pair), .rd_en(read_pair), .dout(fifo_out), .full(full), .empty(empty),
    .ready_wr(ready_phy), .ready_rd(ready_tx), .reset_wr(reset_phy), .reset_rd(reset_tx)
  );
  xpm_cdc_single #(.DEST_SYNC_FF(4), .SRC_INPUT_REG(0), .INIT_SYNC_FF(0), .SIM_ASSERT_CHK(0))
    invalid_cdc (.src_clk(phy_clk), .src_in(invalid_phy), .dest_clk(tx_clk), .dest_out(source_invalid_tx));

  always @(posedge phy_clk or posedge reset_phy) begin
    if (reset_phy) begin
      first_sample_phy <= 0;
      partial_pending_phy <= 0;
      invalid_phy <= 0;
      mask_phy <= 0;
      bypass_phy <= 0;
      locked_phy <= 0;
      config_fault_phy <= 0;
      sample_count_phy <= 0;
      pair_count_phy <= 0;
      partial_drop_count_phy <= 0;
      bad_user_count_phy <= 0;
    end else begin
      if (!locked_phy) begin
        mask_phy <= cfg_mask;
        bypass_phy <= cfg_bypass;
        if (run_phy) begin
          locked_phy <= 1;
          if (cfg_mask != 0 && cfg_mask != 3) begin
            invalid_phy <= 1;
            config_fault_phy <= 1;
          end
        end
      end
      if (changed_phy && !config_fault_phy) begin
        invalid_phy <= 1;
        config_fault_phy <= 1;
        partial_pending_phy <= 0;
        if (partial_pending_phy) partial_drop_count_phy <= partial_drop_count_phy + 1;
      end
      if (accept_sample) begin
        sample_count_phy <= sample_count_phy + 1;
        if (bad_user) begin
          bad_user_count_phy <= bad_user_count_phy + 1;
          partial_drop_count_phy <= partial_drop_count_phy + (partial_pending_phy ? 2 : 1);
          partial_pending_phy <= 0;
          invalid_phy <= 1;
        end else if (!partial_pending_phy) begin
          if (s_axis_tuser[1]) begin
            partial_drop_count_phy <= partial_drop_count_phy + 1;
            invalid_phy <= 1;
          end else begin
            first_sample_phy <= {s_axis_tuser, s_axis_tlast, s_axis_tdata};
            partial_pending_phy <= 1;
          end
        end else begin
          partial_pending_phy <= 0;
          pair_count_phy <= pair_count_phy + 1;
        end
      end
    end
  end

  always @(posedge tx_clk or posedge reset_tx) begin
    if (reset_tx) begin
      dac_i_tx <= 0; dac_q_tx <= 0; dac_last_tx <= 0;
      dac_user0_tx <= 0; dac_user1_tx <= 0;
      response_tx <= 0; underflow_tx <= 0;
      mask_tx <= 0; bypass_tx <= 0; locked_tx <= 0;
      config_fault_tx <= 0; fault_tx <= 0;
      underflow_count_tx <= 0; request_count_tx <= 0;
      request_mismatch_count_tx <= 0; config_error_count_tx <= 0;
    end else begin
      dac_i_tx <= 0; dac_q_tx <= 0; dac_last_tx <= 0;
      dac_user0_tx <= 0; dac_user1_tx <= 0;
      response_tx <= 0; underflow_tx <= 0;
      if (!locked_tx) begin
        mask_tx <= cfg_mask;
        bypass_tx <= cfg_bypass;
        if (run_tx) begin
          locked_tx <= 1;
          if (cfg_mask != 0 && cfg_mask != 3) begin
            config_fault_tx <= 1;
            fault_tx <= 1;
            config_error_count_tx <= config_error_count_tx + 1;
          end
        end
      end
      if (changed_tx && !config_fault_tx) begin
        config_fault_tx <= 1;
        fault_tx <= 1;
        config_error_count_tx <= config_error_count_tx + 1;
      end
      if (run_tx && mask_tx == 3 && (|request_tx)) begin
        response_tx <= 1;
        request_count_tx <= request_count_tx + 1;
        if (request_tx != 3) begin
          request_mismatch_count_tx <= request_mismatch_count_tx + 1;
          fault_tx <= 1;
        end else if (!config_fault_tx && !changed_tx) begin
          if (bypass_tx) begin
            dac_i_tx <= bypass_i_tx;
            dac_q_tx <= bypass_q_tx;
          end else if (active_tx) begin
            if (!ready_tx || empty) begin
              underflow_tx <= 1;
              underflow_count_tx <= underflow_count_tx + 1;
              fault_tx <= 1;
            end else begin
              dac_i_tx <= {fifo_out[56:41], fifo_out[15:0]};
              dac_q_tx <= {fifo_out[72:57], fifo_out[31:16]};
              dac_last_tx <= {fifo_out[73], fifo_out[32]};
              dac_user0_tx <= fifo_out[40:33];
              dac_user1_tx <= fifo_out[81:74];
            end
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
