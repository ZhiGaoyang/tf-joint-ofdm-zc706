`timescale 1ns/1ps
module ofdm_cp_insert (
  input wire clk,
  input wire resetn,
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
  reg [1:0] bank_full, bank_sof, bank_eof;
  reg write_bank, read_bank, pending_sof;
  reg [6:0] input_index;
  reg [7:0] output_index;
  wire [6:0] read_address = output_index < 8'd32 ?
                            output_index[6:0] + 7'd96 : output_index[6:0] - 7'd32;
  wire malformed = (s_axis_tlast != (input_index == 7'd127)) ||
                   (s_axis_tuser[0] && input_index != 0) ||
                   (s_axis_tuser[1] && input_index != 7'd127);
  assign s_axis_tready = resetn && !fault && !bank_full[write_bank];

  always @(posedge clk) begin
    if (!resetn) begin
      bank_full <= 0;
      bank_sof <= 0;
      bank_eof <= 0;
      write_bank <= 0;
      read_bank <= 0;
      pending_sof <= 0;
      input_index <= 0;
      output_index <= 0;
      m_axis_tdata <= 0;
      m_axis_tvalid <= 0;
      m_axis_tlast <= 0;
      m_axis_tuser <= 0;
      fault <= 0;
    end else begin
      if (s_axis_tvalid && s_axis_tready) begin
        if (malformed) fault <= 1;
        else begin
          if (write_bank) bank1[input_index] <= s_axis_tdata;
          else bank0[input_index] <= s_axis_tdata;
          if (input_index == 0) pending_sof <= s_axis_tuser[0];
          if (input_index == 7'd127) begin
            bank_full[write_bank] <= 1;
            bank_sof[write_bank] <= pending_sof;
            bank_eof[write_bank] <= s_axis_tuser[1];
            write_bank <= !write_bank;
            input_index <= 0;
          end else input_index <= input_index + 7'd1;
        end
      end
      // The bank is reusable once its final word is in the held output register.
      // A collection fault does not revoke already committed output ownership.
      if (!m_axis_tvalid || m_axis_tready) begin
        m_axis_tvalid <= bank_full[read_bank];
        if (bank_full[read_bank]) begin
          if (read_bank) m_axis_tdata <= bank1[read_address];
          else m_axis_tdata <= bank0[read_address];
          m_axis_tlast <= output_index == 8'd159;
          m_axis_tuser <= {(output_index == 8'd159 && bank_eof[read_bank]),
                           (output_index == 0 && bank_sof[read_bank])};
          if (output_index == 8'd159) begin
            bank_full[read_bank] <= 0;
            read_bank <= !read_bank;
            output_index <= 0;
          end else output_index <= output_index + 8'd1;
        end
      end
    end
  end
endmodule
