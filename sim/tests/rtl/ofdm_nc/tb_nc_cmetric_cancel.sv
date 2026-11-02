`timescale 1ns/1ps
// Directed bench for independent review F1: a metric read that times out at the requester must
// not deliver its late response to the next read.  A continuous input stream keeps the
// RAM read port busy; the first read (HDR[0]) is abandoned after 64 cycles (rd_cancel
// when HAS_CANCEL is defined, as the core does), then PAY[3] is read.  The response to
// the second read must be PAY[3] (0), and exactly one response may follow it.
module tb_nc_cmetric_cancel;
    reg clk = 0, resetn = 0;
    always #2.5 clk = ~clk;
    reg s_valid = 0, s_hdr = 0, rd_req = 0, rd_cancel = 0;
    reg [6:0] s_ord = 0;
    reg [31:0] s_data = 0;
    reg [8:0] rd_addr = 0;
    wire [31:0] rd_data, syms_hdr, syms_pay;
    wire rd_valid, clear_busy;
    ofdm_rxs_cmetric dut (.clk(clk), .resetn(resetn), .cfg_enable(1'b1), .cfg_freeze(1'b0), .clear(1'b0),
        .clear_busy(clear_busy), .s_valid(s_valid), .s_ord(s_ord), .s_data(s_data), .s_qam(1'b0), .s_null(1'b0),
        .s_hdr(s_hdr), .s_usable(1'b1), .s_sym_last(1'b0), .rd_addr(rd_addr), .rd_req(rd_req),
`ifdef HAS_CANCEL
        .rd_cancel(rd_cancel),
`endif
        .rd_data(rd_data), .rd_valid(rd_valid), .stat_syms_hdr(syms_hdr), .stat_syms_pay(syms_pay));

    integer k, errors, responses;
    reg [31:0] got;
    localparam [31:0] HDR_ZERO = (2 * 11585 * 11585) >> 12;   // QPSK reference, received 0
    always @(posedge clk) if (rd_valid) begin responses = responses + 1; got = rd_data; end

    initial begin
        errors = 0; responses = 0;
        repeat (4) @(posedge clk); resetn <= 1;
        repeat (400) @(posedge clk);                              // reset clear of 385 cycles
        // Phase A: header bank, received 0 on every carrier -> HDR[d] = HDR_ZERO.
        for (k = 0; k < 88; k = k + 1) begin
            s_valid <= 1; s_hdr <= 1; s_ord <= k; s_data <= 0; @(posedge clk);
        end
        s_valid <= 0; repeat (10) @(posedge clk);
        // Phase B: continuous payload stream exactly on the QPSK points (error 0).
        fork
            begin
                for (k = 0; k < 600; k = k + 1) begin
                    s_valid <= 1; s_hdr <= 0; s_ord <= k % 88; s_data <= {16'd11585, 16'd11585}; @(posedge clk);
                end
                s_valid <= 0;
            end
            begin
                repeat (20) @(posedge clk);
                rd_addr <= 9'd0; rd_req <= 1; @(posedge clk); rd_req <= 0;          // HDR[0]
                repeat (64) @(posedge clk);
                if (responses != 0) begin errors = errors + 1; $display("CANCEL_UNEXPECTED early response"); end
                rd_cancel <= 1; @(posedge clk); rd_cancel <= 0;                     // requester timed out
                repeat (20) @(posedge clk);
                rd_addr <= {2'd1, 7'd3}; rd_req <= 1; @(posedge clk); rd_req <= 0;  // PAY[3]
            end
        join
        repeat (40) @(posedge clk);
        $display("CANCEL_OBS responses=%0d data=%0d expected_data=0", responses, got);
        if (responses != 1 || got !== 32'd0) errors = errors + 1;
        // The data path still works: HDR[0] read without contention.
        responses = 0;
        rd_addr <= 9'd0; rd_req <= 1; @(posedge clk); rd_req <= 0;
        repeat (10) @(posedge clk);
        $display("CANCEL_OBS2 responses=%0d data=%0d expected_data=%0d", responses, got, HDR_ZERO);
        if (responses != 1 || got !== HDR_ZERO) errors = errors + 1;
        if (errors == 0) $display("CANCEL_PASS"); else $display("CANCEL_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
