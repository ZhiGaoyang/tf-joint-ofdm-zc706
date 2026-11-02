`timescale 1ns/1ps
// NC extension (design B section 5.1): cfg_mask[10:0] removes 8-carrier groups.
// Each symbol takes 8G inputs (G unmasked groups) in signed data order skipping
// masked groups; masked data bins are emitted as zero.  cfg_mask must be static
// while the loader is out of reset.  mask=0 behaves as the accepted loader.
module ofdm_carrier_loader (
  input wire clk,
  input wire resetn,
  input wire [10:0] cfg_mask,
  input wire [31:0] s_axis_tdata,
  input wire s_axis_tvalid,
  output wire s_axis_tready,
  input wire s_axis_tlast,
  input wire [1:0] s_axis_tuser,
  output reg [31:0] m_axis_tdata,
  output reg m_axis_tvalid,
  input wire m_axis_tready,
  output reg m_axis_tlast,
  output reg [1:0] m_axis_tuser,
  output reg fault
);
  reg [31:0] bank0 [0:127];
  reg [31:0] bank1 [0:127];
  reg [1:0] bank_full;
  reg [1:0] bank_sof, bank_eof;
  reg write_bank, read_bank;
  reg [6:0] input_index, read_index;
  reg pending_sof;
  `include "ofdm_nc_map.vh"
  // Static configuration, registered once more for timing.
  reg [10:0] mask;
  reg [6:0] input_last;                 // 8G - 1
  reg [3:0] first_group, next_group;
  reg [6:0] first_address;
  reg [127:0] bin_masked;
  // Write position: group wg, member wj; write_address = ord2bin({wg,wj}).
  reg [3:0] wg;
  reg [2:0] wj;
  reg [6:0] write_address;
  wire [3:0] step_group = wj == 3'd7 ? next_group : wg;
  wire [2:0] step_member = wj + 3'd1;
  wire [15:0] mask_wide = {5'b0, cfg_mask};
  wire [127:0] bin_masked_next;
  genvar gb;
  generate
    for (gb = 0; gb < 128; gb = gb + 1) begin : g_bin_masked
      assign bin_masked_next[gb] = mask_wide[nc_bin2group(gb)];
    end
  endgenerate
  wire malformed = (s_axis_tlast != (input_index == input_last)) ||
                   (s_axis_tuser[0] && input_index != 0) ||
                   (s_axis_tuser[1] && input_index != input_last);

  function is_data_bin;
    input [6:0] bin;
    begin
      is_data_bin = ((bin >= 7'd1 && bin <= 7'd48) || bin >= 7'd80) &&
                    bin != 7'd7 && bin != 7'd19 && bin != 7'd31 && bin != 7'd43 &&
                    bin != 7'd85 && bin != 7'd97 && bin != 7'd109 && bin != 7'd121;
    end
  endfunction

  function [31:0] fixed_bin;
    input [6:0] bin;
    begin
      case (bin)
        7'd85, 7'd97, 7'd109, 7'd19, 7'd43: fixed_bin = 32'h00004000;
        7'd121, 7'd7, 7'd31: fixed_bin = 32'h0000c000;
        default: fixed_bin = 32'h00000000;
      endcase
    end
  endfunction

  assign s_axis_tready = resetn && !fault && !bank_full[write_bank];

  always @(posedge clk) begin
    if (!resetn) begin
      bank_full <= 0;
      bank_sof <= 0;
      bank_eof <= 0;
      write_bank <= 0;
      read_bank <= 0;
      input_index <= 0;
      read_index <= 0;
      pending_sof <= 0;
      mask <= cfg_mask;
      input_last <= {4'd11 - nc_popcount11(cfg_mask), 3'b000} - 7'd1;
      first_group <= nc_first_unmasked(cfg_mask);
      first_address <= nc_ord2bin({nc_first_unmasked(cfg_mask), 3'b000});
      wg <= nc_first_unmasked(cfg_mask);
      wj <= 0;
      write_address <= nc_ord2bin({nc_first_unmasked(cfg_mask), 3'b000});
      next_group <= nc_next_unmasked(cfg_mask, nc_first_unmasked(cfg_mask));
      bin_masked <= bin_masked_next;
      m_axis_tdata <= 0;
      m_axis_tvalid <= 0;
      m_axis_tlast <= 0;
      m_axis_tuser <= 0;
      fault <= 0;
    end else begin
      next_group <= nc_next_unmasked(mask, wg);
      if (s_axis_tvalid && s_axis_tready) begin
        if (malformed) begin
          fault <= 1;
        end else begin
          if (write_bank) bank1[write_address] <= s_axis_tdata;
          else bank0[write_address] <= s_axis_tdata;
          if (input_index == 0) pending_sof <= s_axis_tuser[0];
          if (input_index == input_last) begin
            bank_full[write_bank] <= 1;
            bank_sof[write_bank] <= pending_sof;
            bank_eof[write_bank] <= s_axis_tuser[1];
            write_bank <= !write_bank;
            input_index <= 0;
            wg <= first_group;
            wj <= 0;
            write_address <= first_address;
          end else begin
            input_index <= input_index + 7'd1;
            wg <= step_group;
            wj <= step_member;
            write_address <= nc_ord2bin({step_group, step_member});
          end
        end
      end

      // The final bin lives in this register before its bank is released.
      // A fault stops collection, not already committed output ownership.
      if (!m_axis_tvalid || m_axis_tready) begin
        m_axis_tvalid <= bank_full[read_bank];
        if (bank_full[read_bank]) begin
          if (is_data_bin(read_index) && !bin_masked[read_index]) begin
            if (read_bank) m_axis_tdata <= bank1[read_index];
            else m_axis_tdata <= bank0[read_index];
          end else m_axis_tdata <= fixed_bin(read_index);
          m_axis_tlast <= read_index == 7'd127;
          m_axis_tuser <= {(read_index == 7'd127 && bank_eof[read_bank]),
                           (read_index == 0 && bank_sof[read_bank])};
          if (read_index == 7'd127) begin
            bank_full[read_bank] <= 0;
            read_bank <= !read_bank;
            read_index <= 0;
          end else read_index <= read_index + 7'd1;
        end
      end
    end
  end
endmodule
