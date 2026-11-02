`timescale 1ns/1ps
// Copy of the accepted ofdm_rx_channel_coeff with a configurable usable-energy
// floor (the fixed 2^22 rejects every bin at the measured -47.7 dBFS RF level).
module ofdm_rxs_coeff (
    input wire clk,resetn,input wire [31:0] cfg_min_energy,
    input wire [31:0] s_axis_tdata0,s_axis_tdata1,
    input wire [7:0] s_axis_tindex,input wire [15:0] s_axis_tepoch,
    input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
    output wire [47:0] m_axis_tdata,output wire [7:0] m_axis_tindex,
    output wire [15:0] m_axis_tepoch,output wire m_axis_tlast,m_axis_tusable,m_axis_tclip,
    output wire [1:0] m_axis_terror,output wire m_axis_tvalid,input wire m_axis_tready,
    output reg fault
);
    localparam [127:0] TRAINING=128'h6f634bb9957f000000002cea7d0e24da;
    reg [26:0] valid,usable,last,sign_i,sign_q;
    reg [7:0] index[0:26];reg [15:0] epoch[0:26];reg [1:0] errors[0:26];
    reg signed [16:0] mean_i,mean_q;
    reg [31:0] square_i,square_q;reg [15:0] magnitude_i,magnitude_q;
    reg [31:0] denominator[2:24];
    reg [52:0] remainder_i[2:24],remainder_q[2:24];
    reg [21:0] quotient_i[2:24],quotient_q[2:24];
    reg [23:0] rounded_i,rounded_q;
    reg [47:0] output_data;reg output_clip;
    wire advance=resetn&&(!valid[26]||m_axis_tready);
    wire active=((s_axis_tindex>=1&&s_axis_tindex<=48)||(s_axis_tindex>=80&&s_axis_tindex<=127));
    wire [1:0] input_error={(s_axis_tlast!=(s_axis_tindex==127)),s_axis_tindex[7]};
    wire [32:0] energy={1'b0,square_i}+{1'b0,square_q};
    wire permitted=usable[1]&&errors[1]==0&&energy>={1'b0,cfg_min_energy};
    wire [32:0] twice_ri={1'b0,remainder_i[24][31:0]}<<1;
    wire [32:0] twice_rq={1'b0,remainder_q[24][31:0]}<<1;
    wire increment_i=twice_ri>{1'b0,denominator[24]}||
        (twice_ri=={1'b0,denominator[24]}&&quotient_i[24][0]);
    wire increment_q=twice_rq>{1'b0,denominator[24]}||
        (twice_rq=={1'b0,denominator[24]}&&quotient_q[24][0]);
    wire clip_i=rounded_i>(sign_i[25]?24'd8388608:24'd8388607);
    wire clip_q=rounded_q>(sign_q[25]?24'd8388608:24'd8388607);
    wire [23:0] result_i=clip_i?(sign_i[25]?24'h800000:24'h7fffff):
        (sign_i[25]?(~rounded_i+24'd1):rounded_i);
    wire [23:0] result_q=clip_q?(sign_q[25]?24'h800000:24'h7fffff):
        (sign_q[25]?(~rounded_q+24'd1):rounded_q);
    integer k;
    function signed [16:0] training_mean;
        input signed [15:0] a,b;input negative;
        reg signed [16:0] sum;reg [16:0] magnitude,rounded;
        begin
            sum={a[15],a}+{b[15],b};
            magnitude=sum[16]?(~sum+17'd1):sum;
            rounded={1'b0,magnitude[16:1]};
            if(magnitude[0]&&rounded[0])rounded=rounded+1'b1;
            training_mean=(sum[16]^negative)?-$signed(rounded):$signed(rounded);
        end
    endfunction
    assign s_axis_tready=advance;
    assign m_axis_tvalid=resetn&&valid[26];assign m_axis_tdata=output_data;
    assign m_axis_tindex=index[26];assign m_axis_tepoch=epoch[26];
    assign m_axis_tlast=last[26];assign m_axis_tusable=usable[26]&&!output_clip;
    assign m_axis_tclip=output_clip;assign m_axis_terror=errors[26];
    always @(posedge clk)begin
        if(!resetn)begin valid<=0;fault<=0;end
        else if(advance)begin
            valid[0]<=s_axis_tvalid;
            usable[0]<=active;index[0]<=s_axis_tindex;epoch[0]<=s_axis_tepoch;
            last[0]<=s_axis_tlast;errors[0]<=input_error;sign_i[0]<=0;sign_q[0]<=0;
            for(k=1;k<27;k=k+1)begin
                valid[k]<=valid[k-1];usable[k]<=usable[k-1];index[k]<=index[k-1];
                epoch[k]<=epoch[k-1];last[k]<=last[k-1];errors[k]<=errors[k-1];
                sign_i[k]<=sign_i[k-1];sign_q[k]<=sign_q[k-1];
            end
            mean_i<=training_mean(s_axis_tdata0[15:0],s_axis_tdata1[15:0],TRAINING[s_axis_tindex[6:0]]);
            mean_q<=training_mean(s_axis_tdata0[31:16],s_axis_tdata1[31:16],TRAINING[s_axis_tindex[6:0]]);
            square_i<=mean_i*mean_i;square_q<=mean_q*mean_q;
            magnitude_i<=mean_i[16]?-mean_i:mean_i;
            magnitude_q<=mean_q[16]?-mean_q:mean_q;
            sign_i[1]<=mean_i[16];sign_q[1]<=!mean_q[16];
            usable[2]<=permitted;
            denominator[2]<=permitted?energy[31:0]:32'd1;
            remainder_i[2]<=permitted?{5'd0,magnitude_i,32'd0}:53'd0;
            remainder_q[2]<=permitted?{5'd0,magnitude_q,32'd0}:53'd0;
            quotient_i[2]<=0;quotient_q[2]<=0;
            rounded_i<={2'd0,quotient_i[24]}+{23'd0,increment_i};
            rounded_q<={2'd0,quotient_q[24]}+{23'd0,increment_q};
            output_data<=usable[25]?{result_q,result_i}:48'd0;
            output_clip<=usable[25]&&(clip_i||clip_q);
            if((s_axis_tvalid&&input_error!=0)||(valid[25]&&usable[25]&&(clip_i||clip_q)))fault<=1;
        end
    end
    genvar stage;
    generate for(stage=3;stage<=24;stage=stage+1)begin: divide_step
        wire [52:0] shifted={21'd0,denominator[stage-1]}<<(24-stage);
        always @(posedge clk)if(advance)begin
            denominator[stage]<=denominator[stage-1];
            if(remainder_i[stage-1]>=shifted)begin
                remainder_i[stage]<=remainder_i[stage-1]-shifted;
                quotient_i[stage]<=quotient_i[stage-1]|(22'd1<<(24-stage));
            end else begin remainder_i[stage]<=remainder_i[stage-1];quotient_i[stage]<=quotient_i[stage-1];end
            if(remainder_q[stage-1]>=shifted)begin
                remainder_q[stage]<=remainder_q[stage-1]-shifted;
                quotient_q[stage]<=quotient_q[stage-1]|(22'd1<<(24-stage));
            end else begin remainder_q[stage]<=remainder_q[stage-1];quotient_q[stage]<=quotient_q[stage-1];end
        end
    end endgenerate
endmodule
