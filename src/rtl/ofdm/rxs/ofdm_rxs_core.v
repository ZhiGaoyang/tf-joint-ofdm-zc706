`timescale 1ns/1ps
// Route-B streaming OFDM receiver core (protocol V0.2).  One sample per
// s_valid, no input backpressure.  All modules run in the PHY clock domain.
// NC extension: decoder candidate masks/blind detection (cfg_blind_en,
// cfg_hdr_thr) and the accepted frame mask in each status record (st_mask).
//   ingress gain -> ring ------------------------------> fetch -> fft -> chan -> cpe -> decode
//                -> dc block -> detect -> candidates -^     ^------- feedback (limit/abort) --'
module ofdm_rxs_core #(parameter SIN_ROM_FILE = "ofdm_cfo_sine_quarter.mem") (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_iq,
    input wire s_valid,
    // configuration (static while running)
    input wire [2:0] cfg_gain_shift,
    input wire [38:0] cfg_energy_floor,
    input wire [7:0] cfg_min_plateau,
    input wire [11:0] cfg_blank,
    input wire [5:0] cfg_backoff,
    input wire [9:0] cfg_guard,
    input wire [31:0] cfg_min_energy,
    input wire cfg_prbs_check,
    input wire cfg_blind_en,
    input wire [20:0] cfg_hdr_thr,
    input wire cfg_metric_en,
    input wire cfg_metric_freeze,
    input wire metric_clear,
    output wire metric_clear_busy,
    input wire [8:0] metric_rd_addr,
    input wire metric_rd_req,
    input wire metric_rd_cancel,
    output wire [31:0] metric_rd_data,
    output wire metric_rd_valid,
    output wire [31:0] stat_syms_hdr,
    output wire [31:0] stat_syms_pay,
    // frame status record
    output reg st_valid,
    output reg [3:0] st_reason,
    output reg [31:0] st_frame_id,
    output reg [12:0] st_payload_len,
    output reg st_mcs,
    output reg [15:0] st_epoch,
    output reg [31:0] st_bit_errors,
    output reg [31:0] st_compared_bits,
    output reg [15:0] st_unusable,
    output reg [31:0] st_start,
    output reg [31:0] st_step,
    output reg [31:0] st_evm_sum,     // sum |e|^2 (F14) >> 16 over payload carriers
    output reg [14:0] st_carriers,
    output reg [10:0] st_mask,
    output wire [31:0] st_rx_last,
    output wire [31:0] stat_rx_cnt,
    // statistics
    output wire [31:0] stat_detections,
    output wire [31:0] stat_long_plateaus,
    output wire [31:0] stat_busy_drops,
    output reg [31:0] stat_candidate_drops,
    output wire [31:0] stat_frames,
    output wire [31:0] stat_overruns,
    output wire [31:0] stat_saturations,
    output wire [31:0] stat_train_ok,
    output wire [31:0] stat_train_reject,
    output wire [31:0] stat_dropped_symbols,
    output wire [31:0] stat_cpe_undefined,
    output wire [31:0] stat_samples,
    output wire fault
);
    // -------------------------------------------------------------- ingress
    function [15:0] shift_sat;
        input signed [15:0] x;
        input [2:0] sh;
        reg signed [23:0] y;
        begin
            y = $signed({{8{x[15]}}, x}) <<< sh;
            shift_sat = y > 24'sd32767 ? 16'h7fff : (y < -24'sd32768 ? 16'h8000 : y[15:0]);
        end
    endfunction
    reg [31:0] iq0;
    reg v0;
    always @(posedge clk) begin
        if (!resetn) v0 <= 0; else v0 <= s_valid;
        iq0 <= {shift_sat(s_iq[31:16], cfg_gain_shift), shift_sat(s_iq[15:0], cfg_gain_shift)};
    end
    wire [31:0] min_energy = cfg_min_energy < 32'd1048576 ? 32'd1048576 : cfg_min_energy;

    // ----------------------------------------------------------------- ring
    wire [31:0] wr_index;
    wire rd_en;
    wire [31:0] rd_index, rd_data;
    ofdm_rxs_ring ring (.clk(clk), .resetn(resetn), .s_iq(iq0), .s_valid(v0), .wr_index(wr_index),
        .rd_en(rd_en), .rd_index(rd_index), .rd_data(rd_data));
    assign stat_samples = wr_index;

    // --------------------------------------------------------------- detect
    wire [31:0] dc_iq;
    wire dc_valid;
    ofdm_rxs_dcblock dcblock (.clk(clk), .resetn(resetn), .s_iq(iq0), .s_valid(v0),
        .m_iq(dc_iq), .m_valid(dc_valid));
    wire det_valid;
    wire [31:0] det_start;
    wire signed [31:0] det_step;
    ofdm_rxs_detect detect (.clk(clk), .resetn(resetn), .s_iq(dc_iq), .s_valid(dc_valid),
        .cfg_energy_floor(cfg_energy_floor), .cfg_min_plateau(cfg_min_plateau), .cfg_blank(cfg_blank),
        .m_valid(det_valid), .m_start(det_start), .m_step(det_step),
        .stat_detections(stat_detections), .stat_long_plateaus(stat_long_plateaus),
        .stat_busy_drops(stat_busy_drops));

    // ------------------------------------------------------- candidate FIFO
    reg [63:0] cand [0:3];
    reg [1:0] cand_wr, cand_rd;
    reg [2:0] cand_count;
    wire cand_pop;
    wire cand_push = det_valid && cand_count != 3'd4;
    always @(posedge clk) begin
        if (!resetn) begin
            cand_wr <= 0; cand_rd <= 0; cand_count <= 0; stat_candidate_drops <= 0;
        end else begin
            if (cand_push) begin cand[cand_wr] <= {det_step, det_start}; cand_wr <= cand_wr + 1'b1; end
            if (det_valid && cand_count == 3'd4) stat_candidate_drops <= stat_candidate_drops + 1'b1;
            if (cand_pop) cand_rd <= cand_rd + 1'b1;
            cand_count <= cand_count + (cand_push ? 1'b1 : 1'b0) - (cand_pop ? 1'b1 : 1'b0);
        end
    end
    wire [63:0] cand_head = cand[cand_rd];

    // ---------------------------------------------------------------- fetch
    wire chan_fb_valid, dec_fb_valid;
    wire [7:0] chan_fb_tag, dec_fb_tag, dec_fb_nsym;
    reg pend_fb;
    reg [7:0] pend_fb_tag;
    // Decoder feedback has priority; a coincident training rejection waits one cycle.
    wire fb_valid = dec_fb_valid || chan_fb_valid || pend_fb;
    wire [7:0] fb_tag = dec_fb_valid ? dec_fb_tag : (pend_fb ? pend_fb_tag : chan_fb_tag);
    wire [7:0] fb_nsym = dec_fb_valid ? dec_fb_nsym : 8'd0;
    always @(posedge clk) begin
        if (!resetn) pend_fb <= 0;
        else if (dec_fb_valid && chan_fb_valid) begin pend_fb <= 1; pend_fb_tag <= chan_fb_tag; end
        else if (!dec_fb_valid && pend_fb && chan_fb_valid) begin pend_fb <= 1; pend_fb_tag <= chan_fb_tag; end
        else if (!dec_fb_valid) pend_fb <= 0;
    end
    wire info_we;
    wire [7:0] info_tag;
    wire [31:0] info_start, info_step;
    wire [31:0] f_data;
    wire [7:0] f_tag, f_sym;
    wire f_last, f_valid, f_ready;
    ofdm_rxs_fetch #(.SIN_ROM_FILE(SIN_ROM_FILE)) fetch (.clk(clk), .resetn(resetn),
        .cfg_backoff(cfg_backoff), .cfg_guard(cfg_guard),
        .cand_valid(cand_count != 0), .cand_start(cand_head[31:0]), .cand_step(cand_head[63:32]),
        .cand_pop(cand_pop), .wr_index(wr_index), .rd_en(rd_en), .rd_index(rd_index), .rd_data(rd_data),
        .fb_valid(fb_valid), .fb_tag(fb_tag), .fb_nsym(fb_nsym),
        .info_we(info_we), .info_tag(info_tag), .info_start(info_start), .info_step(info_step),
        .m_data(f_data), .m_tag(f_tag), .m_sym(f_sym), .m_last(f_last), .m_valid(f_valid), .m_ready(f_ready),
        .stat_frames(stat_frames), .stat_overruns(stat_overruns));
    reg [63:0] info [0:15];
    always @(posedge clk) if (info_we) info[info_tag[3:0]] <= {info_step, info_start};

    // ------------------------------------------------------------------ FFT
    wire [31:0] x_data;
    wire [6:0] x_k;
    wire [7:0] x_tag, x_sym;
    wire x_last, x_valid, x_ready, fft_fault;
    ofdm_rxs_fft fft (.clk(clk), .resetn(resetn), .s_data(f_data), .s_tag(f_tag), .s_sym(f_sym),
        .s_last(f_last), .s_valid(f_valid), .s_ready(f_ready),
        .m_data(x_data), .m_k(x_k), .m_tag(x_tag), .m_sym(x_sym), .m_last(x_last),
        .m_valid(x_valid), .m_ready(x_ready), .stat_saturations(stat_saturations), .fault(fft_fault));

    // -------------------------------------------------------------- channel
    wire [31:0] e_data;
    wire [6:0] e_k;
    wire [7:0] e_tag, e_sym;
    wire e_usable, e_last, e_valid, e_ready, chan_fault;
    ofdm_rxs_chan chan (.clk(clk), .resetn(resetn), .cfg_min_energy(min_energy),
        .s_data(x_data), .s_k(x_k), .s_tag(x_tag), .s_sym(x_sym), .s_last(x_last),
        .s_valid(x_valid), .s_ready(x_ready),
        .m_data(e_data), .m_k(e_k), .m_tag(e_tag), .m_sym(e_sym), .m_usable(e_usable), .m_last(e_last),
        .m_valid(e_valid), .m_ready(e_ready),
        .fb_valid(chan_fb_valid), .fb_tag(chan_fb_tag),
        .stat_train_ok(stat_train_ok), .stat_train_reject(stat_train_reject),
        .stat_dropped_symbols(stat_dropped_symbols), .fault(chan_fault));

    // ------------------------------------------------------------------ CPE
    wire [31:0] c_data;
    wire [7:0] c_tag, c_sym;
    wire c_usable, c_first, c_last, c_valid, c_ready;
    ofdm_rxs_cpe #(.SIN_ROM_FILE(SIN_ROM_FILE)) cpe (.clk(clk), .resetn(resetn),
        .s_data(e_data), .s_k(e_k), .s_tag(e_tag), .s_sym(e_sym), .s_usable(e_usable),
        .s_valid(e_valid), .s_ready(e_ready),
        .m_data(c_data), .m_tag(c_tag), .m_sym(c_sym), .m_usable(c_usable), .m_first(c_first),
        .m_last(c_last), .m_valid(c_valid), .m_ready(c_ready), .stat_cpe_undefined(stat_cpe_undefined));

    // --------------------------------------------------------------- decode
    wire d_valid, d_mcs;
    wire [7:0] d_tag;
    wire [3:0] d_reason;
    wire [31:0] d_frame_id, d_bit_errors, d_compared;
    wire [12:0] d_len;
    wire [15:0] d_epoch, d_unusable;
    wire [31:0] d_evm;
    wire [14:0] d_carriers;
    wire [10:0] d_mask;
    wire cm_valid, cm_qam, cm_null, cm_hdr, cm_usable, cm_sym_last;
    wire [6:0] cm_ord;
    wire [31:0] cm_data;
    ofdm_rxs_cmetric cmetric (.clk(clk), .resetn(resetn), .cfg_enable(cfg_metric_en), .cfg_freeze(cfg_metric_freeze),
        .clear(metric_clear), .clear_busy(metric_clear_busy), .s_valid(cm_valid), .s_ord(cm_ord), .s_data(cm_data),
        .s_qam(cm_qam), .s_null(cm_null), .s_hdr(cm_hdr), .s_usable(cm_usable), .s_sym_last(cm_sym_last),
        .rd_addr(metric_rd_addr), .rd_req(metric_rd_req), .rd_cancel(metric_rd_cancel),
        .rd_data(metric_rd_data), .rd_valid(metric_rd_valid),
        .stat_syms_hdr(stat_syms_hdr), .stat_syms_pay(stat_syms_pay));
    ofdm_rxs_decode decode (.clk(clk), .resetn(resetn), .cfg_prbs_check(cfg_prbs_check),
        .cfg_blind_en(cfg_blind_en), .cfg_hdr_thr(cfg_hdr_thr),
        .st_mask(d_mask), .st_rx_last(st_rx_last), .stat_rx_cnt(stat_rx_cnt),
        .cm_valid(cm_valid), .cm_ord(cm_ord), .cm_data(cm_data), .cm_qam(cm_qam), .cm_null(cm_null),
        .cm_hdr(cm_hdr), .cm_usable(cm_usable), .cm_sym_last(cm_sym_last),
        .s_data(c_data), .s_tag(c_tag), .s_sym(c_sym), .s_usable(c_usable), .s_first(c_first),
        .s_last(c_last), .s_valid(c_valid), .s_ready(c_ready),
        .fb_valid(dec_fb_valid), .fb_tag(dec_fb_tag), .fb_nsym(dec_fb_nsym),
        .st_valid(d_valid), .st_tag(d_tag), .st_reason(d_reason), .st_frame_id(d_frame_id),
        .st_payload_len(d_len), .st_mcs(d_mcs), .st_epoch(d_epoch), .st_bit_errors(d_bit_errors),
        .st_compared_bits(d_compared), .st_unusable(d_unusable),
        .st_evm_sum(d_evm), .st_carriers(d_carriers));
    always @(posedge clk) begin
        if (!resetn) st_valid <= 0;
        else st_valid <= d_valid;
        if (d_valid) begin
            st_reason <= d_reason; st_frame_id <= d_frame_id; st_payload_len <= d_len; st_mcs <= d_mcs;
            st_epoch <= d_epoch; st_bit_errors <= d_bit_errors; st_compared_bits <= d_compared;
            st_unusable <= d_unusable; st_evm_sum <= d_evm; st_carriers <= d_carriers;
            st_mask <= d_mask;
            {st_step, st_start} <= info[d_tag[3:0]];
        end
    end
    assign fault = fft_fault || chan_fault;
endmodule
