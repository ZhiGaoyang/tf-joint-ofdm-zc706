`timescale 1ns/1ps
// Per-carrier quality metrics for group masking (design B sections 1.2-1.3, 5.2).
// One measured data carrier per cycle at most, from the decoder input (after
// equalisation and CPE).  Three banks of 88 words, address {bank, ord}:
//   bank 0 HDR   : header symbols, QPSK reference, every copy counted
//   bank 1 PAY   : payload symbols; masked carriers (s_null) use reference 0
//   bank 2 ERASE : number of unusable (erased) instances, any symbol
// Error term t = (e_I^2 + e_Q^2) >> 12 (2^16 = one unit constellation energy),
// e folded per axis against the nearest level as in the decoder; erased
// instances only count in ERASE.  32-bit saturating accumulation (ERASE 16-bit).
// Pipeline c1 |I|,|Q| -> c2 folded error -> c3 squares -> c4 sum, read ->
// c5 saturating add, write.  The same ord returns no sooner than 88 inputs
// later, so the read-modify-write needs no forwarding.  stat_syms_hdr/pay
// count measured symbols (s_sym_last).  clear zeroes the 384 used RAM words and
// the counters in 385 cycles; inputs are ignored from the clear edge on and
// elements still in flight neither write nor count (the clear wins on every
// edge).  cfg_freeze pauses accumulation.
// AXI-side reads use port A in cycles without a pipeline read; rd_valid comes a
// few cycles after a free cycle, so a continuous input stream can delay it.
// rd_cancel abandons the outstanding read (the requester timed out): no stale
// rd_valid is produced for it; rd_addr = {bank[1:0], ord[6:0]}.
module ofdm_rxs_cmetric (
    input wire clk,
    input wire resetn,
    input wire cfg_enable,
    input wire cfg_freeze,
    input wire clear,
    output wire clear_busy,
    input wire s_valid,
    input wire [6:0] s_ord,
    input wire [31:0] s_data,          // Q[31:16], I[15:0], W16/F14
    input wire s_qam,
    input wire s_null,
    input wire s_hdr,
    input wire s_usable,
    input wire s_sym_last,
    input wire [8:0] rd_addr,
    input wire rd_req,
    input wire rd_cancel,
    output reg [31:0] rd_data,
    output reg rd_valid,
    output reg [31:0] stat_syms_hdr,
    output reg [31:0] stat_syms_pay
);
    localparam [16:0] QPSK_LEVEL = 17'd11585, QAM_LOW = 17'd5181, QAM_HIGH = 17'd15543;
    localparam [16:0] QAM_THRESHOLD = 17'd10362;

    (* ram_style = "block" *) reg [31:0] mem [0:511];
    // clear state
    reg clearing;
    reg [8:0] clear_addr;
    assign clear_busy = clearing;
    wire clear_start = clear && !clearing;
    wire take = s_valid && cfg_enable && !cfg_freeze && !clearing && !clear;

    // c1
    reg c1_v, c1_qam, c1_null, c1_hdr, c1_erase, c1_last;
    reg [6:0] c1_ord;
    reg [16:0] c1_ai, c1_aq;
    wire signed [15:0] di = s_data[15:0];
    wire signed [15:0] dq = s_data[31:16];
    wire [16:0] adi = di[15] ? -{di[15], di} : {1'b0, di};
    wire [16:0] adq = dq[15] ? -{dq[15], dq} : {1'b0, dq};
    // c2
    reg c2_v, c2_erase, c2_hdr, c2_last;
    reg [6:0] c2_ord;
    reg signed [17:0] c2_ei, c2_eq;
    wire [16:0] ref_i = c1_null ? 17'd0 : (c1_qam ? (c1_ai < QAM_THRESHOLD ? QAM_LOW : QAM_HIGH) : QPSK_LEVEL);
    wire [16:0] ref_q = c1_null ? 17'd0 : (c1_qam ? (c1_aq < QAM_THRESHOLD ? QAM_LOW : QAM_HIGH) : QPSK_LEVEL);
    // c3
    reg c3_v, c3_erase, c3_hdr, c3_last;
    reg [6:0] c3_ord;
    reg [35:0] c3_si, c3_sq;
    // c4
    reg c4_v, c4_erase;
    reg [8:0] c4_addr;
    reg [23:0] c4_t;
    // c5
    reg [31:0] port_a;                 // registered port-A read data
    reg rd_pending, rd_issued;
    reg [8:0] rd_addr_q;
    wire pipe_read = c3_v;             // c4 consumes the port-A word read in c4
    wire [32:0] sum_err = {1'b0, port_a} + {9'd0, c4_t};
    wire [16:0] sum_erase = {1'b0, port_a[15:0]} + 17'd1;

    // Simple dual-port RAM template (one write port, one registered read port) so
    // that synthesis maps the banks to block RAM.
    // Read port: pipeline read (address of the c3 element) has priority.
    wire [8:0] ra = pipe_read ? {c3_erase ? 2'd2 : (c3_hdr ? 2'd0 : 2'd1), c3_ord} : rd_addr_q;
    wire re = pipe_read || rd_pending;
    // Write port: clear or write-back.
    wire we = clearing || c4_v;
    wire [8:0] wa = clearing ? clear_addr : c4_addr;
    wire [31:0] wd = clearing ? 32'd0 :
                     c4_erase ? {16'd0, sum_erase[16] ? 16'hFFFF : sum_erase[15:0]} :
                     (sum_err[32] ? 32'hFFFFFFFF : sum_err[31:0]);
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        if (re) port_a <= mem[ra];
    end

    always @(posedge clk) begin
        if (!resetn) begin
            clearing <= 1; clear_addr <= 0;
            c1_v <= 0; c2_v <= 0; c3_v <= 0; c4_v <= 0;
            rd_pending <= 0; rd_issued <= 0; rd_valid <= 0; rd_data <= 0;
            stat_syms_hdr <= 0; stat_syms_pay <= 0;
        end else begin
            // clear: 512 words would take 512 cycles; only banks 0..2 x 128 are used.
            if (clear && !clearing) begin
                clearing <= 1; clear_addr <= 0; stat_syms_hdr <= 0; stat_syms_pay <= 0;
            end else if (clearing) begin
                clear_addr <= clear_addr + 9'd1;
                if (clear_addr == 9'd383) clearing <= 0;
            end
            // c1
            c1_v <= take;
            if (take) begin
                c1_ai <= adi; c1_aq <= adq; c1_ord <= s_ord;
                c1_qam <= s_qam && !s_hdr; c1_null <= s_null && !s_hdr; c1_hdr <= s_hdr;
                c1_erase <= !s_usable; c1_last <= s_sym_last;
            end
            // c2
            c2_v <= c1_v;
            if (c1_v) begin
                c2_ei <= $signed({1'b0, c1_ai}) - $signed({1'b0, ref_i});
                c2_eq <= $signed({1'b0, c1_aq}) - $signed({1'b0, ref_q});
                c2_ord <= c1_ord; c2_erase <= c1_erase; c2_hdr <= c1_hdr; c2_last <= c1_last;
            end
            // c3
            c3_v <= c2_v;
            if (c2_v) begin
                c3_si <= c2_ei * c2_ei; c3_sq <= c2_eq * c2_eq;
                c3_ord <= c2_ord; c3_erase <= c2_erase; c3_hdr <= c2_hdr; c3_last <= c2_last;
            end
            // c4 (port A read of this element happens in the same cycle)
            c4_v <= c3_v;
            if (c3_v) begin
                c4_t <= (c3_si + c3_sq) >> 12;
                c4_erase <= c3_erase;
                c4_addr <= {c3_erase ? 2'd2 : (c3_hdr ? 2'd0 : 2'd1), c3_ord};
                if (c3_last && !clearing && !clear_start) begin
                    if (c3_hdr) stat_syms_hdr <= stat_syms_hdr == 32'hFFFFFFFF ? stat_syms_hdr : stat_syms_hdr + 1'b1;
                    else stat_syms_pay <= stat_syms_pay == 32'hFFFFFFFF ? stat_syms_pay : stat_syms_pay + 1'b1;
                end
            end
            // AXI-side read: take the request, use port A in a free cycle.
            rd_valid <= 0;
            if (rd_cancel) begin
                rd_pending <= 0; rd_issued <= 0;
            end else begin
                if (rd_req && !rd_pending && !rd_issued) begin rd_pending <= 1; rd_addr_q <= rd_addr; end
                if (rd_pending && !pipe_read) begin rd_pending <= 0; rd_issued <= 1; end
                if (rd_issued) begin rd_issued <= 0; rd_valid <= 1; rd_data <= port_a; end
            end
        end
    end
endmodule
