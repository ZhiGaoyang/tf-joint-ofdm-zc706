`timescale 1ns/1ps
// Raw-sample ring: one write per valid input sample, random read by absolute
// index.  Read data is registered twice (BRAM output register), latency 2.
module ofdm_rxs_ring #(parameter AW = 11) (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_iq,
    input wire s_valid,
    output reg [31:0] wr_index,           // index of the next sample to be written
    input wire rd_en,
    input wire [31:0] rd_index,
    output reg [31:0] rd_data
);
    (* ram_style = "block" *) reg [31:0] mem [0:(1<<AW)-1];
    reg [31:0] rd_reg;
    always @(posedge clk) begin
        if (s_valid) mem[wr_index[AW-1:0]] <= s_iq;
        if (rd_en) rd_reg <= mem[rd_index[AW-1:0]];
        rd_data <= rd_reg;
    end
    always @(posedge clk) begin
        if (!resetn) wr_index <= 0;
        else if (s_valid) wr_index <= wr_index + 1'b1;
    end
endmodule
