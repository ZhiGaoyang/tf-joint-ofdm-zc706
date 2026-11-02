// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2023.2 (win64) Build 4029153 Fri Oct 13 20:14:34 MDT 2023
// Date        : Fri Oct 16 15:39:36 2026
// Host        : JZTWMSJKXABIPVC running 64-bit major release  (build 9200)
// Command     : write_verilog -mode synth_stub
//               D:/FPGA_COMPETITION/build/ofdm_platform_assembly/20261016_01/core_ifft_export01/ifft_core_stub.v
// Design      : ifft128
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z045ffg900-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* x_core_info = "xfft_v9_1_10,Vivado 2023.2" *)
module ifft128(aclk, aresetn, s_axis_config_tdata, 
  s_axis_config_tvalid, s_axis_config_tready, s_axis_data_tdata, s_axis_data_tvalid, 
  s_axis_data_tready, s_axis_data_tlast, m_axis_data_tdata, m_axis_data_tuser, 
  m_axis_data_tvalid, m_axis_data_tready, m_axis_data_tlast, m_axis_status_tdata, 
  m_axis_status_tvalid, m_axis_status_tready, event_frame_started, 
  event_tlast_unexpected, event_tlast_missing, event_fft_overflow, 
  event_status_channel_halt, event_data_in_channel_halt, event_data_out_channel_halt)
/* synthesis syn_black_box black_box_pad_pin="aresetn,s_axis_config_tdata[15:0],s_axis_config_tvalid,s_axis_config_tready,s_axis_data_tdata[31:0],s_axis_data_tvalid,s_axis_data_tready,s_axis_data_tlast,m_axis_data_tdata[31:0],m_axis_data_tuser[15:0],m_axis_data_tvalid,m_axis_data_tready,m_axis_data_tlast,m_axis_status_tdata[7:0],m_axis_status_tvalid,m_axis_status_tready,event_frame_started,event_tlast_unexpected,event_tlast_missing,event_fft_overflow,event_status_channel_halt,event_data_in_channel_halt,event_data_out_channel_halt" */
/* synthesis syn_force_seq_prim="aclk" */;
  input aclk /* synthesis syn_isclock = 1 */;
  input aresetn;
  input [15:0]s_axis_config_tdata;
  input s_axis_config_tvalid;
  output s_axis_config_tready;
  input [31:0]s_axis_data_tdata;
  input s_axis_data_tvalid;
  output s_axis_data_tready;
  input s_axis_data_tlast;
  output [31:0]m_axis_data_tdata;
  output [15:0]m_axis_data_tuser;
  output m_axis_data_tvalid;
  input m_axis_data_tready;
  output m_axis_data_tlast;
  output [7:0]m_axis_status_tdata;
  output m_axis_status_tvalid;
  input m_axis_status_tready;
  output event_frame_started;
  output event_tlast_unexpected;
  output event_tlast_missing;
  output event_fft_overflow;
  output event_status_channel_halt;
  output event_data_in_channel_halt;
  output event_data_out_channel_halt;
endmodule
