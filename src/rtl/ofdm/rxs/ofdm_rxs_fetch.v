`timescale 1ns/1ps
// Symbol fetcher: turns candidates {start, step} into CFO-corrected 128-sample
// FFT windows read from the raw ring.  A frame ends when its header/training
// feedback limits the symbol count, when the next candidate would overlap the
// next symbol, or at the protocol maximum.  The fetcher never waits for a
// header decision; extra symbols are dropped downstream by tag.
module ofdm_rxs_fetch #(
    parameter AW = 11,
    parameter SIN_ROM_FILE = "ofdm_cfo_sine_quarter.mem"
) (
    input wire clk,
    input wire resetn,
    input wire [5:0] cfg_backoff,
    input wire [9:0] cfg_guard,
    // candidate FIFO head and the entry behind it
    input wire cand_valid,
    input wire [31:0] cand_start,
    input wire signed [31:0] cand_step,
    output reg cand_pop,
    // ring
    input wire [31:0] wr_index,
    output wire rd_en,
    output wire [31:0] rd_index,
    input wire [31:0] rd_data,
    // feedback: symbol limit for a tag (0 = abort now)
    input wire fb_valid,
    input wire [7:0] fb_tag,
    input wire [7:0] fb_nsym,
    // per-frame information, written when a frame is loaded
    output reg info_we,
    output reg [7:0] info_tag,
    output reg [31:0] info_start,
    output reg [31:0] info_step,
    // FFT input stream
    output wire [31:0] m_data,
    output wire [7:0] m_tag,
    output wire [7:0] m_sym,
    output wire m_last,
    output wire m_valid,
    input wire m_ready,
    output reg [31:0] stat_frames,
    output reg [31:0] stat_overruns
);
    localparam [7:0] MAX_SYMBOLS = 8'd191;
    localparam [2:0] S_IDLE = 0, S_LOAD = 1, S_CHECK = 2, S_PHASE = 3, S_READ = 4, S_END = 5;
    reg [2:0] state;
    reg [31:0] f_start, sym_base, win_start;
    reg signed [31:0] f_step;
    reg [7:0] tag, sym, limit;
    reg limit_valid;
    reg [6:0] rd_count;
    reg [31:0] phase;
    reg signed [47:0] phase_product;
    reg [15:0] window_offset;

    // Output FIFO and occupancy accounting (issued but not yet popped).
    localparam FD = 64;
    reg [48:0] fifo [0:FD-1];
    reg [5:0] fifo_wr, fifo_rd;
    reg [6:0] fifo_count;
    reg [6:0] occupancy;
    wire fifo_pop = m_valid && m_ready;
    wire can_issue = occupancy < 7'd48;

    wire [31:0] win_end_guard = win_start + 32'd128 + {22'd0, cfg_guard};
    wire samples_ready = $signed(wr_index - win_end_guard) >= 0;
    wire overrun = $signed(wr_index - win_start) > $signed(32'd1 << AW) - 32'sd64;
    wire next_overlaps = cand_valid && $signed(cand_start - (sym_base + 32'd140)) < 0;
    wire limit_hit = limit_valid && sym >= limit;
    wire issue = state == S_READ && can_issue;

    assign rd_en = issue;
    assign rd_index = win_start + {25'd0, rd_count};

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_IDLE; cand_pop <= 0; info_we <= 0; tag <= 0; sym <= 0;
            limit_valid <= 0; limit <= 0; rd_count <= 0; phase <= 0;
            stat_frames <= 0; stat_overruns <= 0;
        end else begin
            cand_pop <= 0; info_we <= 0;
            if (fb_valid && fb_tag == tag && state != S_IDLE) begin
                limit_valid <= 1; limit <= fb_nsym;
            end
            case (state)
                S_IDLE: if (cand_valid) state <= S_LOAD;
                S_LOAD: begin
                    f_start <= cand_start; f_step <= cand_step; sym_base <= cand_start;
                    win_start <= cand_start + 32'd32 - {26'd0, cfg_backoff};
                    window_offset <= 16'd32 - {10'd0, cfg_backoff};
                    tag <= tag + 1'b1; sym <= 0; limit_valid <= 0;
                    cand_pop <= 1;
                    info_we <= 1; info_tag <= tag + 1'b1; info_start <= cand_start; info_step <= cand_step;
                    stat_frames <= stat_frames + 1'b1;
                    state <= S_CHECK;
                end
                S_CHECK: begin
                    // cand_* now show the next candidate (pop took effect).
                    if (cand_pop) state <= S_CHECK;
                    else if (limit_hit || sym == MAX_SYMBOLS || (sym != 0 && next_overlaps)) state <= S_END;
                    else if (overrun) begin stat_overruns <= stat_overruns + 1'b1; state <= S_END; end
                    else if (samples_ready) begin
                        phase_product <= f_step * $signed({1'b0, window_offset});
                        state <= S_PHASE;
                    end
                end
                S_PHASE: begin
                    // Correct by -step per sample relative to the frame start.
                    phase <= -phase_product[31:0];
                    rd_count <= 0; state <= S_READ;
                end
                S_READ: if (issue) begin
                    phase <= phase - f_step;
                    if (rd_count == 7'd127) begin
                        sym <= sym + 1'b1; sym_base <= sym_base + 32'd160;
                        win_start <= win_start + 32'd160; window_offset <= window_offset + 16'd160;
                        state <= S_CHECK;
                    end
                    rd_count <= rd_count + 1'b1;
                end
                S_END: state <= cand_valid ? S_LOAD : S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------ rotation pipeline
    // c0 issue -> c1 ram reg -> c2 ram data / address -> c3 rom -> c4 sign
    // -> c5 products -> c6 sums -> c7 round/saturate -> fifo
    (* rom_style = "block" *) reg signed [17:0] sine_rom [0:1024];
    initial $readmemh(SIN_ROM_FILE, sine_rom);
    reg [7:0] v;
    reg [31:0] ph1, ph2;
    reg [15:0] meta1, meta2, meta3, meta4, meta5, meta6, meta7;
    reg l1, l2, l3, l4, l5, l6, l7;
    reg [11:0] addr2;
    reg [10:0] so3, co3;
    reg sn3, cn3, sn4, cn4;
    reg signed [17:0] sm4, cm4, s5, c5;
    reg [31:0] d3, d4, d5;
    reg signed [34:0] ic6, qs6, is6, qc6;
    reg signed [35:0] oi7, oq7;
    function [11:0] phase_address;
        input [31:0] w;
        begin phase_address = w[31:20] + ((w[19:0] > 20'h80000) || ((w[19:0] == 20'h80000) && w[20])); end
    endfunction
    function [10:0] fold;
        input [11:0] a;
        begin fold = a[10] ? 11'd1024 - {1'b0, a[9:0]} : {1'b0, a[9:0]}; end
    endfunction
    function [15:0] round_sat;
        input signed [35:0] x;     // value scaled by 2^16
        reg signed [35:0] r;
        begin
            r = (x + 36'sd32768) >>> 16;
            round_sat = r > 36'sd32767 ? 16'h7fff : (r < -36'sd32768 ? 16'h8000 : r[15:0]);
        end
    endfunction
    wire [11:0] cos_addr2 = addr2 + 12'd1024;
    always @(posedge clk) begin
        if (!resetn) v <= 0;
        else v <= {v[6:0], issue};   // v[k-1] marks valid stage-k registers
        ph1 <= phase; meta1 <= {tag, sym}; l1 <= rd_count == 7'd127;
        ph2 <= ph1; meta2 <= meta1; l2 <= l1; addr2 <= phase_address(ph1);
        // rd_data is valid in c2 (two cycles after the issue cycle).
        d3 <= rd_data; meta3 <= meta2; l3 <= l2;
        so3 <= fold(addr2); co3 <= fold(cos_addr2); sn3 <= addr2[11]; cn3 <= cos_addr2[11];
        d4 <= d3; meta4 <= meta3; l4 <= l3;
        sm4 <= sine_rom[so3]; cm4 <= sine_rom[co3]; sn4 <= sn3; cn4 <= cn3;
        d5 <= d4; meta5 <= meta4; l5 <= l4;
        s5 <= sn4 ? -sm4 : sm4; c5 <= cn4 ? -cm4 : cm4;
        meta6 <= meta5; l6 <= l5;
        ic6 <= $signed(d5[15:0]) * c5; qs6 <= $signed(d5[31:16]) * s5;
        is6 <= $signed(d5[15:0]) * s5; qc6 <= $signed(d5[31:16]) * c5;
        meta7 <= meta6; l7 <= l6;
        oi7 <= ic6 - qs6; oq7 <= is6 + qc6;
    end
    // Rotation by +phase: (i + jq)(cos + j sin).  Stage-7 data is valid while v[6].
    always @(posedge clk) begin
        if (!resetn) begin
            fifo_wr <= 0; fifo_rd <= 0; fifo_count <= 0; occupancy <= 0;
        end else begin
            if (v[6]) begin
                fifo[fifo_wr] <= {l7, meta7, round_sat(oq7), round_sat(oi7)};
                fifo_wr <= fifo_wr + 1'b1;
            end
            fifo_rd <= fifo_rd + (fifo_pop ? 1'b1 : 1'b0);
            fifo_count <= fifo_count + (v[6] ? 1'b1 : 1'b0) - (fifo_pop ? 1'b1 : 1'b0);
            occupancy <= occupancy + (issue ? 1'b1 : 1'b0) - (fifo_pop ? 1'b1 : 1'b0);
        end
    end
    wire [48:0] head = fifo[fifo_rd];
    assign m_valid = fifo_count != 0;
    assign m_data = head[31:0];
    assign m_sym = head[39:32];
    assign m_tag = head[47:40];
    assign m_last = head[48];
endmodule
