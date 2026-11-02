`timescale 1ns/1ps
// Host testbench for ofdm_rxs_core: replays a generated IQ stream at the
// 384/625 valid ratio (122.88 MSPS into a 200 MHz PHY clock), logs every frame
// status record and the final statistics.  Checking is done by
// scripts/model/rxs_check.py against the generator's expected.json.
// NC copy: drives cfg_blind_en (+BLIND, default 1) and cfg_hdr_thr (+HDRTHR),
// logs the frame mask; checked by scripts/model/nc_rxs_check.py.
module tb_nc_rxs_core;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg resetn = 0;
    reg [31:0] s_iq = 0;
    reg s_valid = 0;
    reg [2:0] gain_shift = 0;
    reg prbs_check = 1;
    reg blind_en = 1;
    reg [20:0] hdr_thr = 21'd185360;
    reg [5:0] backoff = 6'd10;
    wire [10:0] st_mask;
    wire [31:0] st_rx_last, stat_rx_cnt;
    integer nsamp, tail, i, acc, cycles, gap_den, gap_num, reset_at, stale_at;
    reg [8*256-1:0] stream_path;
    reg [31:0] stream [0:2097151];

    wire st_valid, st_mcs, fault;
    wire [3:0] st_reason;
    wire [31:0] st_frame_id, st_bit_errors, st_compared_bits, st_start, st_step;
    wire [12:0] st_payload_len;
    wire [31:0] st_evm;
    wire [14:0] st_carriers;
    wire [15:0] st_epoch, st_unusable;
    wire [31:0] stat_detections, stat_long_plateaus, stat_busy_drops, stat_candidate_drops,
        stat_frames, stat_overruns, stat_saturations, stat_train_ok, stat_train_reject,
        stat_dropped_symbols, stat_cpe_undefined, stat_samples;

    ofdm_rxs_core #(.SIN_ROM_FILE("ofdm_cfo_sine_quarter.mem")) dut (
        .clk(clk), .resetn(resetn), .s_iq(s_iq), .s_valid(s_valid),
        .cfg_gain_shift(gain_shift), .cfg_energy_floor(39'd524288), .cfg_min_plateau(8'd12),
        .cfg_blank(12'd720), .cfg_backoff(backoff), .cfg_guard(10'd448),
        .cfg_min_energy(32'd1048576), .cfg_prbs_check(prbs_check),
        .cfg_blind_en(blind_en), .cfg_hdr_thr(hdr_thr),
        .st_mask(st_mask), .st_rx_last(st_rx_last), .stat_rx_cnt(stat_rx_cnt),
        .cfg_metric_en(1'b1), .cfg_metric_freeze(1'b0), .metric_clear(1'b0), .metric_clear_busy(),
        .metric_rd_addr(9'd0), .metric_rd_req(1'b0), .metric_rd_data(), .metric_rd_valid(),
        .stat_syms_hdr(), .stat_syms_pay(),
        .st_valid(st_valid), .st_reason(st_reason), .st_frame_id(st_frame_id),
        .st_payload_len(st_payload_len), .st_mcs(st_mcs), .st_epoch(st_epoch),
        .st_bit_errors(st_bit_errors), .st_compared_bits(st_compared_bits), .st_unusable(st_unusable),
        .st_start(st_start), .st_step(st_step), .st_evm_sum(st_evm), .st_carriers(st_carriers),
        .stat_detections(stat_detections), .stat_long_plateaus(stat_long_plateaus),
        .stat_busy_drops(stat_busy_drops), .stat_candidate_drops(stat_candidate_drops),
        .stat_frames(stat_frames), .stat_overruns(stat_overruns), .stat_saturations(stat_saturations),
        .stat_train_ok(stat_train_ok), .stat_train_reject(stat_train_reject),
        .stat_dropped_symbols(stat_dropped_symbols), .stat_cpe_undefined(stat_cpe_undefined),
        .stat_samples(stat_samples), .fault(fault));

    always @(posedge clk) begin
        if (st_valid)
            $display("RXS_STATUS reason=%0d id=%0d len=%0d mcs=%0d mask=%0d epoch=%0d ber=%0d cmp=%0d unusable=%0d start=%0d step=%0d evm=%0d carriers=%0d src=%0d blind=%0d t=%0t",
                st_reason, st_frame_id, st_payload_len, st_mcs, st_mask, st_epoch, st_bit_errors, st_compared_bits,
                st_unusable, st_start, $signed(st_step), st_evm, st_carriers, st_rx_last[13:12], st_rx_last[26:16], $time);
        if (dut.det_valid)
            $display("RXS_DETECT start=%0d step=%0d t=%0t", dut.det_start, $signed(dut.det_step), $time);
        if (dut.chan.d4)
            $display("RXS_TRAINQ tag=%0d c_re=%0d c_im=%0d s=%0d shift=%0d cc=%0d ss=%0d accept=%0d",
                dut.chan.q_tag, dut.chan.c_re, dut.chan.c_im, dut.chan.s_sum, dut.chan.qs,
                dut.chan.cc, dut.chan.ss, dut.chan.q_accept);
        if (resetn && fault) begin
            $display("RXS_FAULT t=%0t", $time);
        end
    end

    initial begin
        if (!$value$plusargs("STREAM=%s", stream_path)) $fatal(1, "missing +STREAM");
        if (!$value$plusargs("NSAMP=%d", nsamp)) $fatal(1, "missing +NSAMP");
        if (!$value$plusargs("GAIN=%d", gain_shift)) gain_shift = 0;
        if (!$value$plusargs("PRBS=%d", prbs_check)) prbs_check = 1;
        if (!$value$plusargs("BLIND=%d", blind_en)) blind_en = 1;
        if (!$value$plusargs("HDRTHR=%d", hdr_thr)) hdr_thr = 21'd185360;
        if (!$value$plusargs("BACKOFF=%d", backoff)) backoff = 6'd10;
        $display("RXS_CONFIG blind=%0d hdr_thr=%0d backoff=%0d gain=%0d", blind_en, hdr_thr, backoff, gain_shift);
        // Optional mid-stream reset at a sample index (recovery test).
        if (!$value$plusargs("RESET_AT=%d", reset_at)) reset_at = -1;
        // Optional: make the last blank look 2^31+1000 samples old, as after a
        // long idle period (>17.5 s at 122.88 MSPS) in which the index wrapped.
        if (!$value$plusargs("STALE_BLANK_AT=%d", stale_at)) stale_at = -1;
        $readmemh(stream_path, stream, 0, nsamp - 1);
        tail = 8000;
        repeat (20) @(posedge clk);
        resetn <= 1;
        repeat (40) @(posedge clk);
        acc = 0; i = 0; cycles = 0;
        while (i < nsamp + tail) begin
            @(posedge clk);
            acc = acc + 384;
            if (acc >= 625) begin
                acc = acc - 625;
                s_valid <= 1;
                s_iq <= i < nsamp ? stream[i] : 32'd0;
                i = i + 1;
                if (i == stale_at) begin
                    dut.detect.blank_until = dut.detect.idx5 - 32'h800003E8;
                    $display("RXS_STALE_BLANK sample=%0d blank_until=%0d have_blank=%0d t=%0t", i, dut.detect.blank_until, dut.detect.have_blank, $time);
                end
                if (i == reset_at) begin
                    s_valid <= 0; resetn <= 0;
                    repeat (8) @(posedge clk);
                    resetn <= 1;
                    $display("RXS_RESET sample=%0d t=%0t", i, $time);
                end
            end else s_valid <= 0;
        end
        s_valid <= 0;
        repeat (4000) @(posedge clk);
        $display("RXS_STATS samples=%0d detections=%0d long_plateaus=%0d busy_drops=%0d candidate_drops=%0d frames=%0d overruns=%0d saturations=%0d train_ok=%0d train_reject=%0d dropped_symbols=%0d cpe_undefined=%0d",
            stat_samples, stat_detections, stat_long_plateaus, stat_busy_drops, stat_candidate_drops,
            stat_frames, stat_overruns, stat_saturations, stat_train_ok, stat_train_reject,
            stat_dropped_symbols, stat_cpe_undefined);
        $display("RXS_NC blind_hits=%0d zero_hits=%0d last_ok=%0d last_src=%0d blind_over=%0d",
            stat_rx_cnt[15:0], stat_rx_cnt[31:16], st_rx_last[10:0], st_rx_last[13:12], st_rx_last[14]);
        $display("RXS_DONE");
        $finish;
    end
endmodule
