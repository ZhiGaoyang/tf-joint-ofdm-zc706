`timescale 1ns/1ps
// Per-frame training channel estimate, training qualification and one-tap
// equalisation for the streaming RX.  Symbols arrive in stream order; sym 0/1
// are the two training symbols of a tag, sym >= 2 are equalised with the
// coefficients of the most recent qualified training.  Coefficient writes of
// a new tag always follow the last read of the previous tag in stream order,
// so a single coefficient bank is sufficient.
module ofdm_rxs_chan (
    input wire clk,
    input wire resetn,
    input wire [31:0] cfg_min_energy,   // >= 2^20 (coefficient quotient range)
    input wire [31:0] s_data,
    input wire [6:0] s_k,
    input wire [7:0] s_tag,
    input wire [7:0] s_sym,
    input wire s_last,
    input wire s_valid,
    output wire s_ready,
    output wire [31:0] m_data,
    output wire [6:0] m_k,
    output wire [7:0] m_tag,
    output wire [7:0] m_sym,
    output wire m_usable,
    output wire m_last,
    output wire m_valid,
    input wire m_ready,
    // training rejection -> fetcher abort
    output reg fb_valid,
    output reg [7:0] fb_tag,
    output reg [31:0] stat_train_ok,
    output reg [31:0] stat_train_reject,
    output reg [31:0] stat_dropped_symbols,
    output wire fault
);
    localparam [127:0] TRAINING = 128'h6f634bb9957f000000002cea7d0e24da;
    localparam [1:0] RUN = 0, WAIT_Q = 1;
    reg [1:0] state;
    (* ram_style = "distributed" *) reg [31:0] train0 [0:127];
    (* ram_style = "distributed" *) reg [48:0] coeff [0:127];
    reg [7:0] eq_tag;          // tag owning the coefficient bank
    reg eq_tag_ok;
    reg [7:0] q_tag;
    reg [3:0] q_wait;

    wire active = (s_k >= 7'd1 && s_k <= 7'd48) || s_k >= 7'd80;
    wire is_train0 = s_sym == 8'd0;
    wire is_train1 = s_sym == 8'd1;
    wire is_data = s_sym >= 8'd2;
    wire data_ok = eq_tag_ok && s_tag == eq_tag;
    wire eq_in_ready;
    assign s_ready = resetn && state == RUN && (!is_data || !data_ok || eq_in_ready);
    wire fire = s_valid && s_ready;

    // ---------------------------------------------------------- coefficients
    wire coeff_valid, coeff_usable;
    wire [47:0] coeff_data;
    wire [7:0] coeff_index;
    wire coeff_fault;
    // T1 bins and their stored T0 partners are registered once; the LUTRAM
    // read is then off the arithmetic path of both consumers.
    reg t_valid;
    reg [31:0] t_d0, t_d1;
    reg [6:0] t_k;
    reg [7:0] t_tag;
    always @(posedge clk) begin
        if (!resetn) t_valid <= 0;
        else t_valid <= fire && is_train1;
        t_d0 <= train0[s_k]; t_d1 <= s_data; t_k <= s_k; t_tag <= s_tag;
    end
    ofdm_rxs_coeff coefficients (
        .clk(clk), .resetn(resetn), .cfg_min_energy(cfg_min_energy),
        .s_axis_tdata0(t_d0), .s_axis_tdata1(t_d1),
        .s_axis_tindex({1'b0, t_k}), .s_axis_tepoch({t_tag, 8'd0}),
        .s_axis_tlast(t_k == 7'd127), .s_axis_tvalid(t_valid), .s_axis_tready(),
        .m_axis_tdata(coeff_data), .m_axis_tindex(coeff_index), .m_axis_tepoch(),
        .m_axis_tlast(), .m_axis_tusable(coeff_usable), .m_axis_tclip(), .m_axis_terror(),
        .m_axis_tvalid(coeff_valid), .m_axis_tready(1'b1), .fault(coeff_fault));
    always @(posedge clk) begin
        if (fire && is_train0) train0[s_k] <= s_data;
        if (coeff_valid) coeff[coeff_index[6:0]] <= {coeff_usable, coeff_data};
    end

    // ------------------------------------------ training qualification (Q)
    // H[k] = mean(T0,T1)*sign.  C = sum H[k] conj(H[k-1]) over adjacent active
    // bins, S = sum |H|^2.  Accept when 4|C|^2 >= S^2 (|C|/S >= 0.5).
    function signed [16:0] training_mean;
        input signed [15:0] a, b;
        input negative;
        reg signed [16:0] sum;
        reg [16:0] magnitude, rounded;
        begin
            sum = {a[15], a} + {b[15], b};
            magnitude = sum[16] ? (~sum + 17'd1) : sum;
            rounded = {1'b0, magnitude[16:1]};
            if (magnitude[0] && rounded[0]) rounded = rounded + 1'b1;
            training_mean = (sum[16] ^ negative) ? -$signed(rounded) : $signed(rounded);
        end
    endfunction
    reg q1_valid, q1_last, q1_active, q1_adjacent;
    reg signed [16:0] mi1, mq1, prev_i, prev_q;
    reg q2_valid, q2_last;
    reg signed [34:0] cre2, cim2;
    reg [33:0] e2;
    reg signed [42:0] c_re, c_im;
    reg [41:0] s_sum;
    reg q_done;
    wire t_active = (t_k >= 7'd1 && t_k <= 7'd48) || t_k >= 7'd80;
    always @(posedge clk) begin
        if (!resetn) begin
            q1_valid <= 0; q2_valid <= 0; q_done <= 0;
        end else begin
            q1_valid <= t_valid;
            q2_valid <= q1_valid;
            q_done <= q2_valid && q2_last;
        end
        if (t_valid) begin
            mi1 <= training_mean(t_d0[15:0], t_d1[15:0], TRAINING[t_k]);
            mq1 <= training_mean(t_d0[31:16], t_d1[31:16], TRAINING[t_k]);
            q1_active <= t_active;
            q1_adjacent <= t_active && t_k != 7'd1 && t_k != 7'd80;
            q1_last <= t_k == 7'd127;
            if (t_k == 7'd0) begin c_re <= 0; c_im <= 0; s_sum <= 0; end
        end
        if (q1_valid) begin
            // H[k] conj(H[k-1])
            cre2 <= q1_adjacent ? mi1 * prev_i + mq1 * prev_q : 35'sd0;
            cim2 <= q1_adjacent ? mq1 * prev_i - mi1 * prev_q : 35'sd0;
            // Signed zero keeps the whole conditional signed (an unsigned
            // literal would zero-extend negative means before squaring).
            e2 <= q1_active ? mi1 * mi1 + mq1 * mq1 : 34'sd0;
            prev_i <= mi1; prev_q <= mq1;
            q2_last <= q1_last;
        end
        if (q2_valid) begin
            c_re <= c_re + cre2; c_im <= c_im + cim2; s_sum <= s_sum + e2;
        end
    end
    // Decision pipeline after q_done: leading one, shift, squares, compare.
    function [5:0] lead_shift;
        input [41:0] value;
        integer k;
        begin
            lead_shift = 0;
            for (k = 17; k < 42; k = k + 1) if (value[k]) lead_shift = k - 16;
        end
    endfunction
    reg d1, d2, d3, d4;
    reg [5:0] qs;
    reg signed [17:0] nc_re, nc_im;
    reg [16:0] ns;
    reg [36:0] cc;
    reg [33:0] ss;
    reg q_accept;
    always @(posedge clk) begin
        if (!resetn) begin d1 <= 0; d2 <= 0; d3 <= 0; d4 <= 0; end
        else begin d1 <= q_done; d2 <= d1; d3 <= d2; d4 <= d3; end
        if (q_done) qs <= lead_shift(s_sum);
        if (d1) begin nc_re <= c_re >>> qs; nc_im <= c_im >>> qs; ns <= s_sum >> qs; end
        if (d2) begin cc <= nc_re * nc_re + nc_im * nc_im; ss <= ns * ns; end
        if (d3) q_accept <= {cc, 2'b0} >= {5'd0, ss} && ss != 0;
    end

    // ---------------------------------------------------------- control
    always @(posedge clk) begin
        if (!resetn) begin
            state <= RUN; eq_tag <= 0; eq_tag_ok <= 0; q_tag <= 0; fb_valid <= 0; fb_tag <= 0;
            stat_train_ok <= 0; stat_train_reject <= 0; stat_dropped_symbols <= 0;
        end else begin
            fb_valid <= 0;
            case (state)
                RUN: if (fire && is_train1 && s_k == 7'd127) begin
                    q_tag <= s_tag; state <= WAIT_Q;
                    eq_tag_ok <= 0;
                end else if (fire && is_data && !data_ok && s_k == 7'd127)
                    stat_dropped_symbols <= stat_dropped_symbols + 1'b1;
                WAIT_Q: if (d4) begin
                    // Coefficient writes trail the T1 input by the 27-stage
                    // divider; the next data bins read after at least 128 more
                    // inputs, so no further wait is needed here.
                    eq_tag <= q_tag; eq_tag_ok <= q_accept; state <= RUN;
                    if (q_accept) stat_train_ok <= stat_train_ok + 1'b1;
                    else begin
                        stat_train_reject <= stat_train_reject + 1'b1;
                        fb_valid <= 1; fb_tag <= q_tag;
                    end
                end
                default: state <= RUN;
            endcase
        end
    end

    // ---------------------------------------------------------- equaliser
    wire [48:0] c = coeff[s_k];
    wire [15:0] eq_epoch;
    wire [7:0] eq_index;
    wire eq_valid, eq_usable, eq_fault;
    ofdm_rx_equalize equalizer (
        .clk(clk), .resetn(resetn), .s_axis_tdata(s_data), .s_axis_tcoeff(c[47:0]),
        .s_axis_tindex({1'b0, s_k}), .s_axis_tepoch({s_tag, s_sym}),
        .s_axis_tlast(s_k == 7'd127), .s_axis_tusable(c[48]),
        .s_axis_tvalid(s_valid && state == RUN && is_data && data_ok), .s_axis_tready(eq_in_ready),
        .m_axis_tdata(m_data), .m_axis_tindex(eq_index), .m_axis_tepoch(eq_epoch),
        .m_axis_tlast(m_last), .m_axis_tusable(eq_usable), .m_axis_tinvalid(), .m_axis_tclips(),
        .m_axis_terror(), .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .fault(eq_fault));
    assign m_k = eq_index[6:0];
    assign m_tag = eq_epoch[15:8];
    assign m_sym = eq_epoch[7:0];
    assign m_usable = eq_usable;
    assign fault = coeff_fault || eq_fault;
endmodule
