`timescale 1ns/1ps
// First-order DC blocker for the detector copy only: y = x - m, m += (x-m)/2^K.
// A residual DC would otherwise look like a perfectly periodic signal to the
// lag-160 metric and hold the plateau detector in one endless run.
module ofdm_rxs_dcblock #(parameter K = 10) (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_iq,
    input wire s_valid,
    output reg [31:0] m_iq,
    output reg m_valid
);
    reg signed [15+K+1:0] mean_i, mean_q;
    wire signed [15:0] xi = s_iq[15:0];
    wire signed [15:0] xq = s_iq[31:16];
    wire signed [16:0] ei = xi - (mean_i >>> K);
    wire signed [16:0] eq = xq - (mean_q >>> K);
    function [15:0] sat16;
        input signed [16:0] v;
        begin
            sat16 = v > 17'sd32767 ? 16'h7fff : (v < -17'sd32768 ? 16'h8000 : v[15:0]);
        end
    endfunction
    always @(posedge clk) begin
        if (!resetn) begin
            mean_i <= 0; mean_q <= 0; m_valid <= 0; m_iq <= 0;
        end else begin
            m_valid <= s_valid;
            if (s_valid) begin
                mean_i <= mean_i + ei;
                mean_q <= mean_q + eq;
                m_iq <= {sat16(eq), sat16(ei)};
            end
        end
    end
endmodule
