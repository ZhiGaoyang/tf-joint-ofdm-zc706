`timescale 1ns/1ps
// Pilot common-phase correction.  Buffers each equalised symbol (two banks),
// estimates the phase from the 8 pilots, then emits the 88 data carriers in
// signed-frequency order (-48..-1, 1..48 without pilots) rotated by -phase.
module ofdm_rxs_cpe #(parameter SIN_ROM_FILE = "ofdm_cfo_sine_quarter.mem") (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_data,
    input wire [6:0] s_k,
    input wire [7:0] s_tag,
    input wire [7:0] s_sym,
    input wire s_usable,
    input wire s_valid,
    output wire s_ready,
    output wire [31:0] m_data,
    output wire [7:0] m_tag,
    output wire [7:0] m_sym,
    output wire m_usable,      // carrier usable and the symbol phase was defined
    output wire m_first,       // first data carrier of the symbol
    output wire m_last,        // 88th data carrier
    output wire m_valid,
    input wire m_ready,
    output reg [31:0] stat_cpe_undefined
);
    // ---------------------------------------------------------------- write
    (* ram_style = "block" *) reg [32:0] bank [0:255];
    reg [1:0] full;
    reg wb, rb;
    reg [7:0] info_tag [0:1];
    reg [7:0] info_sym [0:1];
    reg signed [19:0] acc_i, acc_q;
    reg [3:0] acc_n;
    reg signed [19:0] info_ci [0:1];
    reg signed [19:0] info_cq [0:1];
    reg [3:0] info_n [0:1];
    function pilot;
        input [6:0] k;
        begin pilot = k == 7 || k == 19 || k == 31 || k == 43 || k == 85 || k == 97 || k == 109 || k == 121; end
    endfunction
    function pilot_negative;   // pilot value -1 at signed -7, +7, +31
        input [6:0] k;
        begin pilot_negative = k == 121 || k == 7 || k == 31; end
    endfunction
    assign s_ready = resetn && !full[wb];
    wire fire = s_valid && s_ready;
    wire use_pilot = pilot(s_k) && s_usable;
    wire signed [19:0] pi = {{4{s_data[15]}}, s_data[15:0]};
    wire signed [19:0] pq = {{4{s_data[31]}}, s_data[31:16]};
    wire signed [19:0] next_i = (s_k == 0 ? 20'sd0 : acc_i) + (use_pilot ? (pilot_negative(s_k) ? -pi : pi) : 20'sd0);
    wire signed [19:0] next_q = (s_k == 0 ? 20'sd0 : acc_q) + (use_pilot ? (pilot_negative(s_k) ? -pq : pq) : 20'sd0);
    wire [3:0] next_n = (s_k == 0 ? 4'd0 : acc_n) + (use_pilot ? 4'd1 : 4'd0);
    reg release_bank;
    reg [1:0] release_mask;
    always @(posedge clk) begin
        if (fire) bank[{wb, s_k}] <= {s_usable, s_data};
    end
    always @(posedge clk) begin
        if (!resetn) begin
            full <= 0; wb <= 0; acc_i <= 0; acc_q <= 0; acc_n <= 0;
        end else begin
            if (fire) begin
                acc_i <= next_i; acc_q <= next_q; acc_n <= next_n;
                if (s_k == 7'd127) begin
                    info_tag[wb] <= s_tag; info_sym[wb] <= s_sym;
                    info_ci[wb] <= next_i; info_cq[wb] <= next_q; info_n[wb] <= next_n;
                    wb <= ~wb;
                end
            end
            full <= (full | ((fire && s_k == 7'd127) ? (wb ? 2'b10 : 2'b01) : 2'b00))
                  & ~(release_bank ? release_mask : 2'b00);
        end
    end

    // ---------------------------------------------------------------- phase
    localparam [3:0] R_IDLE = 0, R_PHASE = 1, R_WAIT = 2, R_READ = 3, R_DONE = 4, R_MAG1 = 5, R_MAG2 = 6,
                     R_MAG3 = 7, R_ADDR = 8, R_FOLD = 9;
    reg [3:0] rstate;
    reg phase_req;
    wire phase_ready, phase_valid, phase_defined;
    wire signed [31:0] phase_word;
    reg signed [31:0] phase;
    reg phase_ok;
    reg [11:0] sin_addr;       // per-symbol constant rotation address
    reg [10:0] so_c, co_c;
    reg sn_c, cn_c;
    ofdm_rx_cpe_phase cordic (
        .clk(clk), .resetn(resetn), .s_valid(phase_req), .s_ready(phase_ready),
        .s_corr_i(info_ci[rb]), .s_corr_q(info_cq[rb]), .s_sample_index(64'd0),
        .m_valid(phase_valid), .m_ready(1'b1), .m_sample_index(), .m_phase_word(phase_word),
        .m_defined(phase_defined), .m_boundary_ambiguous());
    // Defined when >= 4 pilots and |corr| >= 0.5 per usable pilot (F14 unit).
    reg signed [19:0] mc_i, mc_q;
    reg [3:0] mc_n;
    reg [39:0] mag2, sq_i, sq_q;
    reg [35:0] need2;
    reg magnitude_ok;

    function [11:0] phase_address;
        input [31:0] w;
        begin phase_address = w[31:20] + ((w[19:0] > 20'h80000) || ((w[19:0] == 20'h80000) && w[20])); end
    endfunction
    function [10:0] fold;
        input [11:0] a;
        begin fold = a[10] ? 11'd1024 - {1'b0, a[9:0]} : {1'b0, a[9:0]}; end
    endfunction
    // ----------------------------------------------------------------- read
    // Data carriers in signed order: natural 80..127 then 1..48, no pilots.
    reg [6:0] rk;
    reg [6:0] emitted;
    reg [5:0] occupancy;
    wire out_pop;
    wire can_issue = occupancy < 6'd24;
    wire skip = pilot(rk);
    wire issue = rstate == R_READ && can_issue && !skip;
    wire [6:0] rk_next = rk == 7'd127 ? 7'd1 : rk + 1'b1;
    always @(posedge clk) begin
        if (!resetn) begin
            rstate <= R_IDLE; rb <= 0; phase_req <= 0; release_bank <= 0; release_mask <= 0; rk <= 7'd80; emitted <= 0;
            stat_cpe_undefined <= 0; phase_ok <= 0; phase <= 0;
        end else begin
            release_bank <= 0;
            case (rstate)
                R_IDLE: if (full[rb] && !release_bank) begin
                    mc_i <= info_ci[rb]; mc_q <= info_cq[rb]; mc_n <= info_n[rb]; rstate <= R_MAG1;
                end
                R_MAG1: begin
                    sq_i <= mc_i * mc_i; sq_q <= mc_q * mc_q;
                    need2 <= {mc_n, 13'd0} * {mc_n, 13'd0};
                    rstate <= R_MAG2;
                end
                R_MAG2: begin mag2 <= sq_i + sq_q; rstate <= R_MAG3; end
                R_MAG3: begin
                    magnitude_ok <= mc_n >= 4'd4 && mag2 >= {4'd0, need2};
                    phase_req <= 1; rstate <= R_PHASE;
                end
                R_PHASE: if (phase_ready) begin phase_req <= 0; rstate <= R_WAIT; end
                R_WAIT: if (phase_valid) begin
                    phase_ok <= phase_defined && magnitude_ok;
                    phase <= phase_word;
                    if (!(phase_defined && magnitude_ok)) stat_cpe_undefined <= stat_cpe_undefined + 1'b1;
                    rk <= 7'd80; emitted <= 0; rstate <= R_ADDR;
                end
                R_ADDR: begin sin_addr <= phase_address(-phase); rstate <= R_FOLD; end
                R_FOLD: begin
                    so_c <= fold(sin_addr); co_c <= fold(sin_addr + 12'd1024);
                    sn_c <= sin_addr[11]; cn_c <= sin_addr[11] ^ sin_addr[10];   // bit 11 of addr+1024
                    rstate <= R_READ;
                end
                R_READ: if (skip) rk <= rk_next;
                    else if (issue) begin
                        rk <= rk_next; emitted <= emitted + 1'b1;
                        if (emitted == 7'd87) rstate <= R_DONE;
                    end
                R_DONE: begin
                    release_bank <= 1; release_mask <= rb ? 2'b10 : 2'b01;
                    rb <= ~rb; rstate <= R_IDLE;
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------- rotate pipeline
    // c0 issue -> c1 bank data, rom address -> c2 rom -> c3 sign -> c4 products
    // -> c5 sums -> fifo.  Rotation by -phase.
    (* rom_style = "block" *) reg signed [17:0] sine_rom [0:1024];
    initial $readmemh(SIN_ROM_FILE, sine_rom);
    function [15:0] round_sat;
        input signed [35:0] x;
        reg signed [35:0] r;
        begin
            r = (x + 36'sd32768) >>> 16;
            round_sat = r > 36'sd32767 ? 16'h7fff : (r < -36'sd32768 ? 16'h8000 : r[15:0]);
        end
    endfunction
    reg [5:0] v;
    reg [32:0] d1, d2, d3, d4;
    reg [17:0] m1, m2, m3, m4, m5;    // {tag, sym, first, last}
    reg ok1, ok2, ok3, ok4, ok5;
    reg [10:0] so1, co1;
    reg sn1, cn1, sn2, cn2;
    reg signed [17:0] sm2, cm2, s3, c3;
    reg signed [34:0] ic4, qs4, is4, qc4;
    reg signed [35:0] oi5, oq5;
    reg u5;
    always @(posedge clk) begin
        if (!resetn) v <= 0; else v <= {v[4:0], issue};
        m1 <= {info_tag[rb], info_sym[rb], emitted == 7'd0, emitted == 7'd87}; ok1 <= phase_ok;
        so1 <= so_c; co1 <= co_c; sn1 <= sn_c; cn1 <= cn_c;
        d2 <= d1; m2 <= m1; ok2 <= ok1;
        sm2 <= sine_rom[so1]; cm2 <= sine_rom[co1]; sn2 <= sn1; cn2 <= cn1;
        d3 <= d2; m3 <= m2; ok3 <= ok2;
        s3 <= sn2 ? -sm2 : sm2; c3 <= cn2 ? -cm2 : cm2;
        d4 <= d3; m4 <= m3; ok4 <= ok3;
        ic4 <= $signed(d3[15:0]) * c3; qs4 <= $signed(d3[31:16]) * s3;
        is4 <= $signed(d3[15:0]) * s3; qc4 <= $signed(d3[31:16]) * c3;
        m5 <= m4; ok5 <= ok4; u5 <= d4[32];
        oi5 <= ic4 - qs4; oq5 <= is4 + qc4;
    end
    always @(posedge clk) if (issue) d1 <= bank[{rb, rk}];

    localparam FD = 32;
    reg [50:0] fifo [0:FD-1];
    reg [4:0] fifo_wr, fifo_rd;
    reg [5:0] fifo_count;
    assign out_pop = m_valid && m_ready;
    always @(posedge clk) begin
        if (!resetn) begin
            fifo_wr <= 0; fifo_rd <= 0; fifo_count <= 0; occupancy <= 0;
        end else begin
            // stage-5 registers are valid while v[4]
            if (v[4]) begin
                fifo[fifo_wr] <= {ok5 && u5, m5, round_sat(oq5), round_sat(oi5)};
                fifo_wr <= fifo_wr + 1'b1;
            end
            if (out_pop) fifo_rd <= fifo_rd + 1'b1;
            fifo_count <= fifo_count + (v[4] ? 1'b1 : 1'b0) - (out_pop ? 1'b1 : 1'b0);
            occupancy <= occupancy + (issue ? 1'b1 : 1'b0) - (out_pop ? 1'b1 : 1'b0);
        end
    end
    wire [50:0] head = fifo[fifo_rd];
    assign m_valid = fifo_count != 0;
    assign m_data = head[31:0];
    assign m_last = head[32];
    assign m_first = head[33];
    assign m_sym = head[41:34];
    assign m_tag = head[49:42];
    assign m_usable = head[50];
endmodule
