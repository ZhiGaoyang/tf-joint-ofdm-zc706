`timescale 1ns/1ps
// QPSK / 16QAM mapper, W16/F14 output (Q high, I low), unit average energy.
// QPSK uses label bits [3:2] = {b0, b1}: I = (1-2*b0)/sqrt2, Q = (1-2*b1)/sqrt2.
// 16QAM uses [3:0] = {b0..b3}: I level index 2*b0+b1, Q index 2*b2+b3 over
// levels {3, 1, -3, -1}/sqrt10, as in models/ofdm/core.py.
module ofdm_tx_mapper_v2 (
  input wire clk,
  input wire resetn,
  input wire [3:0] s_axis_tdata,
  input wire s_axis_tmode,
  input wire s_axis_tvalid,
  output wire s_axis_tready,
  input wire s_axis_tlast,
  input wire [1:0] s_axis_tuser,
  output reg [31:0] m_axis_tdata,
  output reg m_axis_tvalid,
  input wire m_axis_tready,
  output reg m_axis_tlast,
  output reg [1:0] m_axis_tuser
);
  localparam signed [15:0] Q1 = 16'sd11585;   // 16384/sqrt(2)
  localparam signed [15:0] A1 = 16'sd5181;    // 16384/sqrt(10)
  localparam signed [15:0] A3 = 16'sd15543;   // 3*16384/sqrt(10)
  function [15:0] level;
    input [1:0] index;
    begin
      case (index)
        2'd0: level = A3;
        2'd1: level = A1;
        2'd2: level = -A3;
        default: level = -A1;
      endcase
    end
  endfunction
  wire [15:0] mapped_i = s_axis_tmode ? level(s_axis_tdata[3:2]) : (s_axis_tdata[3] ? -Q1 : Q1);
  wire [15:0] mapped_q = s_axis_tmode ? level(s_axis_tdata[1:0]) : (s_axis_tdata[2] ? -Q1 : Q1);
  assign s_axis_tready = resetn && (!m_axis_tvalid || m_axis_tready);
  always @(posedge clk) begin
    if (!resetn) begin
      m_axis_tdata <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0; m_axis_tuser <= 0;
    end else if (s_axis_tready) begin
      m_axis_tvalid <= s_axis_tvalid;
      if (s_axis_tvalid) begin
        m_axis_tdata <= {mapped_q, mapped_i};
        m_axis_tlast <= s_axis_tlast;
        m_axis_tuser <= s_axis_tuser;
      end
    end
  end
endmodule
