`timescale 1ns/1ps
// V0.2 grid: ofdm_frame_grid with the V0.2 framer and QPSK/16QAM mapper.
// NC: cfg_mask (static per burst) goes to the framer and carrier loader.
module ofdm_frame_grid_v2 (
  input wire clk,input wire resetn,input wire [10:0] cfg_mask,
  input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_frame_id,
  input wire [12:0] cmd_payload_len,input wire [1:0] cmd_mcs,input wire [15:0] cmd_config_epoch,
  input wire [7:0] s_axis_tdata,input wire s_axis_tvalid,output wire s_axis_tready,input wire s_axis_tlast,
  output wire [31:0] m_axis_tdata,output wire m_axis_tvalid,input wire m_axis_tready,
  output wire m_axis_tlast,output wire [1:0] m_axis_tuser,output wire fault
);
  wire [3:0] l_data;
  wire [1:0] l_user;
  wire l_mode;
  wire l_valid,l_ready,l_last,start_valid,start_ready;
  wire [31:0] q_data,c_data;
  wire [1:0] q_user,c_user;
  wire q_valid,q_ready,q_last,c_valid,c_ready,c_last;
  wire framer_fault,carrier_fault,training_fault;
  assign fault=framer_fault||carrier_fault||training_fault;
  ofdm_tx_framer_v2 framer(.clk(clk),.resetn(resetn),.cfg_mask(cfg_mask),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
    .cmd_frame_id(cmd_frame_id),.cmd_payload_len(cmd_payload_len),.cmd_mcs(cmd_mcs),.cmd_config_epoch(cmd_config_epoch),
    .s_axis_tdata(s_axis_tdata),.s_axis_tvalid(s_axis_tvalid),.s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast),
    .frame_start_valid(start_valid),.frame_start_ready(start_ready),
    .m_axis_tdata(l_data),.m_axis_tmode(l_mode),.m_axis_tvalid(l_valid),.m_axis_tready(l_ready),.m_axis_tlast(l_last),.m_axis_tuser(l_user),.fault(framer_fault));
  ofdm_tx_mapper_v2 mapper(.clk(clk),.resetn(resetn),.s_axis_tdata(l_data),.s_axis_tmode(l_mode),.s_axis_tvalid(l_valid),.s_axis_tready(l_ready),.s_axis_tlast(l_last),.s_axis_tuser(l_user),
    .m_axis_tdata(q_data),.m_axis_tvalid(q_valid),.m_axis_tready(q_ready),.m_axis_tlast(q_last),.m_axis_tuser(q_user));
  ofdm_carrier_loader carrier(.clk(clk),.resetn(resetn),.cfg_mask(cfg_mask),.s_axis_tdata(q_data),.s_axis_tvalid(q_valid),.s_axis_tready(q_ready),.s_axis_tlast(q_last),.s_axis_tuser(q_user),
    .m_axis_tdata(c_data),.m_axis_tvalid(c_valid),.m_axis_tready(c_ready),.m_axis_tlast(c_last),.m_axis_tuser(c_user),.fault(carrier_fault));
  ofdm_training_mux training(.clk(clk),.resetn(resetn),.frame_start_valid(start_valid),.frame_start_ready(start_ready),
    .s_axis_tdata(c_data),.s_axis_tvalid(c_valid),.s_axis_tready(c_ready),.s_axis_tlast(c_last),.s_axis_tuser(c_user),
    .m_axis_tdata(m_axis_tdata),.m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),.m_axis_tlast(m_axis_tlast),.m_axis_tuser(m_axis_tuser),.fault(training_fault));
endmodule
