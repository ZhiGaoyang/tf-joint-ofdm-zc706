# Out-of-context synthesis of the final OFDM core (ofdm_development_core, time-frequency joint version).
# Usage: vivado -mode batch -source build/core_synth.tcl -tclargs <package root> <fresh output dir>
# Produces core.edf (inserted by build/platform.tcl), core_linked.dcp and the core reports.
if {[version -short] ne "2023.2"} {error "Vivado 2023.2 required"}
if {[llength $argv] != 2} {error "Expected package root and fresh output directory"}
set root [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Use a fresh output directory"}
file mkdir $out
set rtl $root/src/rtl/ofdm
set ip $root/src/ip/fft
set ifft $root/src/ip/ifft
create_project -in_memory -part xc7z045ffg900-2
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
foreach f {
    phy/ofdm_rx_metric_registered.v phy/ofdm_rx_equalize.v phy/ofdm_rx_cpe_phase.v
    rxs/ofdm_rxs_dcblock.v rxs/ofdm_rxs_ring.v rxs/ofdm_rxs_detect.v rxs/ofdm_rxs_fetch.v
    rxs/ofdm_rxs_fft.v rxs/ofdm_rxs_coeff.v rxs/ofdm_rxs_chan.v rxs/ofdm_rxs_cpe.v
    rxs/ofdm_rxs_cmetric.v rxs/ofdm_rxs_decode.v rxs/ofdm_rxs_core.v
    phy/ofdm_ifft_stream.v phy/ofdm_cp_insert.v phy/ofdm_carrier_loader.v phy/ofdm_training_mux.v
    txs/ofdm_tx_framer_v2.v txs/ofdm_tx_mapper_v2.v txs/ofdm_frame_grid_v2.v txs/ofdm_tx_frame_v2.v
    txs/ofdm_tx_prbs_source.v txs/ofdm_tx_rf_frame_v2.v
    interfaces/ofdm_async_fifo.v interfaces/ofdm_tx_adapter.v interfaces/ofdm_tx_prefill.v
    interfaces/ofdm_rx_adapter.v lean/ofdm_development_core.v
} {
    read_verilog $rtl/$f
}
read_verilog $ip/fft128_stub.v
read_verilog $ifft/ifft_core_stub.v
set f [open $out/clocks.xdc w]
puts $f {create_clock -name phy_clk -period 5.000 [get_ports clk]}
puts $f {create_clock -name tx_clk -period 4.000 [get_ports tx_clk]}
puts $f {create_clock -name rx_clk -period 4.000 [get_ports rx_clk]}
close $f
read_xdc $out/clocks.xdc
synth_design -top ofdm_development_core -part xc7z045ffg900-2 -mode out_of_context \
    -include_dirs [list $rtl/phy] -generic SIN_ROM_FILE=$rtl/phy/ofdm_cfo_sine_quarter.mem
foreach {ref from} [list fft128 $ip/fft128_edif/fft128/fft128.edn ifft128 $ifft/ifft_core.edf] {
    set cells [get_cells -hier -quiet -filter "IS_BLACKBOX == 1 && REF_NAME == $ref"]
    if {[llength $cells] != 1} {error "CORE_SYNTH: exactly one $ref black box required"}
    update_design -cells $cells -strict -from_file $from
}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]] != 0} {error "CORE_SYNTH: unresolved black boxes"}
set ports [lsort [get_ports]]
set f [open $out/core_ports.tsv w]
puts $f "NAME\tDIRECTION"
foreach p $ports {puts $f "[get_property NAME $p]\t[get_property DIRECTION $p]"}
close $f
puts "CORE_SYNTH_PORTS [llength $ports]"
write_checkpoint -force $out/core_linked.dcp
write_edif -force -security_mode all $out/core.edf
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -file $out/hierarchy.rpt
report_timing_summary -delay_type min_max -max_paths 10 -file $out/timing_summary.rpt
report_timing -delay_type max -max_paths 40 -nworst 1 -unique_pins -file $out/setup40.rpt
report_cdc -file $out/cdc.rpt
puts "CORE_SYNTH_DONE"
