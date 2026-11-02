`timescale 1ns/1ps
// Unit bench for ofdm_rxs_cmetric: cycle stimulus from scripts/rtl/nc_cmetric_vectors.py,
// every AXI-side read and the final banks/counters compared with the reference.
module tb_nc_cmetric;
    reg clk = 0, resetn = 0;
    always #2.5 clk = ~clk;
    reg [31:0] stim [0:200000];
    reg [31:0] exp_mem [0:20000];
    reg s_valid = 0, s_qam = 0, s_null = 0, s_hdr = 0, s_usable = 1, s_sym_last = 0;
    reg clear = 0, freeze = 0, rd_req = 0;
    reg [6:0] s_ord = 0;
    reg [31:0] s_data = 0;
    reg [8:0] rd_addr = 0;
    wire [31:0] rd_data, syms_hdr, syms_pay;
    wire rd_valid, clear_busy;
    ofdm_rxs_cmetric dut (.clk(clk), .resetn(resetn), .cfg_enable(1'b1), .cfg_freeze(freeze), .clear(clear),
        .clear_busy(clear_busy), .s_valid(s_valid), .s_ord(s_ord), .s_data(s_data), .s_qam(s_qam), .s_null(s_null),
        .s_hdr(s_hdr), .s_usable(s_usable), .s_sym_last(s_sym_last), .rd_addr(rd_addr), .rd_req(rd_req), .rd_cancel(1'b0),
        .rd_data(rd_data), .rd_valid(rd_valid), .stat_syms_hdr(syms_hdr), .stat_syms_pay(syms_pay));

    integer cycles, reads, n, e, errors, a, waitc;
    reg [31:0] ctrl;
    initial begin
        if (!$value$plusargs("CYCLES=%d", cycles)) $fatal(1, "missing +CYCLES");
        if (!$value$plusargs("READS=%d", reads)) $fatal(1, "missing +READS");
        $readmemh("stim.mem", stim, 0, 2 * cycles - 1);
        $readmemh("expect.mem", exp_mem, 0, reads + 385);
        errors = 0; e = 0;
        repeat (4) @(posedge clk);
        resetn <= 1;
        for (n = 0; n < cycles; n = n + 1) begin
            ctrl = stim[2*n + 1];
            s_data <= stim[2*n]; s_valid <= ctrl[0]; s_ord <= ctrl[7:1]; s_qam <= ctrl[8]; s_null <= ctrl[9];
            s_hdr <= ctrl[10]; s_usable <= ctrl[11]; s_sym_last <= ctrl[12]; clear <= ctrl[13]; freeze <= ctrl[14];
            rd_req <= ctrl[15]; rd_addr <= ctrl[24:16];
            @(posedge clk);
            if (rd_valid) begin
                if (rd_data !== exp_mem[e]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("CMETRIC_MISMATCH read=%0d got=%h exp=%h", e, rd_data, exp_mem[e]);
                end
                e = e + 1;
            end
        end
        s_valid <= 0; rd_req <= 0; clear <= 0; freeze <= 0;
        repeat (10) @(posedge clk);
        if (e != reads) begin errors = errors + 1; $display("CMETRIC_READ_COUNT got=%0d exp=%0d", e, reads); end
        for (a = 0; a < 384; a = a + 1) begin
            rd_addr <= a; rd_req <= 1; @(posedge clk); rd_req <= 0;
            waitc = 0;
            while (!rd_valid && waitc < 20) begin @(posedge clk); waitc = waitc + 1; end
            if (rd_data !== exp_mem[reads + a]) begin
                errors = errors + 1;
                if (errors < 20) $display("CMETRIC_FINAL_MISMATCH addr=%0d got=%h exp=%h", a, rd_data, exp_mem[reads + a]);
            end
            @(posedge clk);
        end
        if (syms_hdr !== exp_mem[reads + 384] || syms_pay !== exp_mem[reads + 385]) begin
            errors = errors + 1;
            $display("CMETRIC_SYMS got=%0d/%0d exp=%0d/%0d", syms_hdr, syms_pay, exp_mem[reads + 384], exp_mem[reads + 385]);
        end
        if (errors == 0) $display("CMETRIC_PASS cycles=%0d reads=%0d final=386", cycles, reads);
        else $display("CMETRIC_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
