`timescale 1ns/1ps
// V0.2 frame: ofdm_tx_frame with the V0.2 grid.
// NC: cfg_mask (static per burst) is passed to the grid.
module ofdm_tx_frame_v2 (
  input wire clk,input wire resetn,input wire [10:0] cfg_mask,
  input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_frame_id,
  input wire [12:0] cmd_payload_len,input wire [1:0] cmd_mcs,input wire [15:0] cmd_config_epoch,
  input wire [7:0] s_axis_tdata,input wire s_axis_tvalid,output wire s_axis_tready,input wire s_axis_tlast,
  output wire [31:0] m_axis_tdata,output wire m_axis_tvalid,input wire m_axis_tready,
  output wire m_axis_tlast,output wire [1:0] m_axis_tuser,output wire fault
);
  wire [31:0] g_data,i_data;
  wire [1:0] g_user,i_user;
  wire g_valid,g_ready,g_last,i_valid,i_ready,i_last;
  wire grid_fault,ifft_fault,cp_fault;
  assign fault=grid_fault||ifft_fault||cp_fault;
  ofdm_frame_grid_v2 grid(.clk(clk),.resetn(resetn),.cfg_mask(cfg_mask),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
    .cmd_frame_id(cmd_frame_id),.cmd_payload_len(cmd_payload_len),.cmd_mcs(cmd_mcs),.cmd_config_epoch(cmd_config_epoch),
    .s_axis_tdata(s_axis_tdata),.s_axis_tvalid(s_axis_tvalid),.s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(g_data),.m_axis_tvalid(g_valid),.m_axis_tready(g_ready),.m_axis_tlast(g_last),.m_axis_tuser(g_user),.fault(grid_fault));
  ofdm_ifft_stream ifft_stage(.clk(clk),.resetn(resetn),.s_axis_tdata(g_data),.s_axis_tvalid(g_valid),.s_axis_tready(g_ready),.s_axis_tlast(g_last),.s_axis_tuser(g_user),
    .m_axis_tdata(i_data),.m_axis_tvalid(i_valid),.m_axis_tready(i_ready),.m_axis_tlast(i_last),.m_axis_tuser(i_user),.fault(ifft_fault));
  ofdm_cp_insert cp(.clk(clk),.resetn(resetn),.s_axis_tdata(i_data),.s_axis_tvalid(i_valid),.s_axis_tready(i_ready),.s_axis_tlast(i_last),.s_axis_tuser(i_user),
    .m_axis_tdata(m_axis_tdata),.m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),.m_axis_tlast(m_axis_tlast),.m_axis_tuser(m_axis_tuser),.fault(cp_fault));
endmodule
