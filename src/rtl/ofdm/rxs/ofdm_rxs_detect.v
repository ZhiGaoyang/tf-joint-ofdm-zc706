`timescale 1ns/1ps
// Streaming training detector (route B).  Lag-160/window-128 repetition
// metric, normalised by max(E0,E1)^2, plateau = one run above thr_lo that
// reaches thr_hi.  Start = ((n1+n2+1)>>1) - 294, CFO step = angle(sum P)/160.
// See models/ofdm/streaming_rx.py and docs/decisions/2026-10-21_m0_streaming_sync.md.
module ofdm_rxs_detect (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_iq,          // Q[31:16], I[15:0], DC-blocked detector copy
    input wire s_valid,
    input wire [38:0] cfg_energy_floor,
    input wire [7:0] cfg_min_plateau,
    input wire [11:0] cfg_blank,
    output reg m_valid,              // one candidate; consumer FIFO never stalls us
    output reg [31:0] m_start,
    output reg signed [31:0] m_step, // per-sample phase advance of the received CFO
    output reg [31:0] stat_detections,
    output reg [31:0] stat_long_plateaus,
    output reg [31:0] stat_busy_drops
);
    `include "ofdm_cfo_atan.vh"
    localparam [31:0] CENTRE = 32'd294;
    localparam [8:0] MAX_RUN = 9'd320;

    // ---------------------------------------------------------------- metric
    wire metric_valid;
    wire [63:0] metric_index;
    wire signed [39:0] corr_i, corr_q;
    wire [38:0] energy_0, energy_1;
    ofdm_rx_metric_registered metric (
        .clk(clk), .resetn(resetn), .s_axis_tdata(s_iq), .s_axis_tvalid(s_valid),
        .s_axis_tready(), .m_axis_tvalid(metric_valid), .m_axis_tready(1'b1),
        .m_sample_index(metric_index), .m_corr_i(corr_i), .m_corr_q(corr_q),
        .m_energy_0(energy_0), .m_energy_1(energy_1));

    // ------------------------------------------------ normalise and compare
    // n1: register; n2: leading-one of Emax; n3: shift; n4: squares; n5: compare.
    reg v1, v2, v3, v4, v5;
    reg [31:0] idx1, idx2, idx3, idx4, idx5;
    reg signed [39:0] pi1, pq1, pi2, pq2, pi4, pq4, pi5, pq5;
    reg [38:0] emax1, emax2;
    reg floor1, floor2, floor3, floor4;
    reg [5:0] shift2;
    reg signed [17:0] si3, sq3;
    reg [16:0] se3;
    reg [35:0] pp4;
    reg [33:0] ee4;
    reg hi5, lo5;
    function [5:0] lead_shift;     // shift so that value>>shift < 2^17
        input [38:0] value;
        integer k;
        begin
            lead_shift = 0;
            for (k = 17; k < 39; k = k + 1) if (value[k]) lead_shift = k - 16;
        end
    endfunction
    always @(posedge clk) begin
        if (!resetn) begin
            v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; v5 <= 0;
        end else begin
            v1 <= metric_valid;
            v2 <= v1; v3 <= v2; v4 <= v3; v5 <= v4;
        end
        if (metric_valid) begin
            idx1 <= metric_index[31:0]; pi1 <= corr_i; pq1 <= corr_q;
            emax1 <= energy_0 > energy_1 ? energy_0 : energy_1;
        end
        floor1 <= (energy_0 > energy_1 ? energy_0 : energy_1) >= cfg_energy_floor;
        idx2 <= idx1; pi2 <= pi1; pq2 <= pq1; emax2 <= emax1; floor2 <= floor1;
        shift2 <= lead_shift(emax1);
        idx3 <= idx2; floor3 <= floor2;
        si3 <= pi2 >>> shift2; sq3 <= pq2 >>> shift2; se3 <= emax2 >> shift2;
        pi4 <= pi2; pq4 <= pq2;
        idx4 <= idx3; floor4 <= floor3;
        pp4 <= si3 * si3 + sq3 * sq3;
        ee4 <= se3 * se3;
        idx5 <= idx4; pi5 <= pi4; pq5 <= pq4;
        // thr_hi = 0.5: 2pp >= ee.  thr_lo = 0.35: 20pp >= 7ee.
        hi5 <= floor4 && ({pp4, 1'b0} >= {2'b0, ee4});
        lo5 <= floor4 && ({pp4, 4'b0} + {2'b0, pp4, 2'b0} >= {ee4, 2'b0} + {1'b0, ee4, 1'b0} + {3'b0, ee4});
    end

    // ----------------------------------------------------------- plateau run
    // Sample indices are 32-bit and wrap every 2^32 samples (35 s at 122.88
    // MSPS), so they are only ever compared over short modular distances: the
    // blanking flag is cleared once the blank has passed, and the run centre
    // is formed from the run length, not from the sum of two absolute indices.
    reg in_run, run_peak, have_blank, run_after_blank;
    reg [31:0] run_n1, last_n, blank_until;
    reg [8:0] run_len;
    reg signed [47:0] run_acc;
    reg pend_valid;
    reg [31:0] pend_start;
    reg signed [47:0] pend_acc;
    wire [31:0] run_span = last_n - run_n1 + 32'd1;
    wire [31:0] run_start = run_n1 + {1'b0, run_span[31:1]} - CENTRE;
    wire blank_passed = !have_blank || $signed(idx5 - blank_until) >= 0;
    wire run_ok = run_peak && run_len >= {1'b0, cfg_min_plateau} && run_len <= MAX_RUN && run_after_blank;
    wire cordic_idle;
    always @(posedge clk) begin
        if (!resetn) begin
            in_run <= 0; run_peak <= 0; have_blank <= 0; run_after_blank <= 0; run_len <= 0; run_acc <= 0;
            run_n1 <= 0; last_n <= 0; blank_until <= 0; pend_valid <= 0;
            stat_detections <= 0; stat_long_plateaus <= 0; stat_busy_drops <= 0;
        end else begin
            if (pend_valid && cordic_idle) pend_valid <= 0;
            if (v5) begin
                // Cleared here; a detection on this same sample sets it again below.
                if (have_blank && blank_passed) have_blank <= 0;
                if (lo5) begin
                    if (!in_run) begin
                        in_run <= 1; run_n1 <= idx5; run_len <= 1; run_peak <= hi5;
                        run_after_blank <= blank_passed;
                        run_acc <= {{8{pi5[39]}}, pi5};
                    end else begin
                        if (run_len != 9'h1ff) run_len <= run_len + 1'b1;
                        run_peak <= run_peak | hi5;
                        run_acc <= run_acc + {{8{pi5[39]}}, pi5};
                    end
                    last_n <= idx5;
                end else if (in_run) begin
                    in_run <= 0;
                    if (run_len > MAX_RUN) stat_long_plateaus <= stat_long_plateaus + 1'b1;
                    if (run_ok) begin
                        if (pend_valid) stat_busy_drops <= stat_busy_drops + 1'b1;
                        else begin
                            pend_valid <= 1; pend_start <= run_start; pend_acc <= run_acc;
                            blank_until <= run_start + {20'd0, cfg_blank}; have_blank <= 1;
                            stat_detections <= stat_detections + 1'b1;
                        end
                    end
                end
            end
        end
    end
    // Imaginary part of the accumulator is needed too: keep a parallel sum.
    reg signed [47:0] run_acc_q, pend_acc_q;
    always @(posedge clk) begin
        if (v5 && lo5) run_acc_q <= in_run ? run_acc_q + {{8{pq5[39]}}, pq5} : {{8{pq5[39]}}, pq5};
        if (v5 && !lo5 && in_run && run_ok && !pend_valid) pend_acc_q <= run_acc_q;
    end

    // ------------------------------------- CORDIC angle, then divide by 160
    localparam [2:0] C_IDLE = 0, C_SHIFT = 1, C_LOAD = 2, C_ITER = 3, C_DIV = 4, C_OUT = 5, C_MAG = 6;
    reg [2:0] cstate;
    reg [4:0] iter;
    reg [5:0] div_bit;
    reg [5:0] nshift;
    reg signed [47:0] ax, ay;
    reg signed [42:0] x, y;
    reg signed [33:0] z;
    reg [31:0] c_start;
    reg [32:0] magnitude, quotient, remainder;
    reg phase_negative;
    assign cordic_idle = cstate == C_IDLE;
    reg [47:0] mag_x, mag_y;
    function [5:0] norm_shift;    // left shift so that the larger magnitude reaches bit 39
        input [47:0] a, b;
        reg [47:0] largest;
        integer k;
        begin
            largest = a > b ? a : b;
            norm_shift = 0;
            for (k = 0; k < 48; k = k + 1) if (largest[k]) norm_shift = k;
        end
    endfunction
    wire signed [42:0] next_x = y > 0 ? x + (y >>> iter) : (y < 0 ? x - (y >>> iter) : x);
    wire signed [42:0] next_y = y > 0 ? y - (x >>> iter) : (y < 0 ? y + (x >>> iter) : y);
    wire signed [33:0] next_z = y > 0 ? z + cfo_atan_word(iter) : (y < 0 ? z - cfo_atan_word(iter) : z);
    wire [32:0] trial = {remainder[31:0], magnitude[32]};
    always @(posedge clk) begin
        if (!resetn) begin
            cstate <= C_IDLE; m_valid <= 0; m_start <= 0; m_step <= 0;
        end else begin
            m_valid <= 0;
            case (cstate)
                C_IDLE: if (pend_valid) begin
                    // Rotate by 180 degrees for a negative real part.
                    ax <= pend_acc[47] ? -pend_acc : pend_acc;
                    ay <= pend_acc[47] ? -pend_acc_q : pend_acc_q;
                    z <= pend_acc[47] ? (pend_acc_q[47] ? -34'sd2147483648 : 34'sd2147483648) : 34'sd0;
                    c_start <= pend_start;
                    cstate <= C_MAG;
                end
                C_MAG: begin
                    mag_x <= ax[47] ? -ax : ax; mag_y <= ay[47] ? -ay : ay; cstate <= C_SHIFT;
                end
                C_SHIFT: begin nshift <= norm_shift(mag_x, mag_y); cstate <= C_LOAD; end
                C_LOAD: begin
                    // Keep 40 significant bits: shift right when larger than 2^39.
                    if (nshift > 6'd39) begin
                        x <= ax >>> (nshift - 6'd39); y <= ay >>> (nshift - 6'd39);
                    end else begin
                        x <= ax <<< (6'd39 - nshift); y <= ay <<< (6'd39 - nshift);
                    end
                    iter <= 0; cstate <= C_ITER;
                end
                C_ITER: begin
                    x <= next_x; y <= next_y; z <= next_z;
                    if (iter == 5'd31) begin
                        phase_negative <= next_z[31];
                        magnitude <= next_z[31] ? {1'b0, -next_z[31:0]} : {1'b0, next_z[31:0]};
                        remainder <= 0; quotient <= 0; div_bit <= 0; cstate <= C_DIV;
                    end else iter <= iter + 1'b1;
                end
                C_DIV: begin
                    // Restoring division by 160, one quotient bit per cycle.
                    if (trial >= 33'd160) begin
                        remainder <= trial - 33'd160; quotient <= {quotient[31:0], 1'b1};
                    end else begin
                        remainder <= trial; quotient <= {quotient[31:0], 1'b0};
                    end
                    magnitude <= {magnitude[31:0], 1'b0};
                    if (div_bit == 6'd32) cstate <= C_OUT; else div_bit <= div_bit + 1'b1;
                end
                C_OUT: begin
                    // Round half to even on the remainder.
                    m_step <= phase_negative ?
                        -$signed(quotient[31:0] + ((remainder > 33'd80 || (remainder == 33'd80 && quotient[0])) ? 32'd1 : 32'd0)) :
                         $signed(quotient[31:0] + ((remainder > 33'd80 || (remainder == 33'd80 && quotient[0])) ? 32'd1 : 32'd0));
                    m_start <= c_start; m_valid <= 1; cstate <= C_IDLE;
                end
                default: cstate <= C_IDLE;
            endcase
        end
    end
endmodule
