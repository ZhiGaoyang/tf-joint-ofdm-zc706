`timescale 1ns/1ps
// Digital TX->RX loopback: PRBS source -> V0.2 TX frame chain (real IFFT) ->
// samples pulled at 384/625 (idle zeros when TX has nothing) -> streaming RX.
// Plusargs: FRAMES, LEN, MCS (0/1), BURSTS (bursts of FRAMES with an idle gap).
// NC copy (rtl/ofdm_nc TX and RX): MASK (bursts 0,2,..), MASK2 (bursts 1,3,..),
// BACKOFF, BLIND, TONE_BIN/TONE_AMP (tone added at the RX input, amplitude in
// LSB).  Before each burst only the TX chain is reset (the core's TX_GO does
// the same), so the carrier loader takes the burst mask; RX is never reset.
// Every OK record must carry the mask of its burst.
module tb_nc_txrx_loop;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg resetn = 0;
    reg tx_resetn = 0;
    integer dump_fd = 0;
    integer mask_a, mask_b, backoff_i, blind_i, tone_bin, tone_amp, mask_bad, quiet;
    reg [10:0] cfg_mask = 0;
    reg [10:0] burst_mask [0:63];
    real tone_phase;
    integer tone_i, tone_q, sum_i, sum_q;
    wire [10:0] st_mask;
    wire [31:0] st_rx_last, stat_rx_cnt;
    integer frames, len, mcs, bursts, b, acc, ok, bad, seen, timeout, limit, tx_cmds, tx_samples, tx_nonzero;
    integer ok_count [0:1023];
    integer id_i, missing;
    reg start = 0;
    wire busy;
    wire [31:0] issued;
    wire cmd_valid, cmd_ready, p_valid, p_ready, p_last;
    wire [31:0] cmd_id;
    wire [12:0] cmd_len;
    wire [1:0] cmd_mcs;
    wire [15:0] cmd_epoch;
    wire [7:0] p_data;
    reg [15:0] cfg_frames;
    reg [12:0] cfg_len;
    reg cfg_mcs;
    reg [31:0] first_id;
    ofdm_tx_prbs_source src (.clk(clk), .resetn(tx_resetn), .start(start), .cfg_frames(cfg_frames),
        .cfg_first_id(first_id), .cfg_payload_len(cfg_len), .cfg_mcs(cfg_mcs), .cfg_epoch(16'd7),
        .busy(busy), .frames_issued(issued), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_frame_id(cmd_id), .cmd_payload_len(cmd_len), .cmd_mcs(cmd_mcs), .cmd_config_epoch(cmd_epoch),
        .m_axis_tdata(p_data), .m_axis_tvalid(p_valid), .m_axis_tready(p_ready), .m_axis_tlast(p_last));
    wire [31:0] tx_data;
    wire tx_valid, tx_last, tx_fault;
    wire [1:0] tx_user;
    reg tx_ready = 0;
    ofdm_tx_frame_v2 tx (.clk(clk), .resetn(tx_resetn), .cfg_mask(cfg_mask), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_frame_id(cmd_id), .cmd_payload_len(cmd_len), .cmd_mcs(cmd_mcs), .cmd_config_epoch(cmd_epoch),
        .s_axis_tdata(p_data), .s_axis_tvalid(p_valid), .s_axis_tready(p_ready), .s_axis_tlast(p_last),
        .m_axis_tdata(tx_data), .m_axis_tvalid(tx_valid), .m_axis_tready(tx_ready),
        .m_axis_tlast(tx_last), .m_axis_tuser(tx_user), .fault(tx_fault));
    reg [31:0] rx_iq = 0;
    reg rx_valid = 0;
    wire st_valid, st_mcs, rx_fault;
    wire [3:0] st_reason;
    wire [31:0] st_frame_id, st_bit_errors, st_compared_bits, st_start, st_step;
    wire [12:0] st_payload_len;
    wire [31:0] st_evm;
    wire [14:0] st_carriers;
    wire [15:0] st_epoch, st_unusable;
    wire [31:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
    ofdm_rxs_core #(.SIN_ROM_FILE("ofdm_cfo_sine_quarter.mem")) rx (
        .clk(clk), .resetn(resetn), .s_iq(rx_iq), .s_valid(rx_valid),
        .cfg_gain_shift(3'd0), .cfg_energy_floor(39'd524288), .cfg_min_plateau(8'd12),
        .cfg_blank(12'd720), .cfg_backoff(backoff_i[5:0]), .cfg_guard(10'd448),
        .cfg_min_energy(32'd1048576), .cfg_prbs_check(1'b1),
        .cfg_blind_en(blind_i[0]), .cfg_hdr_thr(21'd185360),
        .st_mask(st_mask), .st_rx_last(st_rx_last), .stat_rx_cnt(stat_rx_cnt),
        .cfg_metric_en(1'b1), .cfg_metric_freeze(1'b0), .metric_clear(1'b0), .metric_clear_busy(),
        .metric_rd_addr(9'd0), .metric_rd_req(1'b0), .metric_rd_data(), .metric_rd_valid(),
        .stat_syms_hdr(), .stat_syms_pay(),
        .st_valid(st_valid), .st_reason(st_reason), .st_frame_id(st_frame_id),
        .st_payload_len(st_payload_len), .st_mcs(st_mcs), .st_epoch(st_epoch),
        .st_bit_errors(st_bit_errors), .st_compared_bits(st_compared_bits), .st_unusable(st_unusable),
        .st_start(st_start), .st_step(st_step), .st_evm_sum(st_evm), .st_carriers(st_carriers),
        .stat_detections(s0), .stat_long_plateaus(s1), .stat_busy_drops(s2), .stat_candidate_drops(s3),
        .stat_frames(s4), .stat_overruns(s5), .stat_saturations(s6), .stat_train_ok(s7),
        .stat_train_reject(s8), .stat_dropped_symbols(s9), .stat_cpe_undefined(s10),
        .stat_samples(s11), .fault(rx_fault));

    // 122.88 MSPS sample clock emulation: the TX sample is popped in the same
    // cycle that the RX captures it (tick), idle zeros when TX has nothing.
    wire tick = resetn && (acc + 384 >= 625);
    always @(*) tx_ready = tick;
    always @(posedge clk) begin
        if (!resetn) begin acc <= 0; rx_valid <= 0; end
        else begin
            rx_valid <= tick;
            if (tick) begin
                acc <= acc + 384 - 625;
                tone_i = $rtoi(tone_amp * $cos(tone_phase));
                tone_q = $rtoi(tone_amp * $sin(tone_phase));
                tone_phase = tone_phase + 2.0 * 3.14159265358979 * tone_bin / 128.0;
                if (tone_phase > 6.28318530717959) tone_phase = tone_phase - 6.28318530717959;
                sum_i = (tx_valid ? $signed(tx_data[15:0]) : 0) + tone_i;
                sum_q = (tx_valid ? $signed(tx_data[31:16]) : 0) + tone_q;
                if (sum_i > 32767) sum_i = 32767; if (sum_i < -32768) sum_i = -32768;
                if (sum_q > 32767) sum_q = 32767; if (sum_q < -32768) sum_q = -32768;
                rx_iq <= {sum_q[15:0], sum_i[15:0]};
            end else acc <= acc + 384;
        end
    end
    always @(posedge clk) begin
        if (st_valid) begin
            seen = seen + 1;
            // Scoreboard (independent review F11): the ID must be one that was sent, and each sent
            // ID may be accepted exactly once; duplicates and foreign IDs count as bad.
            if (st_reason == 0 && st_bit_errors == 0 && st_payload_len == cfg_len && st_mcs == cfg_mcs &&
                st_compared_bits == 8 * cfg_len && st_epoch == 16'd7 &&
                st_frame_id >= 1000 && st_frame_id < 1000 + frames * bursts &&
                ok_count[st_frame_id - 1000] == 0 &&
                st_mask == burst_mask[(st_frame_id - 1000) / frames]) begin
                ok = ok + 1;
                ok_count[st_frame_id - 1000] = ok_count[st_frame_id - 1000] + 1;
            end else bad = bad + 1;
            $display("RXL_STATUS reason=%0d id=%0d len=%0d mcs=%0d mask=%0d ber=%0d cmp=%0d evm=%0d carriers=%0d src=%0d",
                st_reason, st_frame_id, st_payload_len, st_mcs, st_mask, st_bit_errors, st_compared_bits,
                st_evm, st_carriers, st_rx_last[13:12]);
        end
        if (cmd_valid && cmd_ready) tx_cmds = tx_cmds + 1;
        if ($test$plusargs("DEBUG") && rx.detect.v5 && rx.detect.lo5)
            $display("RXL_LO idx=%0d hi=%0d floor=%0d pp=%0d ee=%0d", rx.detect.idx5, rx.detect.hi5, rx.detect.floor4, rx.detect.pp4, rx.detect.ee4);
        if ($test$plusargs("DEBUG") && rx.detect.metric_valid && rx.detect.metric_index >= 400 && rx.detect.metric_index <= 1300 && rx.detect.metric_index[4:0] == 0)
            $display("RXL_MET idx=%0d e0=%0d e1=%0d ci=%0d cq=%0d | v4=%0d floor4=%0d pp4=%0d ee4=%0d sh=%0d", rx.detect.metric_index, rx.detect.energy_0, rx.detect.energy_1, rx.detect.corr_i, rx.detect.corr_q, rx.detect.v4, rx.detect.floor4, rx.detect.pp4, rx.detect.ee4, rx.detect.shift2);
        if (tx_valid && tx_ready) begin
            if (dump_fd != 0) $fdisplay(dump_fd, "%08x", tx_data);
            tx_samples = tx_samples + 1;
            if (tx_data != 0) tx_nonzero = tx_nonzero + 1;
        end
        if (resetn && tx_resetn && (tx_fault || rx_fault)) $display("RXL_FAULT tx=%0d rx=%0d t=%0t", tx_fault, rx_fault, $time);
    end
    initial begin
        if (!$value$plusargs("FRAMES=%d", frames)) frames = 4;
        if (!$value$plusargs("LEN=%d", len)) len = 64;
        if (!$value$plusargs("MCS=%d", mcs)) mcs = 0;
        if (!$value$plusargs("BURSTS=%d", bursts)) bursts = 2;
        if (!$value$plusargs("TIMEOUT=%d", limit)) limit = 200000;
        if (!$value$plusargs("MASK=%d", mask_a)) mask_a = 0;
        if (!$value$plusargs("MASK2=%d", mask_b)) mask_b = mask_a;
        if (!$value$plusargs("BACKOFF=%d", backoff_i)) backoff_i = 10;
        if (!$value$plusargs("BLIND=%d", blind_i)) blind_i = 1;
        if (!$value$plusargs("TONE_BIN=%d", tone_bin)) tone_bin = 0;
        if (!$value$plusargs("TONE_AMP=%d", tone_amp)) tone_amp = 0;
        tone_phase = 0.0;
        $display("RXL_CONFIG mask=%0d mask2=%0d backoff=%0d blind=%0d tone_bin=%0d tone_amp=%0d", mask_a, mask_b,
            backoff_i, blind_i, tone_bin, tone_amp);
        if ($test$plusargs("DUMP")) dump_fd = $fopen("tx_dump.mem", "w");
        ok = 0; bad = 0; seen = 0; tx_cmds = 0; tx_samples = 0; tx_nonzero = 0;
        for (id_i = 0; id_i < 1024; id_i = id_i + 1) ok_count[id_i] = 0;
        cfg_frames = frames; cfg_len = len; cfg_mcs = mcs; first_id = 32'd1000;
        repeat (20) @(posedge clk);
        resetn <= 1;
        repeat (200) @(posedge clk);
        for (b = 0; b < bursts; b = b + 1) begin
            burst_mask[b] = (b % 2) ? mask_b : mask_a;
            // Like the core (TX_GO after the previous burst completed): reset the
            // TX chain only after its output has been idle for 2000 cycles.
            quiet = 0;
            while (quiet < 2000) begin @(posedge clk); quiet = tx_valid ? 0 : quiet + 1; end
            @(posedge clk); tx_resetn <= 0; cfg_mask <= burst_mask[b];
            repeat (8) @(posedge clk); tx_resetn <= 1;
            repeat (8) @(posedge clk);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            @(posedge clk);
            while (busy) @(posedge clk);
            // idle gap between bursts
            repeat (3000) @(posedge clk);
            first_id = first_id + frames;
        end
        timeout = 0;
        while (seen < frames * bursts && timeout < limit) begin @(posedge clk); timeout = timeout + 1; end
        repeat (2000) @(posedge clk);
        $display("RXL_RESULT ok=%0d bad=%0d seen=%0d expected=%0d detections=%0d overruns=%0d saturations=%0d tx_cmds=%0d tx_samples=%0d tx_nonzero=%0d long_plateaus=%0d candidate_drops=%0d blind_hits=%0d zero_hits=%0d",
            ok, bad, seen, frames * bursts, s0, s5, s6, tx_cmds, tx_samples, tx_nonzero, s1, s3,
            stat_rx_cnt[15:0], stat_rx_cnt[31:16]);
        missing = 0;
        for (id_i = 0; id_i < frames * bursts; id_i = id_i + 1) if (ok_count[id_i] != 1) missing = missing + 1;
        $display("RXL_SCOREBOARD expected_ids=%0d missing_or_repeated=%0d", frames * bursts, missing);
        if (ok == frames * bursts && bad == 0 && missing == 0) $display("RXL_PASS"); else $display("RXL_FAIL");
        $finish;
    end
endmodule
