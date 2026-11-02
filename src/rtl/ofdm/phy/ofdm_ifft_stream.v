`timescale 1ns/1ps
module ofdm_ifft_stream (
  input wire clk,
  input wire resetn,
  input wire [31:0] s_axis_tdata,
  input wire s_axis_tvalid,
  output wire s_axis_tready,
  input wire s_axis_tlast,
  input wire [1:0] s_axis_tuser,
  output wire [31:0] m_axis_tdata,
  output wire m_axis_tvalid,
  input wire m_axis_tready,
  output wire m_axis_tlast,
  output wire [1:0] m_axis_tuser,
  output reg fault
);
  reg configured;
  reg [6:0] input_index, output_index;
  reg pending_sof;
  reg [1:0] metadata [0:7];
  reg [2:0] meta_write, meta_read;
  reg [3:0] meta_count;
  wire config_valid = resetn && !configured;
  wire config_ready;
  // Capacity is reserved at bin zero; an already started symbol may finish.
  wire input_permitted = configured && (input_index != 0 || meta_count < 4'd8);
  wire core_input_valid = resetn && input_permitted && s_axis_tvalid;
  wire core_input_ready;
  wire [31:0] core_data;
  wire [15:0] core_user;
  wire core_valid, core_last;
  wire core_ready = resetn && meta_count != 0 && m_axis_tready;
  wire [7:0] status_data;
  wire status_valid;
  wire event_frame_started, event_unexpected, event_missing, event_overflow;
  wire event_status_halt, event_input_halt, event_output_halt;
  wire input_fire = s_axis_tvalid && s_axis_tready;
  wire output_fire = core_valid && core_ready;
  wire meta_push = input_fire && input_index == 7'd127;
  wire meta_pop = output_fire && output_index == 7'd127;
  wire malformed_input = (s_axis_tlast != (input_index == 7'd127)) ||
                         (s_axis_tuser[0] && input_index != 0) ||
                         (s_axis_tuser[1] && input_index != 7'd127);
  assign s_axis_tready = resetn && input_permitted && core_input_ready;
  assign m_axis_tdata = core_data;
  assign m_axis_tvalid = resetn && core_valid && meta_count != 0;
  assign m_axis_tlast = core_last;
  assign m_axis_tuser = {(output_index == 7'd127 && metadata[meta_read][1]),
                         (output_index == 0 && metadata[meta_read][0])};

  ifft128 core (
    .aclk(clk), .aresetn(resetn),
    .s_axis_config_tdata(16'h00d4), .s_axis_config_tvalid(config_valid),
    .s_axis_config_tready(config_ready),
    .s_axis_data_tdata(s_axis_tdata), .s_axis_data_tvalid(core_input_valid),
    .s_axis_data_tready(core_input_ready), .s_axis_data_tlast(s_axis_tlast),
    .m_axis_data_tdata(core_data), .m_axis_data_tuser(core_user),
    .m_axis_data_tvalid(core_valid), .m_axis_data_tready(core_ready), .m_axis_data_tlast(core_last),
    .m_axis_status_tdata(status_data), .m_axis_status_tvalid(status_valid), .m_axis_status_tready(1'b1),
    .event_frame_started(event_frame_started), .event_tlast_unexpected(event_unexpected),
    .event_tlast_missing(event_missing), .event_fft_overflow(event_overflow),
    .event_status_channel_halt(event_status_halt), .event_data_in_channel_halt(event_input_halt),
    .event_data_out_channel_halt(event_output_halt)
  );
  always @(posedge clk) begin
    if (!resetn) begin
      configured <= 0;
      input_index <= 0;
      output_index <= 0;
      pending_sof <= 0;
      meta_write <= 0;
      meta_read <= 0;
      meta_count <= 0;
      fault <= 0;
    end else begin
      if (config_valid && config_ready) configured <= 1;
      if (input_fire) begin
        if (malformed_input) fault <= 1;
        if (input_index == 0) pending_sof <= s_axis_tuser[0];
        if (input_index == 7'd127) begin
          metadata[meta_write] <= {s_axis_tuser[1], pending_sof};
          meta_write <= meta_write + 3'd1;
          input_index <= 0;
        end else input_index <= input_index + 7'd1;
      end
      if (output_fire) begin
        if (core_user[6:0] != output_index || core_user[15:7] != 0 ||
            core_last != (output_index == 7'd127)) fault <= 1;
        if (output_index == 7'd127) begin
          output_index <= 0;
          meta_read <= meta_read + 3'd1;
        end else output_index <= output_index + 7'd1;
      end
      case ({meta_push, meta_pop})
        2'b10: meta_count <= meta_count + 4'd1;
        2'b01: meta_count <= meta_count - 4'd1;
        default: meta_count <= meta_count;
      endcase
      // Fault is advisory, never a combinational veto of a held AXI beat.
      // Legal nonrealtime input/output halt events are deliberately not faults.
      if (event_unexpected || event_missing || event_overflow ||
          (status_valid && status_data != 0) || (core_valid && meta_count == 0)) fault <= 1;
    end
  end
endmodule
