`timescale 1ns/1ps
module ofdm_training_mux (
  input wire clk, input wire resetn,
  input wire frame_start_valid, output wire frame_start_ready,
  input wire [31:0] s_axis_tdata, input wire s_axis_tvalid,
  output wire s_axis_tready, input wire s_axis_tlast, input wire [1:0] s_axis_tuser,
  output wire [31:0] m_axis_tdata, output wire m_axis_tvalid,
  input wire m_axis_tready, output wire m_axis_tlast, output wire [1:0] m_axis_tuser,
  output reg fault
);
  localparam IDLE=2'd0,TRAIN0=2'd1,TRAIN1=2'd2,NORMAL=2'd3;
  // Sign bit one denotes -16384, in natural-bin order; PRBS7 recurrence a[n+7]=a[n+6]^a[n].
  localparam [127:0] TRAIN_SIGN=128'h6f634bb9957f000000002cea7d0e24da;
  reg [1:0] state;
  reg [6:0] bin_index;
  wire training=state==TRAIN0||state==TRAIN1;
  wire occupied=(bin_index>=1&&bin_index<=48)||bin_index>=80;
  wire [31:0] training_word=occupied ? (TRAIN_SIGN[bin_index]?32'h0000c000:32'h00004000) : 32'h0;
  assign frame_start_ready=resetn&&state==IDLE&&!fault;
  assign s_axis_tready=resetn&&state==NORMAL&&m_axis_tready;
  assign m_axis_tvalid=resetn&&(training||(state==NORMAL&&s_axis_tvalid));
  assign m_axis_tdata=training?training_word:s_axis_tdata;
  assign m_axis_tlast=training?(bin_index==127):s_axis_tlast;
  assign m_axis_tuser=training?{1'b0,(state==TRAIN0&&bin_index==0)}:s_axis_tuser;
  always @(posedge clk) begin
    if(!resetn) begin state<=IDLE;bin_index<=0;fault<=0;end
    else begin
      if(frame_start_valid&&frame_start_ready) begin state<=TRAIN0;bin_index<=0;end
      if(m_axis_tvalid&&m_axis_tready) begin
        if(training) begin
          if(bin_index==127) begin bin_index<=0;state<=state==TRAIN0?TRAIN1:NORMAL;end
          else bin_index<=bin_index+7'd1;
        end else begin
          // Advisory fault does not withdraw a held beat or block a committed frame drain.
          if(s_axis_tlast!=(bin_index==127)||s_axis_tuser[0]||(s_axis_tuser[1]&&bin_index!=127)) fault<=1;
          if(bin_index==127) begin
            bin_index<=0;
            if(s_axis_tuser[1]&&s_axis_tlast) state<=IDLE;
          end else bin_index<=bin_index+7'd1;
        end
      end
    end
  end
endmodule