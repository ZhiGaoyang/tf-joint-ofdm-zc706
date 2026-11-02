`timescale 1ns/1ps
// Frame-grid bench for group-masked frames (design B, TX side).
// Drives ofdm_frame_grid_v2 with commands/payloads from vectors.mem and
// compares every output beat with the reference-model words, under seeded
// random output backpressure.  Define NC_MASK_PORT for the NC grid; without
// it the bench drives the accepted grid (mask-0 vectors only).
module tb_nc_grid;
  localparam MAXW = 4000000;
  reg clk = 0, resetn = 0;
  always #2.5 clk = ~clk;
  reg [31:0] vec [0:MAXW-1];
  reg cmd_valid = 0;
  wire cmd_ready;
  reg [31:0] cmd_frame_id = 0;
  reg [12:0] cmd_payload_len = 0;
  reg [1:0] cmd_mcs = 0;
  reg [15:0] cmd_epoch = 0;
  reg [10:0] cfg_mask = 0;
  reg [7:0] s_data = 0;
  reg s_valid = 0, s_last = 0;
  wire s_ready;
  wire [31:0] m_data;
  wire m_valid, m_last, fault;
  wire [1:0] m_user;
  reg m_ready = 0;

  ofdm_frame_grid_v2 dut(.clk(clk), .resetn(resetn),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_frame_id(cmd_frame_id),
    .cmd_payload_len(cmd_payload_len), .cmd_mcs(cmd_mcs), .cmd_config_epoch(cmd_epoch),
`ifdef NC_MASK_PORT
    .cfg_mask(cfg_mask),
`endif
    .s_axis_tdata(s_data), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tlast(s_last),
    .m_axis_tdata(m_data), .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
    .m_axis_tlast(m_last), .m_axis_tuser(m_user), .fault(fault));

  integer seed, ncase, c, p, k, nsym, length, expect_fault, beats, errors, checked, timeout, base;
  integer total_beats, total_cases, stall;
  reg [31:0] head;

  always @(posedge clk) m_ready <= ($random(seed) & 3) != 0;   // ~25% stall cycles

  task automatic fail(input [8*64-1:0] what, input integer a, input integer b);
    begin
      errors = errors + 1;
      if (errors <= 20) $display("NC_GRID_MISMATCH case=%0d %0s got=%h exp=%h", c, what, a, b);
    end
  endtask

  initial begin
    seed = 20261025; errors = 0; checked = 0; total_beats = 0; total_cases = 0;
    $readmemh("vectors.mem", vec);
    ncase = vec[0];
    p = 1;
    for (c = 0; c < ncase; c = c + 1) begin
      head = vec[p]; cmd_frame_id = vec[p+1]; cmd_epoch = vec[p+2]; nsym = vec[p+3]; p = p + 4;
      length = head[12:0]; cmd_mcs = {1'b0, head[13]}; expect_fault = head[14]; cfg_mask = head[26:16];
      cmd_payload_len = length;
      resetn = 0; repeat (8) @(posedge clk); resetn = 1; @(posedge clk);
      // command and payload: drive at negedge; a handshake happens at the next
      // posedge when ready is high at the negedge (ready is stable mid-cycle).
      @(negedge clk); cmd_valid = 1; timeout = 0;
      while (!cmd_ready && timeout < 1000) begin @(negedge clk); timeout = timeout + 1; end
      @(negedge clk); cmd_valid = 0;
      for (k = 0; k < length; k = k + 1) begin
        s_data = vec[p+k]; s_valid = 1; s_last = (k == length-1); timeout = 0;
        while (!s_ready && timeout < 400) begin @(negedge clk); timeout = timeout + 1; end
        if (!s_ready) k = length;              // capture refused (expected only for fault cases)
        else @(negedge clk);
      end
      s_valid = 0; s_last = 0;
      p = p + length;
      if (expect_fault) begin
        repeat (400) @(posedge clk);
        if (!fault) fail("missing_fault", 0, 1);
        checked = checked + 1;
      end else begin
        base = p; beats = 0; timeout = 0;
        while (beats < nsym*128 && timeout < 2000000) begin
          @(posedge clk); timeout = timeout + 1;
          if (m_valid && m_ready) begin
            if (m_data !== vec[base+beats]) fail("data", m_data, vec[base+beats]);
            if (m_last !== ((beats % 128) == 127)) fail("tlast", m_last, beats);
            if (m_user[0] !== (beats == 0)) fail("sof", m_user, beats);
            if (m_user[1] !== (beats == nsym*128-1)) fail("eof", m_user, beats);
            beats = beats + 1; checked = checked + 1;
          end
        end
        if (beats != nsym*128) fail("beat_count", beats, nsym*128);
        stall = 0;
        repeat (600) begin @(posedge clk); if (m_valid && m_ready) stall = stall + 1; end
        if (stall) fail("extra_beats", stall, 0);
        if (fault) fail("unexpected_fault", 1, 0);
        p = p + nsym*128; total_beats = total_beats + beats;
      end
      total_cases = total_cases + 1;
    end
    if (errors == 0 && total_cases == ncase)
      $display("NC_GRID_PASS cases=%0d beats=%0d checks=%0d", total_cases, total_beats, checked);
    else
      $display("NC_GRID_FAIL cases=%0d errors=%0d", total_cases, errors);
    $finish;
  end
endmodule
