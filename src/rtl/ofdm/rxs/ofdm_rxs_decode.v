`timescale 1ns/1ps
// Header and payload decoder for the streaming RX (protocol V0.2).
// Input: 88 data carriers per symbol in signed order, sym 2/3 = repeated QPSK
// header, sym >= 4 = whitened payload (QPSK or 16QAM per header).  Emits one
// status record per frame that reached the header stage, sends the symbol
// limit (or abort) back to the fetcher, and compares the payload with the
// per-frame PRBS pattern when enabled.
//
// Payload pipeline (one carrier per cycle at most):
//   p1: demap + descramble, register bits      (carrier counter, no per-bit compare)
//   p2: byte assembly
//   p3: byte CRC / received CRC / PRBS error byte
//   p4: error accumulation
//   p5: status record (after the last byte has passed p4)
// The body always ends on a carrier boundary (2 or 4 bits per carrier, 8-bit
// bytes), so the frame end is a carrier count: (8L+32)/2 or /4.
//
// NC extension (docs/innovation/b_subcarrier_mask_design.md sections 2.4, 3, 5.2):
// frames may switch off whole 8-carrier groups; masked carriers carry no payload
// and the 16-byte header sits on the first 64 unmasked carriers, its bytes 10..11
// echoing the mask.  The header is tried with candidate masks in order
// {last accepted mask, blind mask (cfg_blind_en, at most 3 groups), 0}; the first
// whose CRC passes, fields are legal and echo equals the candidate is accepted.
// Blind mask: per-group sum over sym 3 of ||hsum_I|-23170| + ||hsum_Q|-23170|
// above cfg_hdr_thr (a masked group sends zeros, about 46340 per carrier).
// More than 191 symbols for the accepted mask is a header failure.  With mask 0
// every record and the payload processing are those of the accepted decoder.
module ofdm_rxs_decode (
    input wire clk,
    input wire resetn,
    input wire cfg_prbs_check,
    input wire cfg_blind_en,
    input wire [20:0] cfg_hdr_thr,
    input wire [31:0] s_data,
    input wire [7:0] s_tag,
    input wire [7:0] s_sym,
    input wire s_usable,
    input wire s_first,
    input wire s_last,
    input wire s_valid,
    output wire s_ready,
    // feedback to the fetcher
    output reg fb_valid,
    output reg [7:0] fb_tag,
    output reg [7:0] fb_nsym,
    // frame status record (single-cycle pulse)
    output reg st_valid,
    output reg [7:0] st_tag,
    output reg [3:0] st_reason,      // 0 OK, 1 header CRC/fields, 2 payload CRC, 3 truncated
    output reg [31:0] st_frame_id,
    output reg [12:0] st_payload_len,
    output reg st_mcs,
    output reg [15:0] st_epoch,
    output reg [31:0] st_bit_errors,
    output reg [31:0] st_compared_bits,
    output reg [15:0] st_unusable,
    // EVM: sum over payload carriers of |error|^2 in F14 units, >> 16
    output reg [31:0] st_evm_sum,
    output reg [14:0] st_carriers,
    output reg [10:0] st_mask,
    // [10:0] last accepted mask, [13:12] candidate of the last accepted header
    // (0 last, 1 blind, 2 zero, 3 none yet), [14] last blind mask had >3 groups,
    // [26:16] last blind mask
    output wire [31:0] st_rx_last,
    // [15:0] headers accepted through the blind candidate, [31:16] through zero
    output wire [31:0] stat_rx_cnt,
    // per-carrier metric feed (ofdm_rxs_cmetric): header copies of the frame being
    // received and all 88 carriers of its payload symbols (masked ones as s_null)
    output reg cm_valid,
    output reg [6:0] cm_ord,
    output reg [31:0] cm_data,
    output reg cm_qam,
    output reg cm_null,
    output reg cm_hdr,
    output reg cm_usable,
    output reg cm_sym_last
);
    localparam [3:0] R_OK = 0, R_HEADER = 1, R_PAYLOAD = 2, R_TRUNC = 3;
    localparam [16:0] QAM_THRESHOLD = 17'd10362;   // 2/sqrt(10) in F14
    localparam [2:0] S_RUN = 0, S_CRC = 1, S_FIELDS = 2, S_CHECK = 3, S_DIV = 4, S_CAND = 5;
    localparam [16:0] HDR_LEVEL = 17'd23170;   // two QPSK header copies, 2 * 11585
    reg [2:0] state;
    reg [7:0] tag;
    reg active, in_header, header_ok, mcs;
    (* ram_style = "distributed" *) reg [31:0] h0 [0:127];
    reg [6:0] carrier;
    reg [175:0] hbits;
    reg [3:0] crc_step;
    reg [31:0] crc;
    reg [127:0] hbytes;
    reg [12:0] plen;
    reg [31:0] frame_id;
    reg [15:0] epoch;
    reg [15:0] div_num, div_rem;
    reg [8:0] div_q;
    reg [8:0] div_den;                 // bits per payload symbol: 16G (QPSK) or 32G
    reg [9:0] nsym_full;
    // NC state
    reg [10:0] last_ok, cand_mask, frame_mask, fin_mask, blind_mask;
    reg [1:0] cand_idx, last_src;
    reg blind_over;
    reg [15:0] blind_hits, zero_hits;
    reg [6:0] ord_q;                   // data-carrier ordinal of the next beat
    // blind pipeline: b1 |hsum|, b2 L1 error, b3 group accumulation and compare
    reg b1_valid, b1_first, b1_glast, b2_valid, b2_first, b2_glast;
    reg [3:0] b1_group, b2_group;
    reg [16:0] b1_ai, b1_aq;
    reg [17:0] b2_l1;
    reg [20:0] b_acc;
    reg [10:0] b_bad;
    reg [4:0] div_i;
    reg [7:0] nsym;
    reg [14:0] carriers_left;
    reg [6:0] lfsr;
    reg [15:0] unusable;

    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0] b;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
            crc_byte = x;
        end
    endfunction
    function [31:0] xorshift;
        input [31:0] x0;
        reg [31:0] x;
        begin
            x = x0 ^ (x0 << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
            xorshift = x;
        end
    endfunction
    `include "ofdm_nc_map.vh"
    // Header bytes = 16-bit blocks of the first eight unmasked groups;
    // group g occupies hb[175-16g -: 16].
    function [127:0] nc_hdr_select;
        input [175:0] hb;
        input [10:0] m;
        integer g, k;
        begin
            nc_hdr_select = 128'd0;
            k = 0;
            for (g = 0; g < 11; g = g + 1)
                if (!m[g] && k < 8) begin
                    nc_hdr_select[127 - 16*k -: 16] = hb[175 - 16*g -: 16];
                    k = k + 1;
                end
        end
    endfunction
    function [3:0] popcount8;
        input [7:0] v;
        begin
            popcount8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
        end
    endfunction

    // ------------------------------------------------------------- header
    wire [31:0] h0v = h0[carrier];
    wire signed [16:0] hsum_i = $signed(h0v[15:0]) + $signed(s_data[15:0]);
    wire signed [16:0] hsum_q = $signed(h0v[31:16]) + $signed(s_data[31:16]);

    // ---------------------------------------------------------- p1 demap
    wire signed [15:0] di = s_data[15:0];
    wire signed [15:0] dq = s_data[31:16];
    wire [16:0] adi = di[15] ? -{di[15], di} : {1'b0, di};
    wire [16:0] adq = dq[15] ? -{dq[15], dq} : {1'b0, dq};
    // Bits in transmission order: QPSK {b0,b1}; 16QAM {b0,b1,b2,b3}.
    wire [3:0] raw_bits = mcs ? {di[15], adi < QAM_THRESHOLD, dq[15], adq < QAM_THRESHOLD}
                              : {di[15], dq[15], 2'b00};
    // Descrambler x^7+x^4+1: bit = s6 ^ s3, the produced bit shifts in.
    wire w0 = lfsr[6] ^ lfsr[3];
    wire w1 = lfsr[5] ^ lfsr[2];
    wire w2 = lfsr[4] ^ lfsr[1];
    wire w3 = lfsr[3] ^ lfsr[0];
    wire [6:0] lfsr_next = mcs ? {lfsr[2:0], w0, w1, w2, w3} : {lfsr[4:0], w0, w1};
    wire [3:0] pbits = raw_bits ^ (mcs ? {w0, w1, w2, w3} : {w0, w1, 2'b00});

    wire in_frame = active && s_tag == tag;
    wire [6:0] ord = s_first ? 7'd0 : ord_q;
    wire masked_now = frame_mask[ord[6:3]];
    wire want_payload = in_frame && header_ok && s_sym >= 8'd4 && s_sym < nsym && carriers_left != 0 &&
                        !masked_now;
    assign s_ready = resetn && state == S_RUN;
    wire fire = s_valid && s_ready;
    wire take_payload = fire && want_payload;
    // [10:0] last_ok, [11] 0, [13:12] last_src, [14] blind_over, [15] 0, [26:16] blind_mask
    assign st_rx_last = {5'd0, blind_mask, 1'b0, blind_over, last_src, 1'b0, last_ok};
    assign stat_rx_cnt = {zero_hits, blind_hits};
    // Blind candidate: |hsum| of the second header copy.
    wire [16:0] abs_hi = hsum_i[16] ? -hsum_i : hsum_i;
    wire [16:0] abs_hq = hsum_q[16] ? -hsum_q : hsum_q;
    wire [16:0] dev_i = b1_ai >= HDR_LEVEL ? b1_ai - HDR_LEVEL : HDR_LEVEL - b1_ai;
    wire [16:0] dev_q = b1_aq >= HDR_LEVEL ? b1_aq - HDR_LEVEL : HDR_LEVEL - b1_aq;
    wire [20:0] b_acc_next = (b2_first ? 21'd0 : b_acc) + {3'd0, b2_l1};
    wire take_header3 = fire && in_frame && in_header && s_sym == 8'd3;
    wire [3:0] blind_count = nc_popcount11(b_bad);
    wire blind_usable = cfg_blind_en && blind_count <= 4'd3;
    reg [10:0] cand_value;
    reg cand_ok;
    always @(*) begin
        case (cand_idx)
            2'd0: begin cand_value = last_ok; cand_ok = 1'b1; end
            2'd1: begin cand_value = b_bad; cand_ok = blind_usable && b_bad != last_ok; end
            2'd2: begin cand_value = 11'd0; cand_ok = last_ok != 11'd0 && !(blind_usable && b_bad == 11'd0); end
            default: begin cand_value = 11'd0; cand_ok = 1'b0; end
        endcase
    end

    reg p1_valid, p1_last, p1_mcs;
    reg [3:0] p1_bits;
    // EVM pipeline: p1 folded errors, p2 squares, p3 accumulation.
    localparam [16:0] QPSK_LEVEL = 17'd11585, QAM_LOW = 17'd5181, QAM_HIGH = 17'd15543;
    reg [16:0] a1_i, a1_q;           // |I|, |Q| registered at take
    reg a1_mcs, e1_valid;
    reg signed [17:0] e1_i, e1_q;
    reg [35:0] e2_sq;
    reg e2_valid;
    reg p5_last;
    reg [47:0] evm_acc;
    reg [14:0] evm_count;
    wire [16:0] ideal_i = a1_mcs ? (a1_i < QAM_THRESHOLD ? QAM_LOW : QAM_HIGH) : QPSK_LEVEL;
    wire [16:0] ideal_q = a1_mcs ? (a1_q < QAM_THRESHOLD ? QAM_LOW : QAM_HIGH) : QPSK_LEVEL;
    // p2 byte assembly
    reg [7:0] acc;
    reg [2:0] acc_bits;      // bits already held (0, 2, 4, 6)
    reg p2_valid, p2_last;
    reg [7:0] p2_byte;
    // p3 byte handling
    reg [12:0] byte_count;
    reg [31:0] pcrc, rx_crc, prbs;
    reg p3_valid, p3_last;
    reg [3:0] p3_errors;
    reg p3_payload;
    // p4 accumulation
    reg [31:0] bit_errors, compared;
    reg p4_last;
    // frame identity captured at the last carrier
    reg [7:0] fin_tag;
    reg [31:0] fin_id;
    reg [12:0] fin_len;
    reg fin_mcs;
    reg [15:0] fin_epoch, fin_unusable;

    wire [7:0] acc_next = p1_mcs ? {acc[3:0], p1_bits} : {acc[5:0], p1_bits[3:2]};
    wire [3:0] acc_count = {1'b0, acc_bits} + (p1_mcs ? 4'd4 : 4'd2);
    always @(posedge clk) begin
        if (!resetn) begin
            p1_valid <= 0; p2_valid <= 0; p3_valid <= 0; p4_last <= 0; acc_bits <= 0;
            p1_last <= 0; p2_last <= 0; p3_last <= 0;
            b1_valid <= 0; b2_valid <= 0; b_acc <= 0; b_bad <= 0;
        end else begin
            // blind header-group errors (sym 3, every data carrier)
            b1_valid <= take_header3;
            if (take_header3) begin
                b1_ai <= abs_hi; b1_aq <= abs_hq; b1_group <= carrier[6:3];
                b1_first <= carrier[2:0] == 3'd0; b1_glast <= carrier[2:0] == 3'd7;
            end
            b2_valid <= b1_valid;
            if (b1_valid) begin
                b2_l1 <= {1'b0, dev_i} + {1'b0, dev_q};
                b2_group <= b1_group; b2_first <= b1_first; b2_glast <= b1_glast;
            end
            if (b2_valid) begin
                b_acc <= b_acc_next;
                if (b2_glast) b_bad[b2_group] <= b_acc_next > cfg_hdr_thr;
            end
            // p1
            p1_valid <= take_payload;
            if (take_payload) begin
                p1_bits <= pbits; p1_mcs <= mcs; p1_last <= carriers_left == 15'd1;
                a1_i <= adi; a1_q <= adq; a1_mcs <= mcs;
            end
            // EVM: p1 |x| -> p2 error vs nearest level -> p3 square -> p4 accumulate
            e1_valid <= p1_valid;
            if (p1_valid) begin
                e1_i <= $signed({1'b0, a1_i}) - $signed({1'b0, ideal_i});
                e1_q <= $signed({1'b0, a1_q}) - $signed({1'b0, ideal_q});
            end
            e2_valid <= e1_valid;
            if (e1_valid) e2_sq <= e1_i * e1_i + e1_q * e1_q;
            p5_last <= p4_last;
            if (e2_valid) begin evm_acc <= evm_acc + e2_sq; evm_count <= evm_count + 1'b1; end
            // p2
            p2_valid <= 0; p2_last <= 0;
            if (p1_valid) begin
                if (acc_count == 4'd8) begin
                    p2_valid <= 1; p2_byte <= acc_next; p2_last <= p1_last; acc_bits <= 0;
                end else acc_bits <= acc_count[2:0];
                acc <= acc_next;
            end
            // p3
            p3_valid <= p2_valid; p3_last <= p2_valid && p2_last;
            if (p2_valid) begin
                byte_count <= byte_count + 1'b1;
                p3_payload <= byte_count < plen;
                p3_errors <= popcount8(p2_byte ^ xorshift(prbs));
                if (byte_count < plen) begin
                    pcrc <= crc_byte(pcrc, p2_byte);
                    prbs <= xorshift(prbs);
                end else rx_crc <= {p2_byte, rx_crc[31:8]};
            end
            // p4
            p4_last <= p3_last;
            if (p3_valid && p3_payload && cfg_prbs_check) begin
                bit_errors <= bit_errors + p3_errors;
                compared <= compared + 32'd8;
            end
            // reset of the payload accumulators at the start of each payload
            if (state == S_DIV && div_i == 5'd17 && header_ok) begin
                acc_bits <= 0; byte_count <= 0; pcrc <= 32'hFFFFFFFF; rx_crc <= 0;
                prbs <= (frame_id ^ 32'hA5A5A5A5) == 0 ? 32'd1 : (frame_id ^ 32'hA5A5A5A5);
                bit_errors <= 0; compared <= 0; evm_acc <= 0; evm_count <= 0;
            end
        end
    end

    // ------------------------------------------------------------ control
    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_RUN; active <= 0; in_header <= 0; tag <= 0; fb_valid <= 0; st_valid <= 0;
            header_ok <= 0; mcs <= 0; carrier <= 0; nsym <= 0; carriers_left <= 0;
            div_i <= 0; crc_step <= 0; unusable <= 0; lfsr <= 7'h7f;
            last_ok <= 0; cand_mask <= 0; frame_mask <= 0; fin_mask <= 0; blind_mask <= 0;
            cand_idx <= 0; last_src <= 2'd3; blind_over <= 0; blind_hits <= 0; zero_hits <= 0;
            ord_q <= 0; st_mask <= 0; div_den <= 9'd176; nsym_full <= 0;
            cm_valid <= 0;
        end else begin
            if (fire) ord_q <= s_last ? 7'd0 : ord + 7'd1;
            cm_valid <= fire && ((s_sym == 8'd2 && (s_first || in_frame)) ||
                                 (in_frame && in_header && s_sym == 8'd3) ||
                                 (in_frame && header_ok && s_sym >= 8'd4 && s_sym < nsym));
            if (fire) begin
                cm_ord <= ord; cm_data <= s_data; cm_qam <= mcs; cm_null <= masked_now;
                cm_hdr <= s_sym == 8'd2 || s_sym == 8'd3; cm_usable <= s_usable; cm_sym_last <= s_last;
            end
            if (b2_valid && b2_glast && b2_group == 4'd10) begin
                blind_mask <= {b_acc_next > cfg_hdr_thr, b_bad[9:0]};
                blind_over <= nc_popcount11({b_acc_next > cfg_hdr_thr, b_bad[9:0]}) > 4'd3;
            end
            fb_valid <= 0; st_valid <= 0;
            case (state)
                S_RUN: begin
                    if (fire) begin
                        // A new tag starting at H0 opens a context; an unfinished
                        // previous frame is reported as truncated.
                        if (s_sym == 8'd2 && s_first && !in_frame) begin
                            if (active && header_ok && carriers_left != 0) begin
                                st_valid <= 1; st_tag <= tag; st_reason <= R_TRUNC;
                                st_frame_id <= frame_id; st_payload_len <= plen; st_mcs <= mcs;
                                st_epoch <= epoch; st_bit_errors <= bit_errors;
                                st_compared_bits <= compared; st_unusable <= unusable;
                                st_evm_sum <= evm_acc[47:16]; st_carriers <= evm_count;
                                st_mask <= frame_mask;
                            end
                            active <= 1; in_header <= 1; tag <= s_tag; header_ok <= 0; nsym <= 0;
                            carriers_left <= 0; unusable <= 0;
                        end
                        if (s_sym == 8'd2 && (s_first || in_frame)) begin
                            h0[s_first ? 7'd0 : carrier] <= s_data;
                            carrier <= s_last ? 7'd0 : (s_first ? 7'd1 : carrier + 1'b1);
                        end else if (in_frame && in_header && s_sym == 8'd3) begin
                            hbits <= {hbits[173:0], hsum_i[16], hsum_q[16]};
                            carrier <= s_last ? 7'd0 : carrier + 1'b1;
                            if (s_last) begin
                                in_header <= 0; cand_idx <= 0; state <= S_CAND;
                            end
                        end else if (want_payload) begin
                            if (!s_usable) unusable <= unusable + 1'b1;
                            lfsr <= lfsr_next;
                            carriers_left <= carriers_left - 1'b1;
                            if (carriers_left == 15'd1) begin
                                fin_tag <= tag; fin_id <= frame_id; fin_len <= plen; fin_mcs <= mcs;
                                fin_epoch <= epoch; fin_unusable <= unusable + (s_usable ? 16'd0 : 16'd1);
                                fin_mask <= frame_mask;
                            end
                        end
                    end
                    // Status after the last byte and the last EVM term are accumulated.
                    if (p5_last) begin
                        st_valid <= 1; st_tag <= fin_tag; st_frame_id <= fin_id; st_payload_len <= fin_len;
                        st_mcs <= fin_mcs; st_epoch <= fin_epoch; st_unusable <= fin_unusable;
                        st_reason <= rx_crc == ~pcrc ? R_OK : R_PAYLOAD;
                        st_bit_errors <= bit_errors; st_compared_bits <= compared;
                        st_evm_sum <= evm_acc[47:16]; st_carriers <= evm_count;
                        st_mask <= fin_mask;
                    end
                end
                S_CAND: begin
                    // The blind result of the last group (two cycles after the last
                    // header carrier) is ready long before candidate 1 is evaluated.
                    if (cand_idx == 2'd3) begin
                        fb_valid <= 1; fb_tag <= tag; fb_nsym <= 8'd0;
                        st_valid <= 1; st_tag <= tag; st_reason <= R_HEADER; st_frame_id <= frame_id;
                        st_payload_len <= plen; st_mcs <= mcs; st_epoch <= epoch;
                        st_bit_errors <= 0; st_compared_bits <= 0; st_unusable <= 0;
                        st_evm_sum <= 0; st_carriers <= 0; st_mask <= cand_mask;
                        active <= 0; state <= S_RUN;
                    end else if (cand_ok) begin
                        cand_mask <= cand_value; crc <= 32'hFFFFFFFF; crc_step <= 0; state <= S_CRC;
                    end else cand_idx <= cand_idx + 2'd1;
                end
                S_CRC: begin
                    // The 128 header bits, MSB first per byte, from the candidate's groups.
                    if (crc_step == 0) hbytes <= nc_hdr_select(hbits, cand_mask);
                    else crc <= crc_byte(crc, hbytes[127 - 8*(crc_step-1) -: 8]);
                    if (crc_step == 4'd12) state <= S_FIELDS;
                    crc_step <= crc_step + 1'b1;
                end
                S_FIELDS: begin
                    // Byte order: [0]=version [1]=mcs [2..5]=id LE [6..7]=len LE
                    // [8..9]=epoch LE [10..11]=reserved [12..15]=crc LE.
                    frame_id <= {hbytes[87:80], hbytes[95:88], hbytes[103:96], hbytes[111:104]};
                    plen <= {hbytes[68:64], hbytes[79:72]};
                    epoch <= {hbytes[55:48], hbytes[63:56]};
                    mcs <= hbytes[112];
                    header_ok <= (~crc) == {hbytes[7:0], hbytes[15:8], hbytes[23:16], hbytes[31:24]}
                        && hbytes[127:120] == 8'd1 && hbytes[119:113] == 7'd0
                        && hbytes[47:40] == cand_mask[7:0] && hbytes[39:32] == {5'd0, cand_mask[10:8]}
                        && {hbytes[71:64], hbytes[79:72]} <= 16'd4096;
                    div_num <= {hbytes[68:64], hbytes[79:72], 3'b000} + 16'd32;
                    div_rem <= 0; div_q <= 0; div_i <= 0;
                    state <= S_CHECK;
                end
                S_CHECK: if (!header_ok) begin
                    cand_idx <= cand_idx + 2'd1; state <= S_CAND;
                end else begin
                    frame_mask <= cand_mask; last_ok <= cand_mask; last_src <= cand_idx;
                    if (cand_idx == 2'd1) blind_hits <= blind_hits + 1'b1;
                    if (cand_idx == 2'd2) zero_hits <= zero_hits + 1'b1;
                    div_den <= mcs ? {4'd11 - nc_popcount11(cand_mask), 5'd0}
                                   : {1'b0, 4'd11 - nc_popcount11(cand_mask), 4'd0};
                    div_i <= 1; state <= S_DIV;
                end
                S_DIV: begin
                    if (div_i <= 5'd16) begin
                        // restoring division of the body bits by 16G (QPSK) or 32G (16QAM)
                        if ({div_rem[14:0], div_num[15]} >= {7'd0, div_den}) begin
                            div_rem <= {div_rem[14:0], div_num[15]} - {7'd0, div_den};
                            div_q <= {div_q[7:0], 1'b1};
                        end else begin
                            div_rem <= {div_rem[14:0], div_num[15]}; div_q <= {div_q[7:0], 1'b0};
                        end
                        div_num <= {div_num[14:0], 1'b0};
                        div_i <= div_i + 1'b1;
                    end else if (div_i == 5'd17) begin
                        nsym_full <= 10'd4 + {1'b0, div_q} + (div_rem != 0 ? 10'd1 : 10'd0);
                        div_i <= 5'd18;
                    end else if (nsym_full > 10'd191) begin
                        // More symbols than the fetcher can deliver: a header failure.
                        fb_valid <= 1; fb_tag <= tag; fb_nsym <= 8'd0;
                        st_valid <= 1; st_tag <= tag; st_reason <= R_HEADER; st_frame_id <= frame_id;
                        st_payload_len <= plen; st_mcs <= mcs; st_epoch <= epoch;
                        st_bit_errors <= 0; st_compared_bits <= 0; st_unusable <= 0;
                        st_evm_sum <= 0; st_carriers <= 0; st_mask <= frame_mask;
                        header_ok <= 0; active <= 0; div_i <= 0; state <= S_RUN;
                    end else begin
                        nsym <= nsym_full[7:0];
                        fb_valid <= 1; fb_tag <= tag; fb_nsym <= nsym_full[7:0];
                        // carriers = body bits / bits per carrier
                        carriers_left <= mcs ? {plen, 1'b0} + 15'd8 : {plen, 2'b00} + 15'd16;
                        lfsr <= 7'h7f;
                        div_i <= 0; state <= S_RUN;
                    end
                end
                default: state <= S_RUN;
            endcase
        end
    end
endmodule
