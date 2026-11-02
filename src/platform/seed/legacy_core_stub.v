`timescale 1ns/1ps
`default_nettype none
(* black_box = "yes" *)
module ofdm_development_core (
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi:s_axis_mm2s:m_axis_s2mm, ASSOCIATED_RESET global_arst, FREQ_HZ 200000000" *)
 input wire clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 tx_clk CLK" *) input wire tx_clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 rx_clk CLK" *) input wire rx_clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 global_arst RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_HIGH" *) input wire global_arst,
 input wire dev_arst,rf_tx_arst,rf_rx_arst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWADDR", X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32, FREQ_HZ 200000000" *) input wire [31:0] s_axi_awaddr,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWVALID" *) input wire s_axi_awvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi AWREADY" *) output wire s_axi_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WDATA" *) input wire [31:0] s_axi_wdata,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WSTRB" *) input wire [3:0] s_axi_wstrb,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WVALID" *) input wire s_axi_wvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi WREADY" *) output wire s_axi_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BRESP" *) output wire [1:0] s_axi_bresp,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BVALID" *) output wire s_axi_bvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi BREADY" *) input wire s_axi_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARADDR" *) input wire [31:0] s_axi_araddr,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARVALID" *) input wire s_axi_arvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi ARREADY" *) output wire s_axi_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RDATA" *) output wire [31:0] s_axi_rdata,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RRESP" *) output wire [1:0] s_axi_rresp,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RVALID" *) output wire s_axi_rvalid,(* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 s_axi RREADY" *) input wire s_axi_rready,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TDATA" *) input wire [63:0] s_axis_mm2s_tdata,(* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TKEEP" *) input wire [7:0] s_axis_mm2s_tkeep,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TLAST" *) input wire s_axis_mm2s_tlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TVALID" *) input wire s_axis_mm2s_tvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 s_axis_mm2s TREADY" *) output wire s_axis_mm2s_tready,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TDATA" *) output wire [63:0] m_axis_s2mm_tdata,(* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TKEEP" *) output wire [7:0] m_axis_s2mm_tkeep,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TLAST" *) output wire m_axis_s2mm_tlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TVALID" *) output wire m_axis_s2mm_tvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis_s2mm TREADY" *) input wire m_axis_s2mm_tready,
 (* X_INTERFACE_IGNORE="true" *) output wire [31:0] dev_i_tx,dev_q_tx,
 (* X_INTERFACE_IGNORE="true" *) output wire dev_underflow_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire [1:0] dev_request_tx,dev_enable_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire dev_request_mismatch_tx,
 (* X_INTERFACE_IGNORE="true" *) input wire [15:0] rf_i_rx,rf_q_rx,
 (* X_INTERFACE_IGNORE="true" *) input wire [1:0] rf_enable_rx,rf_valid_rx,
 output wire session_arst,legacy_irq,bridge_irq,
 output wire [31:0] retained_boundary_faults,
 output wire [31:0] boundary_mismatch_count_tx
);
endmodule
`default_nettype wire
