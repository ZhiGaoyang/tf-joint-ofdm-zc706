`timescale 1ns/1ps
// V0.2 framer: copy of the accepted ofdm_qpsk_framer with payload whitening
// (x^7+x^4+1, all-ones seed per frame, body bits only) and 16QAM body labels.
// Labels: QPSK uses m_axis_tdata[3:2], 16QAM uses [3:0]; m_axis_tmode=1 marks
// a 4-bit label.  The header is always QPSK.
// NC extension (docs/innovation/b_subcarrier_mask_design.md section 3, 5.1):
// cfg_mask[10:0] removes whole 8-carrier groups; G = 11 - popcount active
// groups give 8G labels per symbol, 2G bytes per header symbol and 2G/4G
// bytes per QPSK/16QAM body symbol.  Header bytes 10..11 echo the mask.
// cfg_mask must be static while a frame is prepared (latched per command);
// more than three masked groups or more than 187 body symbols set fault.
// mask=0 is bit-identical to the accepted V0.2 framer.
module ofdm_tx_framer_v2 (
  input wire clk, input wire resetn,
  input wire [10:0] cfg_mask,
  input wire cmd_valid, output wire cmd_ready,
  input wire [31:0] cmd_frame_id, input wire [12:0] cmd_payload_len,
  input wire [1:0] cmd_mcs, input wire [15:0] cmd_config_epoch,
  input wire [7:0] s_axis_tdata, input wire s_axis_tvalid,
  output wire s_axis_tready, input wire s_axis_tlast,
  output wire frame_start_valid, input wire frame_start_ready,
  output wire [3:0] m_axis_tdata, output wire m_axis_tmode, output wire m_axis_tvalid,
  input wire m_axis_tready, output wire m_axis_tlast,
  output wire [1:0] m_axis_tuser, output reg fault
);
  localparam IDLE=3'd0, CAPTURE=3'd1, HEADER_CRC=3'd2,
             WAIT_START=3'd3, READ_BYTE=3'd4, EMIT_LABEL=3'd5;
  reg [2:0] state;
  reg [7:0] payload_mem [0:4095];
  reg [7:0] header [0:15];
  reg [31:0] frame_id, payload_crc_state, payload_crc, header_crc_state;
  reg [15:0] config_epoch;
  reg mcs;
  reg [6:0] lfsr;
  reg [12:0] payload_len, capture_index, byte_index, last_byte;
  reg [12:0] geometry_remainder, geometry_product;
  reg [13:0] geometry_divisor;
  reg [8:0] geometry_quotient;
  reg [10:0] mask;
  reg [1:0] extra;            // G - 8
  reg [4:0] header_bytes;     // 2G bytes per header symbol
  reg [5:0] body_bytes;       // 2G (QPSK) or 4G (16QAM) bytes per body symbol
  reg [6:0] label_last;       // 8G - 1
  reg [3:0] header_index;
  reg [7:0] current_byte;
  reg [1:0] pair_index;
  reg [6:0] label_index;
  `include "ofdm_nc_map.vh"
  wire [5:0] header_region = {header_bytes, 1'b0};   // 4G bytes: two header copies
  wire [12:0] body_index = byte_index - header_region;
  wire [4:0] header_byte_index = byte_index < header_bytes ? byte_index[4:0] : byte_index - header_bytes;
  wire [3:0] cmd_masked = nc_popcount11(cfg_mask);
  wire [3:0] cmd_groups = 4'd11 - cmd_masked;
  wire [5:0] cmd_body_bytes = cmd_mcs[0] ? {cmd_groups, 2'b00} : {1'b0, cmd_groups, 1'b0};
  function [31:0] crc_byte;
    input [31:0] crc;
    input [7:0] value;
    reg [31:0] work;
    integer bit_index;
    begin
      work=crc ^ {24'b0,value};
      for(bit_index=0;bit_index<8;bit_index=bit_index+1)
        if(work[0]) work=(work>>1)^32'hedb88320;
        else work=work>>1;
      crc_byte=work;
    end
  endfunction
  function [7:0] header_prefix;
    input [3:0] index;
    input [31:0] id;
    input [12:0] length;
    input [15:0] epoch;
    input mode;
    input [10:0] nc_mask;
    begin
      case(index)
        0: header_prefix=8'h01;
        1: header_prefix={7'b0,mode};
        2: header_prefix=id[7:0]; 3: header_prefix=id[15:8];
        4: header_prefix=id[23:16]; 5: header_prefix=id[31:24];
        6: header_prefix=length[7:0]; 7: header_prefix={3'b0,length[12:8]};
        8: header_prefix=epoch[7:0]; 9: header_prefix=epoch[15:8];
        10: header_prefix=nc_mask[7:0]; 11: header_prefix={5'b0,nc_mask[10:8]};
        default: header_prefix=0;
      endcase
    end
  endfunction
  wire [7:0] prefix_byte=header_prefix(header_index,frame_id,payload_len,config_epoch,mcs,mask);
  wire [31:0] next_header_crc=crc_byte(header_crc_state,prefix_byte);
  wire [31:0] finished_header_crc=next_header_crc^32'hffffffff;
  assign cmd_ready=resetn && !fault && state==IDLE;
  assign s_axis_tready=resetn && !fault && state==CAPTURE;
  assign frame_start_valid=resetn && state==WAIT_START;
  assign m_axis_tvalid=resetn && state==EMIT_LABEL;
  wire in_body = byte_index >= header_region;
  wire quad = in_body && mcs;
  // Whitening bits for this label (first bit first), and the advanced state.
  wire w0 = lfsr[6]^lfsr[3], w1 = lfsr[5]^lfsr[2], w2 = lfsr[4]^lfsr[1], w3 = lfsr[3]^lfsr[0];
  wire [3:0] white = !in_body ? 4'd0 : (quad ? {w0,w1,w2,w3} : {w0,w1,2'b00});
  wire [6:0] lfsr_next = quad ? {lfsr[2:0],w0,w1,w2,w3} : {lfsr[4:0],w0,w1};
  wire [3:0] raw_label = quad ? (pair_index[0] ? current_byte[3:0] : current_byte[7:4]) :
                         {pair_index==0 ? current_byte[7:6] :
                          pair_index==1 ? current_byte[5:4] :
                          pair_index==2 ? current_byte[3:2] : current_byte[1:0], 2'b00};
  wire last_label = quad ? pair_index==1 : pair_index==3;
  assign m_axis_tdata=raw_label ^ white;
  assign m_axis_tmode=quad;
  assign m_axis_tlast=label_index==label_last;
  assign m_axis_tuser={(byte_index==last_byte && last_label),1'b0};
  always @(posedge clk) begin
    if(!resetn) begin
      state<=IDLE;fault<=0;frame_id<=0;config_epoch<=0;payload_len<=0;
      capture_index<=0;payload_crc_state<=32'hffffffff;payload_crc<=0;
      header_crc_state<=32'hffffffff;header_index<=0;byte_index<=0;last_byte<=0;
      current_byte<=0;pair_index<=0;label_index<=0;mcs<=0;lfsr<=7'h7f;
      geometry_remainder<=0;geometry_divisor<=0;geometry_product<=0;geometry_quotient<=0;
      mask<=0;extra<=2'd3;header_bytes<=5'd22;body_bytes<=6'd22;label_last<=7'd87;
    end else begin
      case(state)
        IDLE: if(cmd_valid&&cmd_ready) begin
          frame_id<=cmd_frame_id;payload_len<=cmd_payload_len;config_epoch<=cmd_config_epoch;
          mcs<=cmd_mcs[0];lfsr<=7'h7f;
          capture_index<=0;payload_crc_state<=32'hffffffff;payload_crc<=0;
          header_crc_state<=32'hffffffff;header_index<=0;
          byte_index<=0;pair_index<=0;label_index<=0;
          mask<=cfg_mask;extra<=cmd_groups[1:0];header_bytes<={cmd_groups,1'b0};
          body_bytes<=cmd_body_bytes;label_last<={cmd_groups,3'b000}-7'd1;
          // ceil((L+4)/body_bytes): R0 = L+4+body_bytes-1, nine restoring steps.
          geometry_remainder<=cmd_payload_len+13'd3+{7'b0,cmd_body_bytes};
          geometry_divisor<={cmd_body_bytes,8'b0};geometry_quotient<=0;
          if(cmd_payload_len>13'd4096 || cmd_mcs>2'd1 || cmd_masked>4'd3) fault<=1;
          else if(cmd_payload_len==0) state<=HEADER_CRC;
          else state<=CAPTURE;
        end
        CAPTURE: if(s_axis_tvalid&&s_axis_tready) begin
          if(s_axis_tlast!=(capture_index==payload_len-13'd1)) fault<=1;
          else begin
            payload_mem[capture_index[11:0]]<=s_axis_tdata;
            payload_crc_state<=crc_byte(payload_crc_state,s_axis_tdata);
            if(capture_index==payload_len-13'd1) begin
              payload_crc<=crc_byte(payload_crc_state,s_axis_tdata)^32'hffffffff;
              state<=HEADER_CRC;
            end else capture_index<=capture_index+13'd1;
          end
        end
        HEADER_CRC: begin
          // Nine restoring steps inside the existing 12-cycle CRC preparation;
          // then body_bytes*Q = 2G*Q (x2 for 16QAM) by shift-add, G = 8 + extra.
          // No new frame preparation cycles.  Q > 187 exceeds the RX fetch limit.
          if(header_index<9) begin
            geometry_divisor<=geometry_divisor>>1;
            geometry_quotient<={geometry_quotient[7:0],{1'b0,geometry_remainder}>=geometry_divisor};
            if({1'b0,geometry_remainder}>=geometry_divisor)
              geometry_remainder<=geometry_remainder-geometry_divisor[12:0];
          end else if(header_index==9) begin
            geometry_product<=({4'b0,geometry_quotient}<<4)+(extra[0] ? {4'b0,geometry_quotient}<<1 : 13'd0);
            if(geometry_quotient>9'd187) begin fault<=1;state<=IDLE;end
          end else if(header_index==10)
            geometry_product<=geometry_product+(extra[1] ? {4'b0,geometry_quotient}<<2 : 13'd0);
          else if(header_index==11)
            last_byte<=(mcs ? geometry_product<<1 : geometry_product)+header_region-13'd1;
          header[header_index]<=prefix_byte;
          header_crc_state<=next_header_crc;
          if(header_index==11) begin
            header[12]<=finished_header_crc[7:0];header[13]<=finished_header_crc[15:8];
            header[14]<=finished_header_crc[23:16];header[15]<=finished_header_crc[31:24];
            state<=WAIT_START;
          end else header_index<=header_index+4'd1;
        end
        WAIT_START: if(frame_start_valid&&frame_start_ready) state<=READ_BYTE;
        READ_BYTE: begin
          // Registered memory read: the byte remains owned through four label handshakes.
          if(byte_index<header_region) begin
            if(header_byte_index<16) current_byte<=header[header_byte_index];
            else current_byte<=0;
          end else if(body_index<payload_len) current_byte<=payload_mem[body_index[11:0]];
          else if(body_index<payload_len+13'd4) begin
            case(body_index-payload_len)
              0: current_byte<=payload_crc[7:0];1: current_byte<=payload_crc[15:8];
              2: current_byte<=payload_crc[23:16];default: current_byte<=payload_crc[31:24];
            endcase
          end else current_byte<=0;
          state<=EMIT_LABEL;
        end
        EMIT_LABEL: if(m_axis_tvalid&&m_axis_tready) begin
          if(label_index==label_last) label_index<=0;else label_index<=label_index+7'd1;
          if(in_body) lfsr<=lfsr_next;
          if(last_label) begin
            pair_index<=0;
            if(byte_index==last_byte) state<=IDLE;
            else begin byte_index<=byte_index+13'd1;state<=READ_BYTE;end
          end else pair_index<=pair_index+2'd1;
        end
        default: state<=IDLE;
      endcase
    end
  end
endmodule
