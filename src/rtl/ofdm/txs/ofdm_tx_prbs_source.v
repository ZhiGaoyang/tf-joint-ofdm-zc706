`timescale 1ns/1ps
// Test-traffic source: issues frame descriptors and the per-frame PRBS payload
// (xorshift32 seeded with frame_id ^ 0xA5A5A5A5, first byte after one step),
// matching models/ofdm/v02.prbs_payload and the RX checker.  The descriptor
// fields are sampled per frame, so length/MCS/epoch changes take effect at
// the next frame boundary.
module ofdm_tx_prbs_source (
  input wire clk,
  input wire resetn,
  input wire start,               // pulse: begin a burst of cfg_frames frames
  input wire [15:0] cfg_frames,
  input wire [31:0] cfg_first_id,
  input wire [12:0] cfg_payload_len,
  input wire cfg_mcs,
  input wire [15:0] cfg_epoch,
  output reg busy,
  output reg [31:0] frames_issued,
  // framer command
  output reg cmd_valid,
  input wire cmd_ready,
  output reg [31:0] cmd_frame_id,
  output reg [12:0] cmd_payload_len,
  output reg [1:0] cmd_mcs,
  output reg [15:0] cmd_config_epoch,
  // payload bytes
  output wire [7:0] m_axis_tdata,
  output reg m_axis_tvalid,
  input wire m_axis_tready,
  output wire m_axis_tlast
);
  localparam [1:0] IDLE = 0, CMD = 1, BYTES = 2;
  reg [1:0] state;
  reg [15:0] frames_left;
  reg [31:0] next_id;
  reg [31:0] x;
  reg [12:0] left;
  function [31:0] xorshift;
    input [31:0] v;
    reg [31:0] t;
    begin
      t = v ^ (v << 13); t = t ^ (t >> 17); t = t ^ (t << 5);
      xorshift = t;
    end
  endfunction
  wire [31:0] x_next = xorshift(x);
  assign m_axis_tdata = x_next[7:0];
  assign m_axis_tlast = left == 13'd1;
  always @(posedge clk) begin
    if (!resetn) begin
      state <= IDLE; busy <= 0; cmd_valid <= 0; m_axis_tvalid <= 0;
      frames_left <= 0; frames_issued <= 0; next_id <= 0;
    end else begin
      case (state)
        IDLE: if (start && cfg_frames != 0) begin
          frames_left <= cfg_frames; next_id <= cfg_first_id; busy <= 1; state <= CMD;
        end
        CMD: if (!cmd_valid) begin
          cmd_valid <= 1; cmd_frame_id <= next_id; cmd_payload_len <= cfg_payload_len;
          cmd_mcs <= {1'b0, cfg_mcs}; cmd_config_epoch <= cfg_epoch;
          x <= (next_id ^ 32'hA5A5A5A5) == 0 ? 32'd1 : (next_id ^ 32'hA5A5A5A5);
          left <= cfg_payload_len;
        end else if (cmd_ready) begin
          cmd_valid <= 0; frames_issued <= frames_issued + 1'b1;
          next_id <= next_id + 1'b1; frames_left <= frames_left - 1'b1;
          if (left != 0) begin m_axis_tvalid <= 1; state <= BYTES; end
          else if (frames_left == 16'd1) begin busy <= 0; state <= IDLE; end
        end
        BYTES: if (m_axis_tready) begin
          x <= x_next;
          left <= left - 1'b1;
          if (left == 13'd1) begin
            m_axis_tvalid <= 0;
            if (frames_left == 0) begin busy <= 0; state <= IDLE; end
            else state <= CMD;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
