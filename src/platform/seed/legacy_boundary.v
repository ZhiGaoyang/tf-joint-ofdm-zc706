`timescale 1ns/1ps
`default_nettype none
// Static image-time selection; no live switching or extra sample latency.
module ofdm_platform_boundary #(parameter integer DEV_TX_ENABLE=0)(
  input wire global_arst,session_arst,rf_tx_arst,rf_rx_arst,
  input wire [31:0] official_i_tx,official_q_tx,dev_i_tx,dev_q_tx,
  input wire [3:0] tpl_enable_tx,input wire [1:0] tpl_valid_tx,
  input wire official_underflow_tx,dev_underflow_tx,
  output wire [31:0] tpl_i_tx,tpl_q_tx,output wire tpl_underflow_tx,dev_arst,
  output wire [1:0] dev_request_tx,dev_enable_tx,output wire dev_request_mismatch_tx,
  input wire [15:0] rf_i_rx,rf_q_rx,input wire [1:0] rf_enable_rx,rf_valid_rx,
  output wire [15:0] tap_i_rx,tap_q_rx,output wire [1:0] tap_enable_rx,tap_valid_rx);

  // Existing endpoints own XPM release and FIFO reset qualification.
  assign dev_arst=global_arst|session_arst|rf_tx_arst|rf_rx_arst;
  assign dev_enable_tx=tpl_enable_tx[1:0];
  assign tap_i_rx=rf_i_rx;
  assign tap_q_rx=rf_q_rx;
  assign tap_enable_rx=rf_enable_rx;
  assign tap_valid_rx=rf_valid_rx;

  generate if(DEV_TX_ENABLE!=0)begin:developer_route
    // Route the complete two-sample I/Q bundle without conversion or delay.
    assign {tpl_i_tx,tpl_q_tx}=dev_arst?64'b0:{dev_i_tx,dev_q_tx};
    // No READY or per-lane ENABLE mask: retain malformed requests and underflow.
    assign dev_request_tx=dev_arst?2'b0:tpl_valid_tx;
    assign dev_request_mismatch_tx=!dev_arst&&(|tpl_valid_tx)&&
      ((tpl_valid_tx!=2'b11)||(tpl_enable_tx[1:0]!=2'b11));
    // Official underflow is FIFO-wide; enabled channel 2/3 retention is conservative.
    assign tpl_underflow_tx=(!dev_arst&&dev_underflow_tx)||
      (official_underflow_tx&&(|tpl_enable_tx[3:2]));
  end else begin:official_route
    // Default bypass remains bit-exact even while any developer reset is asserted.
    assign {tpl_i_tx,tpl_q_tx}={official_i_tx,official_q_tx};
    assign tpl_underflow_tx=official_underflow_tx;
    assign dev_request_tx=2'b0;
    assign dev_request_mismatch_tx=1'b0;
  end endgenerate
endmodule
`default_nettype wire
