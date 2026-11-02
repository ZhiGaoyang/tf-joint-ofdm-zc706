`timescale 1ns/1ps
module ofdm_rx_metric_registered (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_sample_index,
    output reg signed [39:0] m_corr_i,
    output reg signed [39:0] m_corr_q,
    output reg [38:0] m_energy_0,
    output reg [38:0] m_energy_1
);
    (* ram_style = "block" *) reg [31:0] sample_delay [0:159];
    reg signed [32:0] history_i [0:127];
    reg signed [32:0] history_q [0:127];
    reg [31:0] history_e0 [0:127];
    reg [31:0] history_e1 [0:127];
    reg [7:0] delay_pointer;
    reg [6:0] history_pointer;
    reg [7:0] delay_count;
    reg [7:0] history_count;
    reg [63:0] accepted_index;
    reg pair_valid, multiply_valid;
    reg [63:0] pair_index,multiply_index;
    reg [31:0] pair_old,pair_new;
    reg signed [31:0] multiply_ii,multiply_qq,multiply_iq,multiply_qi;
    reg signed [31:0] multiply_ai2,multiply_aq2,multiply_bi2,multiply_bq2;
    reg product_valid;
    reg [63:0] product_index;
    reg signed [32:0] product_i, product_q;
    reg [31:0] product_e0, product_e1;
    reg signed [39:0] sum_i, sum_q;
    reg [38:0] sum_e0, sum_e1;

    wire ce = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = resetn && ce;
    wire take_input = s_axis_tvalid && s_axis_tready;
    wire signed [15:0] ai = pair_old[15:0];
    wire signed [15:0] aq = pair_old[31:16];
    wire signed [15:0] bi = pair_new[15:0];
    wire signed [15:0] bq = pair_new[31:16];
    wire signed [31:0] ii = ai * bi;
    wire signed [31:0] qq = aq * bq;
    wire signed [31:0] iq = ai * bq;
    wire signed [31:0] qi = aq * bi;
    wire signed [31:0] ai2 = ai * ai;
    wire signed [31:0] aq2 = aq * aq;
    wire signed [31:0] bi2 = bi * bi;
    wire signed [31:0] bq2 = bq * bq;
    wire signed [39:0] old_i = history_count == 128 ? {{7{history_i[history_pointer][32]}},history_i[history_pointer]} : 40'sd0;
    wire signed [39:0] old_q = history_count == 128 ? {{7{history_q[history_pointer][32]}},history_q[history_pointer]} : 40'sd0;
    wire [38:0] old_e0 = history_count == 128 ? {7'd0,history_e0[history_pointer]} : 39'd0;
    wire [38:0] old_e1 = history_count == 128 ? {7'd0,history_e1[history_pointer]} : 39'd0;
    wire signed [39:0] next_i = sum_i + {{7{product_i[32]}},product_i} - old_i;
    wire signed [39:0] next_q = sum_q + {{7{product_q[32]}},product_q} - old_q;
    wire [38:0] next_e0 = sum_e0 + {7'd0,product_e0} - old_e0;
    wire [38:0] next_e1 = sum_e1 + {7'd0,product_e1} - old_e1;

    // Read-first synchronous history; validity, not RAM contents, resets the epoch.
    always @(posedge clk) begin
        if(take_input)begin
            sample_delay[delay_pointer]<=s_axis_tdata;
            pair_old<=sample_delay[delay_pointer];
        end
    end
    always @(posedge clk) begin
        if (!resetn) begin
            delay_pointer <= 0;
            history_pointer <= 0;
            delay_count <= 0;
            history_count <= 0;
            accepted_index <= 0;
            pair_valid<=0;multiply_valid<=0;pair_index<=0;multiply_index<=0;pair_new<=0;
            multiply_ii<=0;multiply_qq<=0;multiply_iq<=0;multiply_qi<=0;
            multiply_ai2<=0;multiply_aq2<=0;multiply_bi2<=0;multiply_bq2<=0;
            product_valid <= 0;
            product_index <= 0;
            product_i <= 0; product_q <= 0;
            product_e0 <= 0; product_e1 <= 0;
            sum_i <= 0; sum_q <= 0; sum_e0 <= 0; sum_e1 <= 0;
            m_axis_tvalid <= 0;
            m_sample_index <= 0;
            m_corr_i <= 0; m_corr_q <= 0; m_energy_0 <= 0; m_energy_1 <= 0;
        end else if (ce) begin
            pair_valid<=take_input&&delay_count==160;
            multiply_valid<=pair_valid;
            multiply_index<=pair_index;
            multiply_ii<=ii;multiply_qq<=qq;multiply_iq<=iq;multiply_qi<=qi;
            multiply_ai2<=ai2;multiply_aq2<=aq2;multiply_bi2<=bi2;multiply_bq2<=bq2;
            product_valid <= 0;
            m_axis_tvalid <= 0;
            if (take_input) begin
                pair_new<=s_axis_tdata;pair_index<=accepted_index;
                delay_pointer <= delay_pointer == 159 ? 8'd0 : delay_pointer + 1'b1;
                accepted_index <= accepted_index + 1'b1;
                if (delay_count < 160) delay_count <= delay_count + 1'b1;
            end
            if(multiply_valid)begin
                product_valid<=1;product_index<=multiply_index;
                product_i<={multiply_ii[31],multiply_ii}+{multiply_qq[31],multiply_qq};
                product_q<={multiply_iq[31],multiply_iq}-{multiply_qi[31],multiply_qi};
                product_e0<=$unsigned(multiply_ai2)+$unsigned(multiply_aq2);
                product_e1<=$unsigned(multiply_bi2)+$unsigned(multiply_bq2);
            end
            if (product_valid) begin
                history_i[history_pointer] <= product_i;
                history_q[history_pointer] <= product_q;
                history_e0[history_pointer] <= product_e0;
                history_e1[history_pointer] <= product_e1;
                history_pointer <= history_pointer + 1'b1;
                if (history_count < 128) history_count <= history_count + 1'b1;
                sum_i <= next_i; sum_q <= next_q;
                sum_e0 <= next_e0; sum_e1 <= next_e1;
                if (history_count >= 127) begin
                    m_axis_tvalid <= 1;
                    m_sample_index <= product_index;
                    m_corr_i <= next_i; m_corr_q <= next_q;
                    m_energy_0 <= next_e0; m_energy_1 <= next_e1;
                end
            end
        end
    end
endmodule
