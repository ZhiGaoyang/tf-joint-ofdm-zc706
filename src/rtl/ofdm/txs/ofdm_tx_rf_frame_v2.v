`timescale 1ns/1ps
`default_nettype none
// V0.2 RF frame: ofdm_tx_rf_frame with the V0.2 frame chain.
// NC: cfg_mask (phy_clk, static per burst) is passed to the frame chain.
module ofdm_tx_rf_frame_v2 #(
  parameter integer FIFO_DEPTH = 2048,
  parameter integer PREFILL_PAIRS = 1024
) (
  input wire arst, phy_clk, tx_clk, run_phy, run_tx,
  input wire phy_hold,
  input wire [15:0] cfg_frames,
  input wire [10:0] cfg_mask,
  input wire cmd_valid, output wire cmd_ready,
  input wire [31:0] cmd_frame_id,
  input wire [12:0] cmd_payload_len,
  input wire [1:0] cmd_mcs,
  input wire [15:0] cmd_config_epoch,
  input wire [7:0] s_axis_tdata,
  input wire s_axis_tvalid, output wire s_axis_tready, input wire s_axis_tlast,
  input wire [1:0] request_tx,
  output wire [31:0] dac_i_tx, dac_q_tx,
  output wire [1:0] dac_last_tx,
  output wire [7:0] dac_user0_tx, dac_user1_tx,
  output wire response_tx, underflow_tx, ready_phy, ready_tx,
  output wire prefilled_phy, active_tx, done_tx, aborted_tx, pair_valid_tx,
  output wire fault_phy, fault_tx, partial_pending_phy,
  output wire [31:0] sample_count_phy, pair_count_phy, partial_drop_count_phy, bad_user_count_phy,
  output wire [31:0] frames_queued_phy, frames_retired_tx, pairs_retired_tx,
  output wire [31:0] underflow_count_tx, request_count_tx, request_mismatch_count_tx,
  output wire frame_fault_phy,
  output reg [31:0] descriptors_accepted_phy
);
  // phy_hold is a PHY-synchronous hold (the parent's synchronised reset); it keeps
  // the frame chain in reset before the prefill synchronisers settle, without an
  // asynchronous path from foreign-clock resets into synchronous PHY resets.
  wire frame_resetn = ready_phy && !phy_hold;
  reg quota_locked_phy;
  reg [15:0] captured_frames_phy;
  wire cmd_allow = quota_locked_phy && captured_frames_phy >= 16'd1 &&
                   captured_frames_phy <= 16'd32 &&
                   descriptors_accepted_phy < captured_frames_phy && frame_resetn;
  wire core_cmd_ready, core_byte_ready;
  wire [31:0] cp_data;
  wire [1:0] cp_user;
  wire cp_valid, cp_ready, cp_last;
  assign cmd_ready = core_cmd_ready && cmd_allow;
  assign s_axis_tready = core_byte_ready && frame_resetn;
  // Quota has no live run/fault veto: a held unaccepted command keeps VALID.
  always @(posedge phy_clk or negedge frame_resetn) begin
    if(!frame_resetn) begin
      quota_locked_phy <= 0;
      captured_frames_phy <= 0;
      descriptors_accepted_phy <= 0;
    end else begin
      if(!quota_locked_phy && run_phy) begin
        quota_locked_phy <= 1;
        captured_frames_phy <= cfg_frames;
      end
      if(cmd_valid && cmd_ready) descriptors_accepted_phy <= descriptors_accepted_phy + 1'b1;
    end
  end
  ofdm_tx_frame_v2 frame_tx (
    .clk(phy_clk),.resetn(frame_resetn),.cfg_mask(cfg_mask),.cmd_valid(cmd_valid && cmd_allow),.cmd_ready(core_cmd_ready),
    .cmd_frame_id(cmd_frame_id),.cmd_payload_len(cmd_payload_len),.cmd_mcs(cmd_mcs),.cmd_config_epoch(cmd_config_epoch),
    .s_axis_tdata(s_axis_tdata),.s_axis_tvalid(s_axis_tvalid),.s_axis_tready(core_byte_ready),.s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(cp_data),.m_axis_tvalid(cp_valid),.m_axis_tready(cp_ready),.m_axis_tlast(cp_last),.m_axis_tuser(cp_user),.fault(frame_fault_phy)
  );
  ofdm_tx_prefill #(.FIFO_DEPTH(FIFO_DEPTH),.PREFILL_PAIRS(PREFILL_PAIRS)) rf_edge (
    .arst(arst),.phy_clk(phy_clk),.tx_clk(tx_clk),.run_phy(run_phy),.run_tx(run_tx),.cfg_frames(cfg_frames),
    .source_fault_phy(frame_fault_phy),.s_axis_tdata(cp_data),.s_axis_tvalid(cp_valid),.s_axis_tready(cp_ready),
    .s_axis_tlast(cp_last),.s_axis_tuser({6'b0,cp_user}),.request_tx(request_tx),
    .dac_i_tx(dac_i_tx),.dac_q_tx(dac_q_tx),.dac_last_tx(dac_last_tx),.dac_user0_tx(dac_user0_tx),.dac_user1_tx(dac_user1_tx),
    .response_tx(response_tx),.underflow_tx(underflow_tx),.ready_phy(ready_phy),.ready_tx(ready_tx),
    .prefilled_phy(prefilled_phy),.active_tx(active_tx),.done_tx(done_tx),.aborted_tx(aborted_tx),.pair_valid_tx(pair_valid_tx),
    .fault_phy(fault_phy),.fault_tx(fault_tx),.partial_pending_phy(partial_pending_phy),
    .sample_count_phy(sample_count_phy),.pair_count_phy(pair_count_phy),.partial_drop_count_phy(partial_drop_count_phy),.bad_user_count_phy(bad_user_count_phy),
    .frames_queued_phy(frames_queued_phy),.frames_retired_tx(frames_retired_tx),.pairs_retired_tx(pairs_retired_tx),
    .underflow_count_tx(underflow_count_tx),.request_count_tx(request_count_tx),.request_mismatch_count_tx(request_mismatch_count_tx)
  );
endmodule
`default_nettype wire
