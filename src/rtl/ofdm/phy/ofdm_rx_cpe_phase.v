`timescale 1ns/1ps
module ofdm_rx_cpe_phase (
    input wire clk,input wire resetn,
    input wire s_valid,output wire s_ready,
    input wire signed [19:0] s_corr_i,input wire signed [19:0] s_corr_q,
    input wire [63:0] s_sample_index,
    output reg m_valid,input wire m_ready,
    output reg [63:0] m_sample_index,
    output reg signed [31:0] m_phase_word,
    output reg m_defined,output reg m_boundary_ambiguous
);
    `include "ofdm_cfo_atan.vh"
    localparam [2:0] IDLE=0,MAXIMUM=1,LEADING=2,NORMALIZE=3,ITERATE=4,RESULT=5;
    reg [2:0] state;
    reg [4:0] iteration;
    reg signed [20:0] quadrant_x,quadrant_y;
    reg [19:0] magnitude_x,magnitude_y,largest;
    reg [5:0] shift;
    reg signed [42:0] x,y;
    reg signed [33:0] z;
    wire signed [20:0] input_x={s_corr_i[19],s_corr_i};
    wire signed [20:0] input_y={s_corr_q[19],s_corr_q};
    wire signed [42:0] extended_x={{22{quadrant_x[20]}},quadrant_x};
    wire signed [42:0] extended_y={{22{quadrant_y[20]}},quadrant_y};
    function [5:0] normalize_shift;
        input [19:0] value;
        integer k,highest;
        begin
            highest=0;
            for(k=0;k<20;k=k+1)if(value[k])highest=k;
            normalize_shift=39-highest;
        end
    endfunction
    function boundary;
        input [31:0] phase;reg [32:0] magnitude;
        begin
            magnitude=phase[31]?(~{phase[31],phase}+33'd1):{1'b0,phase};
            boundary=(33'd2147483648-magnitude)<=64;
        end
    endfunction
    wire signed [42:0] next_x=y>0 ? x+(y>>>iteration):(y<0?x-(y>>>iteration):x);
    wire signed [42:0] next_y=y>0 ? y-(x>>>iteration):(y<0?y+(x>>>iteration):y);
    wire signed [33:0] next_z=y>0 ? z+cfo_atan_word(iteration):(y<0?z-cfo_atan_word(iteration):z);
    assign s_ready=resetn&&state==IDLE;
    always @(posedge clk)begin
        if(!resetn)begin
            state<=IDLE;iteration<=0;quadrant_x<=0;quadrant_y<=0;
            magnitude_x<=0;magnitude_y<=0;largest<=0;shift<=0;x<=0;y<=0;z<=0;
            m_valid<=0;m_sample_index<=0;m_phase_word<=0;m_defined<=0;m_boundary_ambiguous<=0;
        end else begin
            case(state)
                IDLE:if(s_valid&&s_ready)begin
                    m_sample_index<=s_sample_index;
                    if(s_corr_i==0)begin
                        m_phase_word<=s_corr_q==0?32'sd0:(s_corr_q[19]?-32'sd1073741824:32'sd1073741824);
                        m_defined<=s_corr_q!=0;m_boundary_ambiguous<=0;m_valid<=1;state<=RESULT;
                    end else begin
                        quadrant_x<=input_x<0?-input_x:input_x;
                        quadrant_y<=input_x<0?-input_y:input_y;
                        magnitude_x<=input_x<0?-input_x:input_x;
                        magnitude_y<=input_y<0?-input_y:input_y;
                        z<=input_x<0?(input_y<0?-34'sd2147483648:34'sd2147483648):34'sd0;
                        state<=MAXIMUM;
                    end
                end
                MAXIMUM:begin largest<=magnitude_x>magnitude_y?magnitude_x:magnitude_y;state<=LEADING;end
                LEADING:begin shift<=normalize_shift(largest);state<=NORMALIZE;end
                NORMALIZE:begin x<=extended_x<<<shift;y<=extended_y<<<shift;iteration<=0;state<=ITERATE;end
                ITERATE:begin
                    x<=next_x;y<=next_y;z<=next_z;
                    if(iteration==31)begin
                        m_phase_word<=next_z[31:0];m_defined<=1;
                        m_boundary_ambiguous<=boundary(next_z[31:0]);m_valid<=1;state<=RESULT;
                    end else iteration<=iteration+1'b1;
                end
                RESULT:if(m_valid&&m_ready)begin m_valid<=0;state<=IDLE;end
                default:begin state<=IDLE;m_valid<=0;end
            endcase
        end
    end
endmodule
