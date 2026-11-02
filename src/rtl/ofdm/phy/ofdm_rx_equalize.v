`timescale 1ns/1ps
module ofdm_rx_equalize (
    input wire clk,resetn,input wire [31:0] s_axis_tdata,input wire [47:0] s_axis_tcoeff,
    input wire [7:0] s_axis_tindex,input wire [15:0] s_axis_tepoch,
    input wire s_axis_tlast,s_axis_tusable,s_axis_tvalid,output wire s_axis_tready,
    output wire [31:0] m_axis_tdata,output wire [7:0] m_axis_tindex,
    output wire [15:0] m_axis_tepoch,output wire m_axis_tlast,m_axis_tusable,m_axis_tinvalid,
    output wire [1:0] m_axis_tclips,m_axis_terror,
    output wire m_axis_tvalid,input wire m_axis_tready,output reg fault
);
    reg [4:0] valid,usable,active,last;
    reg [7:0] index[0:4];reg [15:0] epoch[0:4];reg [1:0] errors[0:4];
    reg signed [15:0] operand_i,operand_q;reg signed [23:0] gain_i,gain_q;
    reg signed [39:0] product_ii,product_qq,product_iq,product_qi;
    reg signed [40:0] sum_i,sum_q,rounded_i,rounded_q;
    reg [31:0] output_data;reg [1:0] output_clips;reg output_usable,output_invalid;
    wire advance=resetn&&(!valid[4]||m_axis_tready);
    wire input_active=((s_axis_tindex>=1&&s_axis_tindex<=48)||(s_axis_tindex>=80&&s_axis_tindex<=127));
    wire [1:0] input_error={(s_axis_tlast!=(s_axis_tindex==127)),s_axis_tindex[7]};
    wire clip_i=rounded_i>41'sd32767||rounded_i< -41'sd32768;
    wire clip_q=rounded_q>41'sd32767||rounded_q< -41'sd32768;
    integer k;
    function signed [40:0] rne18;
        input signed [40:0] value;reg [40:0] magnitude,quotient;
        begin
            magnitude=value[40]?(~value+41'd1):value;
            quotient=magnitude>>18;
            if(magnitude[17:0]>18'd131072||(magnitude[17:0]==18'd131072&&quotient[0]))quotient=quotient+1'b1;
            rne18=value[40]?-$signed(quotient):$signed(quotient);
        end
    endfunction
    function [15:0] clamp;
        input signed [40:0] value;
        begin
            if(value>41'sd32767)clamp=16'h7fff;
            else if(value< -41'sd32768)clamp=16'h8000;
            else clamp=value[15:0];
        end
    endfunction
    assign s_axis_tready=advance;assign m_axis_tvalid=resetn&&valid[4];
    assign m_axis_tdata=output_data;assign m_axis_tindex=index[4];assign m_axis_tepoch=epoch[4];
    assign m_axis_tlast=last[4];assign m_axis_tusable=output_usable;assign m_axis_tinvalid=output_invalid;
    assign m_axis_tclips=output_clips;assign m_axis_terror=errors[4];
    always @(posedge clk)begin
        if(!resetn)begin valid<=0;fault<=0;end
        else if(advance)begin
            valid[0]<=s_axis_tvalid;active[0]<=input_active;
            usable[0]<=input_active&&s_axis_tusable&&input_error==0;
            index[0]<=s_axis_tindex;epoch[0]<=s_axis_tepoch;last[0]<=s_axis_tlast;errors[0]<=input_error;
            for(k=1;k<5;k=k+1)begin
                valid[k]<=valid[k-1];active[k]<=active[k-1];usable[k]<=usable[k-1];
                index[k]<=index[k-1];epoch[k]<=epoch[k-1];last[k]<=last[k-1];errors[k]<=errors[k-1];
            end
            operand_i<=s_axis_tdata[15:0];operand_q<=s_axis_tdata[31:16];
            gain_i<=s_axis_tcoeff[23:0];gain_q<=s_axis_tcoeff[47:24];
            product_ii<=operand_i*gain_i;product_qq<=operand_q*gain_q;
            product_iq<=operand_i*gain_q;product_qi<=operand_q*gain_i;
            sum_i<=$signed({product_ii[39],product_ii})-$signed({product_qq[39],product_qq});
            sum_q<=$signed({product_iq[39],product_iq})+$signed({product_qi[39],product_qi});
            rounded_i<=rne18(sum_i);rounded_q<=rne18(sum_q);
            output_data<=usable[3]?{clamp(rounded_q),clamp(rounded_i)}:32'd0;
            output_clips<=usable[3]?({1'b0,clip_i}+{1'b0,clip_q}):2'd0;
            output_usable<=usable[3]&&!clip_i&&!clip_q;
            output_invalid<=errors[3]!=0||(active[3]&&!usable[3]);
            if(s_axis_tvalid&&input_error!=0)fault<=1;
        end
    end
endmodule
