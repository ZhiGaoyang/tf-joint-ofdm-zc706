`timescale 1ps/1ps
// Platform-level host test of the lean development core: AXI-Lite control,
// TX burst through the real prefill/CDC at 61.44 MHz (two samples per DAC
// beat), digital loop to a 122.88 MHz ADC stream (one sample per beat), real
// RX adapter CDC, streaming RX, coherent statistics snapshot.
// NC copy: the accepted sequence first (mask 0, backoff 10), then the NC
// registers (0x048..0x06C) with masked bursts at backoff 16, an illegal mask
// (TX fault, no frames) and recovery by the next TX_GO.
module tb_nc_lean_core;
    reg clk = 0, tx_clk = 0, rx_clk = 0;
    always #2500 clk = ~clk;                 // 200 MHz
    always #8138 tx_clk = ~tx_clk;           // 61.44 MHz
    always #4069 rx_clk = ~rx_clk;           // 122.88 MHz
    reg global_arst = 1;
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire [31:0] dev_i_tx, dev_q_tx;
    wire dev_underflow_tx, session_arst, legacy_irq, bridge_irq;
    wire [31:0] retained_faults, mismatch_count;
    reg [15:0] rf_i = 0, rf_q = 0;
    reg [1:0] rf_valid = 0;
    wire s_axis_mm2s_tready, m_axis_s2mm_tvalid, m_axis_s2mm_tlast;
    wire [63:0] m_axis_s2mm_tdata;
    wire [7:0] m_axis_s2mm_tkeep;
    ofdm_development_core dut (
        .clk(clk), .tx_clk(tx_clk), .rx_clk(rx_clk), .global_arst(global_arst),
        // Model the board-shell feedback dev_arst = global | session | rf resets.
        .dev_arst(global_arst | session_arst), .rf_tx_arst(1'b0), .rf_rx_arst(1'b0),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_mm2s_tdata(64'd0), .s_axis_mm2s_tkeep(8'd0), .s_axis_mm2s_tlast(1'b0),
        .s_axis_mm2s_tvalid(1'b0), .s_axis_mm2s_tready(s_axis_mm2s_tready),
        .m_axis_s2mm_tdata(m_axis_s2mm_tdata), .m_axis_s2mm_tkeep(m_axis_s2mm_tkeep),
        .m_axis_s2mm_tlast(m_axis_s2mm_tlast), .m_axis_s2mm_tvalid(m_axis_s2mm_tvalid),
        .m_axis_s2mm_tready(1'b1),
        .dev_i_tx(dev_i_tx), .dev_q_tx(dev_q_tx), .dev_underflow_tx(dev_underflow_tx),
        .dev_request_tx(2'b11), .dev_enable_tx(2'b11), .dev_request_mismatch_tx(1'b0),
        .rf_i_rx(rf_i), .rf_q_rx(rf_q), .rf_enable_rx(2'b11), .rf_valid_rx(rf_valid),
        .session_arst(session_arst), .legacy_irq(legacy_irq), .bridge_irq(bridge_irq),
        .retained_boundary_faults(retained_faults), .boundary_mismatch_count_tx(mismatch_count));

    // DAC pairs -> ADC samples: the DAC takes two samples per tx_clk, the ADC
    // delivers one per rx_clk (exactly twice the rate), through a short queue.
    reg [31:0] q [0:255];
    reg [7:0] q_wr = 0, q_rd = 0;
    always @(posedge tx_clk) begin
        q[q_wr] <= {dev_q_tx[15:0], dev_i_tx[15:0]};
        q[q_wr + 8'd1] <= {dev_q_tx[31:16], dev_i_tx[31:16]};
        q_wr <= q_wr + 8'd2;
    end
    reg started = 0;
    reg [1:0] loop_atten = 0;   // channel loss: arithmetic >> on I and Q
    always @(posedge rx_clk) begin
        if (!started && q_wr >= 8'd16) started <= 1;
        rf_valid <= started ? 2'b11 : 2'b00;
        if (started) begin
            rf_i <= $signed(q[q_rd][15:0]) >>> loop_atten;
            rf_q <= $signed(q[q_rd][31:16]) >>> loop_atten;
            q_rd <= q_rd + 1'b1;
        end
    end

    task axi_write(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            fork
                begin wait (awready); @(posedge clk); while (!awready) @(posedge clk); awvalid <= 0; end
                begin wait (wready); @(posedge clk); while (!wready) @(posedge clk); wvalid <= 0; end
            join
            while (!bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask
    task axi_read(input [11:0] a, output [31:0] d);
        begin
            @(posedge clk); araddr <= a; arvalid <= 1;
            @(posedge clk); while (!arready) @(posedge clk); arvalid <= 0;
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(posedge clk);
        end
    endtask

    reg [31:0] v, crc_ok, crc_fail, hdr_fail, ber_lo, cmp_lo, issued, det, st;
    integer wait_cycles, failures, d;
    reg [31:0] hdr_m, pay_m, era_m, syms_h;
    task snapshot;
        begin
            axi_write(12'h040, 1);
            axi_read(12'h080, issued);
            axi_read(12'h08C, det);
            axi_read(12'h09C, hdr_fail);
            axi_read(12'h0A0, crc_ok);
            axi_read(12'h0A4, crc_fail);
            axi_read(12'h0AC, ber_lo);
            axi_read(12'h0B4, cmp_lo);
            axi_read(12'h044, st);
        end
    endtask
    task burst(input [15:0] frames, input [31:0] first, input [12:0] len, input mcs, input [31:0] expect_ok);
        begin
            axi_write(12'h010, frames);
            axi_write(12'h014, first);
            axi_write(12'h018, len);
            axi_write(12'h01C, mcs);
            axi_write(12'h00C, 1);
            wait_cycles = 0;
            snapshot;
            while (crc_ok < expect_ok && wait_cycles < 60) begin
                repeat (5000) @(posedge clk);
                wait_cycles = wait_cycles + 1;
                snapshot;
                if (wait_cycles % 5 == 0)
                    $display("LEAN_POLL t=%0t status=%h issued=%0d det=%0d crc_ok=%0d tstate=%0d ready_phy=%0d ready_tx=%0d prefilled=%0d rxvalid=%0d ad_valid=%0d tx_samples=%0d",
                        $time, st, issued, det, crc_ok, dut.tstate, dut.tx_ready_phy, dut.tx_ready_tx_phy, dut.tx_prefilled,
                        rf_valid, dut.ad_valid, dut.tx_samples);
            end
            $display("LEAN_BURST frames=%0d len=%0d mcs=%0d issued=%0d det=%0d hdr_fail=%0d crc_ok=%0d crc_fail=%0d ber=%0d cmp=%0d status=%h",
                frames, len, mcs, issued, det, hdr_fail, crc_ok, crc_fail, ber_lo, cmp_lo, st);
            if (crc_ok != expect_ok || crc_fail != 0 || hdr_fail != 0 || ber_lo != 0) failures = failures + 1;
        end
    endtask

    initial begin
        failures = 0;
        repeat (50) @(posedge clk);
        global_arst <= 0;
        repeat (100) @(posedge clk);
        axi_read(12'h000, v);
        $display("LEAN_ID %h", v);
        if (v != 32'h4F464442) failures = failures + 1;
        axi_write(12'h008, 32'h3);            // rx_enable, prbs_check
        repeat (200) @(posedge clk);
        burst(16'd6, 32'd100, 13'd256, 1'b0, 32'd6);
        burst(16'd4, 32'd200, 13'd300, 1'b1, 32'd10);
        burst(16'd8, 32'd300, 13'd0, 1'b0, 32'd18);
        // TX digital gain x4 (0x038 = 2) through a channel that loses x4, as on the
        // board: the RX input level stays nominal and the TX output must not clip.
        axi_write(12'h038, 32'd2);
        loop_atten = 2;
        axi_read(12'h038, v);
        $display("LEAN_TXGAIN %0d", v);
        if (v != 2) failures = failures + 1;
        burst(16'd4, 32'd500, 13'd512, 1'b1, 32'd22);
        axi_write(12'h038, 32'd0);
        loop_atten = 0;
        // PL digital loopback: switch with RX disabled, counters restart with RX.
        axi_write(12'h008, 32'h2);
        repeat (100) @(posedge clk);
        axi_write(12'h008, 32'h13);
        repeat (400) @(posedge clk);
        burst(16'd5, 32'd400, 13'd100, 1'b0, 32'd5);
        axi_read(12'h008, v);
        $display("LEAN_LOOPBACK ctrl=%h", v);
        // ------------------------------------------------------------ NC part
        axi_read(12'h004, v); $display("LEAN_NC version=%h", v);
        if (v != 32'h20261025) failures = failures + 1;
        axi_read(12'h048, v); if (v != 0) failures = failures + 1;
        axi_read(12'h04C, v); if (v != 32'h01000000) failures = failures + 1;
        axi_read(12'h050, v); $display("LEAN_NC reset cfg ok hdr_thr=%0d", v); if (v != 185360) failures = failures + 1;
        // RX off, backoff 16 (blank 720, plateau 12), RX on with PL loopback kept off.
        axi_write(12'h008, 32'h2);
        repeat (100) @(posedge clk);
        axi_write(12'h030, (32'd16 << 20) | (32'd720 << 8) | 32'd12);
        axi_write(12'h008, 32'h3);
        repeat (400) @(posedge clk);
        axi_write(12'h048, 32'h080);
        // Per-carrier metrics on (blind kept on), cleared before the burst.
        axi_write(12'h04C, 32'h03000000);
        axi_write(12'h054, 32'd1);
        repeat (600) @(posedge clk);
        axi_read(12'h054, v); if (v[8]) failures = failures + 1;
        burst(16'd4, 32'd700, 13'd256, 1'b0, 32'd4);
        axi_write(12'h04C, 32'h07000000);          // freeze for a consistent read
        axi_read(12'h058, v); $display("LEAN_NC syms_hdr=%0d", v); if (v != 8) failures = failures + 1;
        syms_h = v;
        axi_read(12'h05C, v); $display("LEAN_NC syms_pay=%0d", v); if (v != 4 * 13) failures = failures + 1;   // P = ceil(260 / 20)
        for (d = 0; d < 88; d = d + 1) begin
            axi_read(12'h200 + 4 * d, hdr_m);
            axi_read(12'h400 + 4 * d, pay_m);
            axi_read(12'h600 + 4 * d, era_m);
            if (d / 8 == 7) begin
                if (hdr_m < 65000 * syms_h || hdr_m > 65536 * syms_h) begin failures = failures + 1;
                    $display("LEAN_NC_METRIC_BAD masked hdr d=%0d %0d", d, hdr_m); end
            end else if (hdr_m > 655 * syms_h) begin failures = failures + 1;
                $display("LEAN_NC_METRIC_BAD hdr d=%0d %0d", d, hdr_m); end
            if (pay_m > 655 * 52 || era_m != 0) begin failures = failures + 1;
                $display("LEAN_NC_METRIC_BAD pay/erase d=%0d %0d %0d", d, pay_m, era_m); end
            if (d == 0 || d == 56 || d == 63) $display("LEAN_NC metric d=%0d hdr=%0d pay=%0d erase=%0d", d, hdr_m, pay_m, era_m);
        end
        axi_write(12'h04C, 32'h01000000);          // metrics off, blind on
        axi_read(12'h068, v); $display("LEAN_NC tx_status=%h", v);
        if (v != {13'd0, 7'd80, 1'b0, 11'h080}) failures = failures + 1;
        axi_read(12'h06C, v); $display("LEAN_NC last_mask=%h", v); if (v != 32'h080) failures = failures + 1;
        axi_read(12'h064, v); $display("LEAN_NC rx_cnt=%h", v); if (v[15:0] == 0) failures = failures + 1;
        // independent F3: full 32-bit NC_RX_LAST: [10:0] last_ok, [13:12] src, [14] blind_over, [26:16] blind mask.
        axi_read(12'h060, v); $display("LEAN_NC rx_last=%h", v); if (v != 32'h00800080) failures = failures + 1;
        // independent F1: metrics were read frozen; no read may have timed out.
        axi_read(12'h054, v); $display("LEAN_NC metric_ctrl=%h", v); if (v[9]) failures = failures + 1;
        axi_write(12'h048, 32'h007);
        burst(16'd2, 32'd800, 13'd2000, 1'b1, 32'd6);
        axi_read(12'h06C, v); $display("LEAN_NC last_mask=%h", v); if (v != 32'h007) failures = failures + 1;
        axi_read(12'h060, v); $display("LEAN_NC rx_last=%h", v); if (v != 32'h00070007) failures = failures + 1;
        // Illegal mask (4 groups): the framer faults and no frame is sent.
        axi_write(12'h048, 32'h00F);
        axi_write(12'h010, 32'd2); axi_write(12'h014, 32'd900); axi_write(12'h018, 32'd64); axi_write(12'h01C, 32'd0);
        axi_write(12'h00C, 1);
        repeat (60000) @(posedge clk);
        snapshot;
        axi_read(12'h068, v);
        $display("LEAN_NC illegal status=%h tx_status=%h crc_ok=%0d issued=%0d", st, v, crc_ok, issued);
        if (!v[11] || !st[8] || crc_ok != 6) failures = failures + 1;
        // Recovery: a legal mask and a new TX_GO.
        axi_write(12'h048, 32'h400);
        burst(16'd3, 32'd1000, 13'd512, 1'b0, 32'd9);
        axi_read(12'h06C, v); $display("LEAN_NC last_mask=%h", v); if (v != 32'h400) failures = failures + 1;
        // Coverage gap noted by independent: writing 0x048 during a burst only affects the next TX_GO.
        axi_write(12'h048, 32'h001);
        axi_write(12'h010, 32'd3); axi_write(12'h014, 32'd1100); axi_write(12'h018, 32'd512); axi_write(12'h01C, 32'd0);
        axi_write(12'h00C, 1);
        repeat (200) @(posedge clk);
        axi_write(12'h048, 32'h002);                // mid-burst write
        wait_cycles = 0; snapshot;
        while (crc_ok < 12 && wait_cycles < 60) begin repeat (5000) @(posedge clk); wait_cycles = wait_cycles + 1; snapshot; end
        axi_read(12'h06C, v); $display("LEAN_NC midburst last_mask=%h crc_ok=%0d hdr_fail=%0d", v, crc_ok, hdr_fail);
        if (v != 32'h001 || crc_ok != 12 || hdr_fail != 0) failures = failures + 1;
        axi_read(12'h068, v); if (v[10:0] != 11'h001) failures = failures + 1;
        axi_read(12'h048, v); if (v != 32'h002) failures = failures + 1;
        axi_write(12'h048, 32'h000);
        $display("LEAN_DONE failures=%0d", failures);
        if (failures == 0) $display("LEAN_PASS"); else $display("LEAN_FAIL");
        $finish;
    end
endmodule
