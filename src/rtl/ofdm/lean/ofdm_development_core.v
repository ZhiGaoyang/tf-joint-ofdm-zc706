`timescale 1ns/1ps
`default_nettype none
// Route-B lean development core.  Same module name and ports as the previous
// rtl/ofdm/platform/ofdm_development_core.v so the existing board shell and
// insertion flow are reused unchanged.  Contents:
//   AXI-Lite registers (config, TX burst control, coherent statistics snapshot)
//   PRBS test source -> V0.2 TX frame chain -> existing prefill/DAC adapter
//   existing RX adapter (rx_clk -> PHY CDC) -> streaming RX core (ofdm_rxs_core)
// The payload DMA ports are kept idle (MM2S sink, S2MM silent) and IRQs are low.
// NC extension (docs/innovation/b_subcarrier_mask_design.md section 4):
//   0x048 NC_TX_CFG  [10:0] TX group mask, latched at TX_GO for the whole burst
//   0x04C NC_RX_CFG  [24] blind candidate enable (reset 1), [25] metric enable,
//                    [26] metric freeze; other bits reserved 0
//   0x054 NC_METRIC_CTRL write [0]=1 clears the metric banks, [9]=1 clears the timeout flag;
//                    read [8] clear busy, [9] a metric read timed out (sticky; that read
//                    returned 0 and its request was cancelled, so no stale data follows)
//   0x058/0x05C NC_SYMS_HDR / NC_SYMS_PAY (RO) measured header / payload symbols
//   0x200+4d / 0x400+4d / 0x600+4d (RO, d=0..87) header / payload error sums
//                    (2^16 = unit energy per instance) and erased-instance counts;
//                    read through the RX metric block (a few wait cycles; 0 while
//                    the RX core is in reset or after a 64-cycle timeout)
//   0x050 NC_HDR_THR [20:0] blind group threshold (reset 185360)
//   0x060 NC_RX_LAST (RO) decoder last-accepted mask/candidate/blind diagnostics
//   0x064 NC_RX_CNT  (RO) [15:0] blind-accepted, [31:16] zero-accepted headers
//   0x068 NC_TX_STATUS (RO) [10:0] burst mask, [11] >3 groups, [18:12] data carriers
//   0x06C NC_LAST_MASK (RO) [10:0] mask of the last status record
module ofdm_development_core (
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi:s_axis_mm2s:m_axis_s2mm, ASSOCIATED_RESET global_arst, FREQ_HZ 200000000" *)
 input wire clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 tx_clk CLK" *) input wire tx_clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 rx_clk CLK" *) input wire rx_clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 global_arst RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_HIGH" *) input wire global_arst,
 input wire dev_arst,rf_tx_arst,rf_rx_arst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWADDR", X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32, FREQ_HZ 200000000" *) input wire [31:0] s_axi_awaddr,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWVALID" *) input wire s_axi_awvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWREADY" *) output wire s_axi_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WDATA" *) input wire [31:0] s_axi_wdata,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WSTRB" *) input wire [3:0] s_axi_wstrb,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WVALID" *) input wire s_axi_wvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WREADY" *) output wire s_axi_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BRESP" *) output wire [1:0] s_axi_bresp,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BVALID" *) output wire s_axi_bvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BREADY" *) input wire s_axi_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARADDR" *) input wire [31:0] s_axi_araddr,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARVALID" *) input wire s_axi_arvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARREADY" *) output wire s_axi_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RDATA" *) output wire [31:0] s_axi_rdata,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RRESP" *) output wire [1:0] s_axi_rresp,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RVALID" *) output wire s_axi_rvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RREADY" *) input wire s_axi_rready,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TDATA" *) input wire [63:0] s_axis_mm2s_tdata,(* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TKEEP" *) input wire [7:0] s_axis_mm2s_tkeep,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TLAST" *) input wire s_axis_mm2s_tlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TVALID" *) input wire s_axis_mm2s_tvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TREADY" *) output wire s_axis_mm2s_tready,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TDATA" *) output wire [63:0] m_axis_s2mm_tdata,(* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TKEEP" *) output wire [7:0] m_axis_s2mm_tkeep,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TLAST" *) output wire m_axis_s2mm_tlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TVALID" *) output wire m_axis_s2mm_tvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TREADY" *) input wire m_axis_s2mm_tready,
 (* X_INTERFACE_IGNORE="true" *) output reg [31:0] dev_i_tx,dev_q_tx,
 (* X_INTERFACE_IGNORE="true" *) output wire dev_underflow_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire [1:0] dev_request_tx,dev_enable_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire dev_request_mismatch_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire [15:0] rf_i_rx,rf_q_rx,
 (* X_INTERFACE_IGNORE="true" *) input wire [1:0] rf_enable_rx,rf_valid_rx,
 output wire session_arst,legacy_irq,bridge_irq,
 output wire [31:0] retained_boundary_faults,
 output wire [31:0] boundary_mismatch_count_tx
);
 // ------------------------------------------------------------- idle DMA
 assign s_axis_mm2s_tready = 1'b1;
 assign m_axis_s2mm_tdata = 64'd0;
 assign m_axis_s2mm_tkeep = 8'd0;
 assign m_axis_s2mm_tlast = 1'b0;
 assign m_axis_s2mm_tvalid = 1'b0;
 assign legacy_irq = 1'b0;
 assign bridge_irq = 1'b0;

 // ---------------------------------------------------------------- resets
 // The board shell feeds dev_arst = global | session_arst | rf_tx | rf_rx back
 // into this core.  session_arst is driven from tx_arst below, so dev_arst must
 // not be used here: it would close a combinational reset loop and would also
 // reset the receiver on every TX burst.
 wire modem_arst = global_arst | rf_tx_arst | rf_rx_arst;
 wire reg_arst;
 xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(1))
  reg_reset_cdc(.src_arst(global_arst),.dest_clk(clk),.dest_arst(reg_arst));

 // --------------------------------------------------------------- AXI-Lite
 reg aw_pending, w_pending, b_valid, r_valid, r_wait;
 reg [11:0] aw_addr, ar_addr;
 reg [31:0] w_data, r_data;
 assign s_axi_awready = !aw_pending && !b_valid;
 assign s_axi_wready = !w_pending && !b_valid;
 assign s_axi_bvalid = b_valid;
 assign s_axi_bresp = 2'b00;
 assign s_axi_arready = !r_valid && !r_wait;
 assign s_axi_rvalid = r_valid;
 assign s_axi_rresp = 2'b00;
 assign s_axi_rdata = r_data;
 wire do_write = aw_pending && w_pending && !b_valid;

 // configuration registers
 reg rx_enable, prbs_check, rx_soft_reset, tx_soft_reset, loopback;
 reg [15:0] tx_frames;
 reg [31:0] tx_first_id;
 reg [12:0] tx_len;
 reg tx_mcs;
 reg [15:0] tx_epoch;
 reg [2:0] rx_gain;
 reg [1:0] tx_gain;
 reg [31:0] rx_energy_floor, rx_min_energy;
 reg [7:0] rx_min_plateau;
 reg [11:0] rx_blank;
 reg [5:0] rx_backoff;
 reg [9:0] rx_guard;
 reg tx_go, snap;
 reg [10:0] tx_mask, tx_mask_burst;
 reg rx_blind_en, rx_metric_en, rx_metric_freeze, metric_clear;
 reg m_rd_req, m_rd_cancel, m_rd_timeout;
 reg [8:0] m_rd_addr;
 reg [5:0] r_wait_count;
 wire metric_busy, m_rd_valid;
 wire [31:0] m_rd_data, syms_hdr, syms_pay;
 reg [20:0] rx_hdr_thr;
 `include "ofdm_nc_map.vh"

 // ------------------------------------------------------------ TX control
 localparam [2:0] T_IDLE = 0, T_RESET = 1, T_WAIT = 2, T_RUN = 3, T_START = 4;
 reg [2:0] tstate;
 reg [5:0] tcount;
 reg tx_path_reset, run_phy, prbs_start;
 wire tx_arst = modem_arst | tx_path_reset | tx_soft_reset;
 wire run_tx;
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  run_tx_cdc(.src_clk(clk),.src_in(run_phy),.dest_clk(tx_clk),.dest_out(run_tx));
 wire tx_ready_phy, tx_ready_tx, tx_ready_tx_phy, tx_prefilled, tx_done_tx, tx_aborted_tx;
 wire tx_done_phy, tx_aborted_phy, tx_fault_phy, tx_fault_tx, tx_fault_tx_phy, tx_frame_fault;
 wire tx_underflow;
 // Register combined READY/FAULT in TX before feedback; local TX gates stay immediate.
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  ready_tx_cdc(.src_clk(tx_clk),.src_in(tx_ready_tx),.dest_clk(clk),.dest_out(tx_ready_tx_phy));
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(0),.INIT_SYNC_FF(0))
  done_tx_cdc(.src_clk(tx_clk),.src_in(tx_done_tx),.dest_clk(clk),.dest_out(tx_done_phy));
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(0),.INIT_SYNC_FF(0))
  aborted_tx_cdc(.src_clk(tx_clk),.src_in(tx_aborted_tx),.dest_clk(clk),.dest_out(tx_aborted_phy));
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  fault_tx_cdc(.src_clk(tx_clk),.src_in(tx_fault_tx),.dest_clk(clk),.dest_out(tx_fault_tx_phy));
 always @(posedge clk or posedge reg_arst) begin
  if (reg_arst) begin
   tstate <= T_IDLE; tcount <= 0; tx_path_reset <= 1; run_phy <= 0; prbs_start <= 0;
   tx_mask_burst <= 0;
  end else begin
   prbs_start <= 0;
   if (tx_go) begin
    // A new burst always starts from a shared TX reset (one burst per reset).
    tstate <= T_RESET; tcount <= 0; tx_path_reset <= 1; run_phy <= 0;
    // The whole TX frame chain is in reset from here, so the mask is stable
    // before any frame is prepared.
    tx_mask_burst <= tx_mask;
   end else case (tstate)
    T_RESET: begin
     tcount <= tcount + 1'b1;
     if (tcount == 6'd63) begin tx_path_reset <= 0; tcount <= 0; tstate <= T_WAIT; end
    end
    T_WAIT: begin
     // The prefill locks its quota only after the configuration has been
     // stable for several ready edges before run; wait 16 ready edges.
     if (tx_ready_phy && tx_ready_tx_phy) tcount <= tcount + 1'b1; else tcount <= 0;
     if (tcount == 6'd16) begin run_phy <= 1; tcount <= 0; tstate <= T_START; end
    end
    T_START: begin
     // Let run_tx cross and the quota lock before issuing descriptors.
     tcount <= tcount + 1'b1;
     if (tcount == 6'd31) begin prbs_start <= 1; tstate <= T_RUN; end
    end
    default: ;
   endcase
  end
 end
 // Registered TX path resets only; masks the developer TX route in the boundary.
 assign session_arst = tx_path_reset | tx_soft_reset;

 // ---------------------------------------------------------------- TX chain
 // global_arst comes from the 200 MHz reset generator (same clock as this
 // logic); it also keeps the vendor transform models out of X before the XPM
 // synchronisers settle.  The foreign-clock RF resets never reach these gates.
 wire tx_phy_resetn = tx_ready_phy && !global_arst;
 wire src_busy, cmd_valid, cmd_ready, p_valid, p_ready, p_last;
 wire [31:0] src_issued, cmd_id;
 wire [12:0] cmd_len;
 wire [1:0] cmd_mcs;
 wire [15:0] cmd_epoch;
 wire [7:0] p_data;
 ofdm_tx_prbs_source source (.clk(clk), .resetn(tx_phy_resetn), .start(prbs_start),
  .cfg_frames(tx_frames), .cfg_first_id(tx_first_id), .cfg_payload_len(tx_len), .cfg_mcs(tx_mcs),
  .cfg_epoch(tx_epoch), .busy(src_busy), .frames_issued(src_issued),
  .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_frame_id(cmd_id), .cmd_payload_len(cmd_len),
  .cmd_mcs(cmd_mcs), .cmd_config_epoch(cmd_epoch),
  .m_axis_tdata(p_data), .m_axis_tvalid(p_valid), .m_axis_tready(p_ready), .m_axis_tlast(p_last));
 wire [31:0] tx_samples, tx_queued, tx_descriptors, tx_i_raw, tx_q_raw;
 ofdm_tx_rf_frame_v2 tx (
  .arst(tx_arst),.phy_hold(global_arst),.phy_clk(clk),.tx_clk(tx_clk),.run_phy(run_phy),.run_tx(run_tx),.cfg_frames(tx_frames),
  .cfg_mask(tx_mask_burst),
  .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_frame_id(cmd_id),
  .cmd_payload_len(cmd_len),.cmd_mcs(cmd_mcs),.cmd_config_epoch(cmd_epoch),
  .s_axis_tdata(p_data),.s_axis_tvalid(p_valid),.s_axis_tready(p_ready),.s_axis_tlast(p_last),
  .request_tx(dev_request_tx),.dac_i_tx(tx_i_raw),.dac_q_tx(tx_q_raw),.dac_last_tx(),.dac_user0_tx(),.dac_user1_tx(),
  .response_tx(),.underflow_tx(tx_underflow),.ready_phy(tx_ready_phy),.ready_tx(tx_ready_tx),
  .prefilled_phy(tx_prefilled),.active_tx(),.done_tx(tx_done_tx),.aborted_tx(tx_aborted_tx),.pair_valid_tx(),
  .fault_phy(tx_fault_phy),.fault_tx(tx_fault_tx),.partial_pending_phy(),
  .sample_count_phy(tx_samples),.pair_count_phy(),.partial_drop_count_phy(),.bad_user_count_phy(),
  .frames_queued_phy(tx_queued),.frames_retired_tx(),.pairs_retired_tx(),
  .underflow_count_tx(),.request_count_tx(),.request_mismatch_count_tx(boundary_mismatch_count_tx),
  .frame_fault_phy(tx_frame_fault),.descriptors_accepted_phy(tx_descriptors));
 // TX digital gain: <<tx_gain (x1/x2/x4/x8) with saturation, one tx_clk register.
 // The DAC valid is continuous at this profile, so the extra register only
 // delays the stream by one sample pair; idle and reset zeros stay zero.
 wire [1:0] tx_gain_tx;
 xpm_cdc_array_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0),.WIDTH(2))
  tx_gain_cdc(.src_clk(clk),.src_in(tx_gain),.dest_clk(tx_clk),.dest_out(tx_gain_tx));
 function [15:0] gain_sat;
  input [15:0] x;
  input [1:0] sh;
  reg signed [18:0] y;
  begin
   y = $signed({{3{x[15]}}, x}) <<< sh;
   gain_sat = y > 19'sd32767 ? 16'h7fff : (y < -19'sd32768 ? 16'h8000 : y[15:0]);
  end
 endfunction
 always @(posedge tx_clk) begin
  dev_i_tx <= {gain_sat(tx_i_raw[31:16], tx_gain_tx), gain_sat(tx_i_raw[15:0], tx_gain_tx)};
  dev_q_tx <= {gain_sat(tx_q_raw[31:16], tx_gain_tx), gain_sat(tx_q_raw[15:0], tx_gain_tx)};
 end
 assign dev_underflow_tx = tx_underflow;
 assign retained_boundary_faults = 32'd0;

 // ---------------------------------------------------------------- RX chain
 wire rx_path_arst = modem_arst | rx_soft_reset | !rx_enable;
 wire rx_core_arst;
 xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.INIT_SYNC_FF(1),.RST_ACTIVE_HIGH(1))
  rx_core_reset_cdc(.src_arst(rx_path_arst),.dest_clk(clk),.dest_arst(rx_core_arst));
 // The adapter counts every sample offered while running as accepted or lost,
 // so it only runs once its FIFO has left reset (ready_rx, rx_clk domain).
 wire run_rx;
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  run_rx_cdc(.src_clk(clk),.src_in(rx_enable),.dest_clk(rx_clk),.dest_out(run_rx));
 // ------------------------------------------------ PL digital loopback
 // CTRL[4]: the RX adapter takes the DAC sample pairs (tx_clk, 2 samples per
 // beat) instead of the ADC (rx_clk, 1 sample per beat).  Both clocks come
 // from the same device clock, so one pair is read every second rx_clk edge.
 // Change CTRL[4] only while RX is disabled.
 wire loopback_tx, loopback_rx;
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  loopback_tx_cdc(.src_clk(clk),.src_in(loopback),.dest_clk(tx_clk),.dest_out(loopback_tx));
 xpm_cdc_single #(.DEST_SYNC_FF(4),.SRC_INPUT_REG(1),.INIT_SYNC_FF(0))
  loopback_rx_cdc(.src_clk(clk),.src_in(loopback),.dest_clk(rx_clk),.dest_out(loopback_rx));
 wire [63:0] lb_dout;
 wire lb_full, lb_empty, lb_ready_wr, lb_ready_rd;
 reg lb_phase, lb_started;
 reg [63:0] lb_pair;
 reg [4:0] lb_fill;
 wire lb_rd = loopback_rx && lb_ready_rd && !lb_empty && !lb_phase && lb_started;
 ofdm_async_fifo #(.WIDTH(64), .DEPTH(512)) loop_fifo (
  .arst(rx_path_arst | !loopback), .wr_clk(tx_clk), .rd_clk(rx_clk),
  .din({dev_q_tx, dev_i_tx}), .wr_en(loopback_tx && lb_ready_wr && !lb_full),
  .rd_en(lb_rd), .dout(lb_dout), .full(lb_full), .empty(lb_empty),
  .ready_wr(lb_ready_wr), .ready_rd(lb_ready_rd), .reset_wr(), .reset_rd());
 reg [15:0] lb_i, lb_q;
 always @(posedge rx_clk) begin
  if (!loopback_rx) begin
   lb_phase <= 0; lb_started <= 0; lb_fill <= 0; lb_i <= 0; lb_q <= 0;
  end else begin
   // start once a few pairs are queued, then alternate sample0/sample1
   if (!lb_started) begin
    if (lb_ready_rd && !lb_empty) lb_fill <= lb_fill + 1'b1;
    if (lb_fill == 5'd16) lb_started <= 1;
   end else begin
    lb_phase <= ~lb_phase;
    if (lb_rd) begin lb_pair <= lb_dout; lb_i <= lb_dout[15:0]; lb_q <= lb_dout[47:32]; end
    else if (lb_phase) begin lb_i <= lb_pair[31:16]; lb_q <= lb_pair[63:48]; end
    else begin lb_i <= 0; lb_q <= 0; end
   end
  end
 end
 wire [15:0] adc_i = loopback_rx ? lb_i : rf_i_rx;
 wire [15:0] adc_q = loopback_rx ? lb_q : rf_q_rx;
 wire [1:0] adc_valid = loopback_rx ? {2{lb_started}} : (rf_valid_rx & rf_enable_rx);
 wire [31:0] ad_data;
 wire ad_valid, ad_ready_rx, ad_ready_phy, ad_invalid;
 ofdm_rx_adapter #(.FIFO_DEPTH(512)) adapter (
  .arst(rx_path_arst), .rx_clk(rx_clk), .phy_clk(clk), .run_rx(run_rx && ad_ready_rx), .run_phy(rx_enable),
  .cfg_mask(2'b11), .rf_valid(adc_valid), .rf_i(adc_i), .rf_q(adc_q),
  .rf_last(1'b0), .rf_user(8'd0),
  .m_axis_tdata(ad_data), .m_axis_tlast(), .m_axis_tuser(), .m_axis_tvalid(ad_valid), .m_axis_tready(1'b1),
  .ready_rx(ad_ready_rx), .ready_phy(ad_ready_phy), .fault_rx(), .invalid_phy(ad_invalid), .fault_phy_raw(),
  .seen_count_rx(), .accepted_count_rx(), .lost_count_rx(), .overflow_count_rx(), .mismatch_count_rx(),
  .config_error_count_rx());
 wire st_valid, st_mcs, rx_fault;
 wire [3:0] st_reason;
 wire [31:0] st_frame_id, st_bit_errors, st_compared, st_start, st_step, st_evm;
 wire [14:0] st_carriers;
 wire [12:0] st_len;
 wire [15:0] st_epoch, st_unusable;
 wire [31:0] c_det, c_long, c_busy, c_cand, c_frames, c_over, c_sat, c_tok, c_trej, c_drop, c_cpe, c_samples;
 wire [10:0] st_mask;
 wire [31:0] nc_rx_last, nc_rx_cnt;
 reg [10:0] last_mask;
 wire [3:0] tx_masked = nc_popcount11(tx_mask_burst);
 wire [6:0] tx_carriers = {4'd11 - tx_masked, 3'd0};
 ofdm_rxs_core rx (
  .clk(clk), .resetn(!rx_core_arst && !global_arst), .s_iq(ad_data), .s_valid(ad_valid),
  .cfg_gain_shift(rx_gain), .cfg_energy_floor({7'd0, rx_energy_floor}), .cfg_min_plateau(rx_min_plateau),
  .cfg_blank(rx_blank), .cfg_backoff(rx_backoff), .cfg_guard(rx_guard), .cfg_min_energy(rx_min_energy),
  .cfg_prbs_check(prbs_check), .cfg_blind_en(rx_blind_en), .cfg_hdr_thr(rx_hdr_thr),
  .st_mask(st_mask), .st_rx_last(nc_rx_last), .stat_rx_cnt(nc_rx_cnt),
  .cfg_metric_en(rx_metric_en), .cfg_metric_freeze(rx_metric_freeze), .metric_clear(metric_clear),
  .metric_clear_busy(metric_busy), .metric_rd_addr(m_rd_addr), .metric_rd_req(m_rd_req),
  .metric_rd_cancel(m_rd_cancel),
  .metric_rd_data(m_rd_data), .metric_rd_valid(m_rd_valid), .stat_syms_hdr(syms_hdr), .stat_syms_pay(syms_pay),
  .st_valid(st_valid), .st_reason(st_reason), .st_frame_id(st_frame_id), .st_payload_len(st_len),
  .st_mcs(st_mcs), .st_epoch(st_epoch), .st_bit_errors(st_bit_errors), .st_compared_bits(st_compared),
  .st_unusable(st_unusable), .st_start(st_start), .st_step(st_step),
  .st_evm_sum(st_evm), .st_carriers(st_carriers),
  .stat_detections(c_det), .stat_long_plateaus(c_long), .stat_busy_drops(c_busy), .stat_candidate_drops(c_cand),
  .stat_frames(c_frames), .stat_overruns(c_over), .stat_saturations(c_sat), .stat_train_ok(c_tok),
  .stat_train_reject(c_trej), .stat_dropped_symbols(c_drop), .stat_cpe_undefined(c_cpe),
  .stat_samples(c_samples), .fault(rx_fault));

 // ------------------------------------------------------ frame statistics
 reg [31:0] n_hdr_fail, n_crc_ok, n_crc_fail, n_trunc, n_ok_qpsk, n_ok_16qam;
 reg [63:0] bit_err, bits_cmp;
 reg [31:0] last_id, last_ber, last_step, last_start, last_info, last_evm, evm_cum, carriers_cum;
 always @(posedge clk) begin
  if (rx_core_arst) begin
   n_hdr_fail <= 0; n_crc_ok <= 0; n_crc_fail <= 0; n_trunc <= 0; n_ok_qpsk <= 0; n_ok_16qam <= 0;
   bit_err <= 0; bits_cmp <= 0; last_id <= 0; last_ber <= 0; last_step <= 0; last_start <= 0; last_info <= 0;
   last_evm <= 0; evm_cum <= 0; carriers_cum <= 0; last_mask <= 0;
  end else if (st_valid) begin
   last_mask <= st_mask;
   case (st_reason)
    4'd0: begin
     n_crc_ok <= n_crc_ok + 1'b1;
     if (st_mcs) n_ok_16qam <= n_ok_16qam + 1'b1; else n_ok_qpsk <= n_ok_qpsk + 1'b1;
    end
    4'd1: n_hdr_fail <= n_hdr_fail + 1'b1;
    4'd2: n_crc_fail <= n_crc_fail + 1'b1;
    default: n_trunc <= n_trunc + 1'b1;
   endcase
   if (st_reason != 4'd1) begin
    bit_err <= bit_err + st_bit_errors; bits_cmp <= bits_cmp + st_compared;
   end
   last_id <= st_frame_id; last_ber <= st_bit_errors; last_step <= st_step; last_start <= st_start;
   // Quality for the adaptive policy: only frames with a valid header carry payload EVM.
   if (st_reason != 4'd1) begin
    last_evm <= st_evm; evm_cum <= evm_cum + st_evm; carriers_cum <= carriers_cum + st_carriers;
   end
   last_info <= {st_unusable[7:0], st_reason, 2'd0, st_mcs, st_len, 4'd0};
  end
 end

 // ------------------------------------------------------- snapshot block
 localparam NS = 32;
 reg [31:0] shadow [0:NS-1];
 // Word i is read at 0x080 + 4*i (see docs/interfaces/lean_core_registers_2026-10-21.md).
 wire [32*NS-1:0] live = {
  last_evm, carriers_cum, evm_cum, c_drop, n_ok_16qam, n_ok_qpsk, last_start, last_step,
  last_ber, last_info, last_id, c_samples, c_cpe, c_long, c_cand, c_sat, c_over,
  bits_cmp[63:32], bits_cmp[31:0], bit_err[63:32], bit_err[31:0], n_trunc, n_crc_fail, n_crc_ok, n_hdr_fail,
  c_trej, c_tok, c_frames, c_det, tx_samples, tx_queued, src_issued};
 integer k;
 always @(posedge clk) if (snap) for (k = 0; k < NS; k = k + 1) shadow[k] <= live[32*k +: 32];

 wire [31:0] status_word = {16'd0, tstate, 1'b0, rx_fault, ad_invalid, ad_ready_phy, tx_frame_fault,
  tx_fault_tx_phy, tx_fault_phy, tx_aborted_phy, tx_done_phy, tx_prefilled, tx_ready_phy, run_phy, src_busy};

 always @(posedge clk or posedge reg_arst) begin
  if (reg_arst) begin
   aw_pending <= 0; w_pending <= 0; b_valid <= 0; r_valid <= 0; aw_addr <= 0; ar_addr <= 0;
   w_data <= 0; r_data <= 0; tx_go <= 0; snap <= 0;
   rx_metric_en <= 0; rx_metric_freeze <= 0; metric_clear <= 0;
   m_rd_req <= 0; r_wait <= 0; m_rd_addr <= 0; r_wait_count <= 0; m_rd_cancel <= 0; m_rd_timeout <= 0;
   rx_enable <= 0; prbs_check <= 1; rx_soft_reset <= 0; tx_soft_reset <= 0; loopback <= 0;
   tx_frames <= 16'd8; tx_first_id <= 32'd1; tx_len <= 13'd256; tx_mcs <= 0; tx_epoch <= 0;
   rx_gain <= 3'd0; tx_gain <= 2'd0; rx_energy_floor <= 32'd524288; rx_min_energy <= 32'd1048576;
   rx_min_plateau <= 8'd12; rx_blank <= 12'd720; rx_backoff <= 6'd10; rx_guard <= 10'd448;
   tx_mask <= 0; rx_blind_en <= 1; rx_hdr_thr <= 21'd185360;
  end else begin
   tx_go <= 0; snap <= 0; metric_clear <= 0; m_rd_req <= 0; m_rd_cancel <= 0;
   if (r_wait) begin
    // Metric window read: wait for the RX metric block (bounded).
    r_wait_count <= r_wait_count + 1'b1;
    if (m_rd_valid || rx_core_arst || r_wait_count == 6'd63) begin
     r_data <= (m_rd_valid && !rx_core_arst) ? m_rd_data : 32'd0;
     r_valid <= 1; r_wait <= 0;
     // Abandon the request at the metric block so that its late response cannot be
     // taken by the next read (independent review F1); flag the timeout for the PS.
     if (!m_rd_valid) begin m_rd_cancel <= 1; m_rd_timeout <= 1; end
    end
   end
   if (s_axi_awvalid && s_axi_awready) begin aw_pending <= 1; aw_addr <= s_axi_awaddr[11:0]; end
   if (s_axi_wvalid && s_axi_wready) begin w_pending <= 1; w_data <= s_axi_wdata; end
   if (do_write) begin
    aw_pending <= 0; w_pending <= 0; b_valid <= 1;
    case (aw_addr[11:2])
     10'h002: {loopback, tx_soft_reset, rx_soft_reset, prbs_check, rx_enable} <= w_data[4:0];
     10'h003: tx_go <= w_data[0];
     10'h004: tx_frames <= w_data[15:0];
     10'h005: tx_first_id <= w_data;
     10'h006: tx_len <= w_data[12:0];
     10'h007: tx_mcs <= w_data[0];
     10'h008: tx_epoch <= w_data[15:0];
     10'h009: rx_gain <= w_data[2:0];
     10'h00A: rx_energy_floor <= w_data;
     10'h00B: rx_min_energy <= w_data;
     10'h00C: {rx_backoff, rx_blank, rx_min_plateau} <= w_data[25:0];
     10'h00D: rx_guard <= w_data[9:0];
     10'h00E: tx_gain <= w_data[1:0];
     10'h010: snap <= w_data[0];
     10'h012: tx_mask <= w_data[10:0];
     10'h013: {rx_metric_freeze, rx_metric_en, rx_blind_en} <= w_data[26:24];
     10'h015: begin metric_clear <= w_data[0]; if (w_data[9]) m_rd_timeout <= 0; end
     10'h014: rx_hdr_thr <= w_data[20:0];
     default: ;
    endcase
   end
   if (b_valid && s_axi_bready) b_valid <= 0;
   if (s_axi_arvalid && s_axi_arready && s_axi_araddr[11:9] != 3'd0 && s_axi_araddr[11:9] <= 3'd3) begin
    r_wait <= 1; r_wait_count <= 0; m_rd_req <= 1;
    m_rd_addr <= {s_axi_araddr[10:9] - 2'd1, s_axi_araddr[8:2]};
   end else if (s_axi_arvalid && s_axi_arready) begin
    r_valid <= 1;
    case (s_axi_araddr[11:2])
     10'h000: r_data <= 32'h4F464442;              // "OFDB"
     10'h001: r_data <= 32'h20261025;
     10'h002: r_data <= {27'd0, loopback, tx_soft_reset, rx_soft_reset, prbs_check, rx_enable};
     10'h004: r_data <= {16'd0, tx_frames};
     10'h005: r_data <= tx_first_id;
     10'h006: r_data <= {19'd0, tx_len};
     10'h007: r_data <= {31'd0, tx_mcs};
     10'h008: r_data <= {16'd0, tx_epoch};
     10'h009: r_data <= {29'd0, rx_gain};
     10'h00A: r_data <= rx_energy_floor;
     10'h00B: r_data <= rx_min_energy;
     10'h00C: r_data <= {6'd0, rx_backoff, rx_blank, rx_min_plateau};
     10'h00D: r_data <= {22'd0, rx_guard};
     10'h00E: r_data <= {30'd0, tx_gain};
     10'h011: r_data <= status_word;
     10'h012: r_data <= {21'd0, tx_mask};
     10'h013: r_data <= {5'd0, rx_metric_freeze, rx_metric_en, rx_blind_en, 24'd0};
     10'h015: r_data <= {22'd0, m_rd_timeout, metric_busy, 8'd0};
     10'h016: r_data <= syms_hdr;
     10'h017: r_data <= syms_pay;
     10'h014: r_data <= {11'd0, rx_hdr_thr};
     10'h018: r_data <= nc_rx_last;
     10'h019: r_data <= nc_rx_cnt;
     10'h01A: r_data <= {13'd0, tx_carriers, tx_masked > 4'd3, tx_mask_burst};
     10'h01B: r_data <= {21'd0, last_mask};
     default: r_data <= s_axi_araddr[11:7] == 5'd1 ? shadow[s_axi_araddr[6:2]] : 32'd0;  // 0x080..0x0FC
    endcase
   end
   if (r_valid && s_axi_rready) r_valid <= 0;
  end
 end
endmodule
`default_nettype wire
