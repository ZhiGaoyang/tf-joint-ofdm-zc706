`timescale 1ns/1ps
// Forward FFT (xfft 9.1 fft128, unscaled, natural order) with per-symbol
// {tag, sym} metadata and saturation to signed16/F14.  Based on the
// accepted ofdm_fft_stream wrapper; at most 8 symbols are in flight.
module ofdm_rxs_fft (
    input wire clk,
    input wire resetn,
    input wire [31:0] s_data,
    input wire [7:0] s_tag,
    input wire [7:0] s_sym,
    input wire s_last,
    input wire s_valid,
    output wire s_ready,
    output reg [31:0] m_data,
    output reg [6:0] m_k,
    output reg [7:0] m_tag,
    output reg [7:0] m_sym,
    output reg m_last,
    output reg m_valid,
    input wire m_ready,
    output reg [31:0] stat_saturations,
    output reg fault
);
    reg configured;
    reg [15:0] meta [0:7];
    reg [2:0] meta_wr, meta_rd;
    reg [3:0] meta_count;
    reg [6:0] in_index;
    wire config_ready;
    wire core_in_ready;
    wire [47:0] core_data;
    wire [7:0] core_user;
    wire core_valid, core_last;
    wire out_enable = !m_valid || m_ready;
    wire core_ready = resetn && out_enable;
    wire in_permitted = configured && (in_index != 0 || meta_count < 4'd8);
    assign s_ready = resetn && in_permitted && core_in_ready;
    wire in_fire = s_valid && s_ready;
    wire out_fire = core_valid && core_ready;
    wire meta_push = in_fire && s_last;
    wire meta_pop = out_fire && core_last;
    wire ev_unexpected, ev_missing;
    fft128 core (
        .aclk(clk), .aresetn(resetn),
        .s_axis_config_tdata(8'h01), .s_axis_config_tvalid(resetn && !configured),
        .s_axis_config_tready(config_ready),
        .s_axis_data_tdata(s_data), .s_axis_data_tvalid(resetn && in_permitted && s_valid),
        .s_axis_data_tready(core_in_ready), .s_axis_data_tlast(s_last),
        .m_axis_data_tdata(core_data), .m_axis_data_tuser(core_user),
        .m_axis_data_tvalid(core_valid), .m_axis_data_tready(core_ready), .m_axis_data_tlast(core_last),
        .event_frame_started(), .event_tlast_unexpected(ev_unexpected),
        .event_tlast_missing(ev_missing), .event_status_channel_halt(),
        .event_data_in_channel_halt(), .event_data_out_channel_halt());
    wire signed [23:0] ci = core_data[23:0];
    wire signed [23:0] cq = core_data[47:24];
    wire clip_i = ci > 24'sd32767 || ci < -24'sd32768;
    wire clip_q = cq > 24'sd32767 || cq < -24'sd32768;
    function [15:0] clamp;
        input signed [23:0] value;
        begin
            clamp = value > 24'sd32767 ? 16'h7fff : (value < -24'sd32768 ? 16'h8000 : value[15:0]);
        end
    endfunction
    always @(posedge clk) begin
        if (!resetn) begin
            configured <= 0; meta_wr <= 0; meta_rd <= 0; meta_count <= 0; in_index <= 0;
            m_valid <= 0; m_last <= 0; stat_saturations <= 0; fault <= 0;
        end else begin
            if (!configured && config_ready) configured <= 1;
            if (in_fire) begin
                in_index <= in_index + 1'b1;
                if (s_last != (in_index == 7'd127)) fault <= 1;
            end
            if (meta_push) begin meta[meta_wr] <= {s_tag, s_sym}; meta_wr <= meta_wr + 1'b1; end
            if (meta_pop) meta_rd <= meta_rd + 1'b1;
            meta_count <= meta_count + (meta_push ? 1'b1 : 1'b0) - (meta_pop ? 1'b1 : 1'b0);
            if (out_enable) begin
                m_valid <= core_valid;
                if (core_valid) begin
                    m_data <= {clamp(cq), clamp(ci)};
                    m_k <= core_user[6:0];
                    {m_tag, m_sym} <= meta[meta_rd];
                    m_last <= core_last;
                    stat_saturations <= stat_saturations + clip_i + clip_q;
                end
            end
            if (ev_unexpected || ev_missing) fault <= 1;
        end
    end
endmodule
