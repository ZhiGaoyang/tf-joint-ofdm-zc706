# Insert the OFDM core netlist into the platform shell, place, route, report, write bitstream.
# Args: <core_dir> <fresh_out> <threads> <base_dcp> <vivado_home>
if {[version -short] ne "2023.2"} {error "Vivado 2023.2 required"}
if {[llength $argv] != 5} {error "Expected core_dir out threads base_dcp vivado_home"}
lassign $argv core_dir out threads base vivado_home
set core_dir [file normalize $core_dir]
set out [file normalize $out]
set base [file normalize $base]
set xpm [file normalize $vivado_home/data/ip/xpm]
set modem i_system_wrapper/system_i/ofdm_core/inst
if {![string is integer -strict $threads] || $threads < 1 || $threads > 8} {error "threads must be 1..8"}
if {[file exists $out]} {error "Use a fresh output directory"}
if {![file isfile $base] || ![file isfile $core_dir/core.edf] || ![file isdirectory $xpm]} {error "Missing explicit input"}
file mkdir $out
set_param general.maxThreads $threads
proc stage {name script} {
    global out
    set t0 [clock milliseconds]
    uplevel 1 $script
    set f [open $out/costs.tsv a]
    puts $f "$name\t[expr {([clock milliseconds]-$t0)/1000.0}]"
    close $f
}
proc timing_line {tag} {
    global out
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    set f [open $out/summary.tsv a]
    puts $f "$tag\tWNS=$wns\tWHS=$whs"
    close $f
    puts "LEAN_PLATFORM $tag WNS=$wns WHS=$whs"
    return $wns
}

stage open_base {open_checkpoint $base}
set ports_before [lsort [get_property NAME [get_pins -of_objects [get_cells $modem]]]]
# A retained base carries an older modem; a shell from synth_platform_shell.tcl
# already holds the core as a black box and must not be black-boxed again.
if {![get_property IS_BLACKBOX [get_cells $modem]]} {
    stage black_box {update_design -cells [get_cells $modem] -black_box}
}
stage insert {update_design -cells [get_cells $modem] -strict -from_file $core_dir/core.edf}
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]] != 0} {error "LEAN_PLATFORM: unresolved black boxes"}
set ports_after [lsort [get_property NAME [get_pins -of_objects [get_cells $modem]]]]
if {$ports_before ne $ports_after} {error "LEAN_PLATFORM: core pin set changed"}
foreach ref {fft128 ifft128} {
    if {[llength [get_cells -hier -quiet -filter "REF_NAME == $ref || ORIG_REF_NAME == $ref"]] != 1} {
        error "LEAN_PLATFORM: exactly one $ref required"
    }
}

# Stock XPM scoped constraints for every XPM instance inside the new core.
set scripts [dict create \
    xpm_cdc_single $xpm/xpm_cdc/tcl/xpm_cdc_single.tcl \
    xpm_cdc_async_rst $xpm/xpm_cdc/tcl/xpm_cdc_async_rst.tcl \
    xpm_cdc_sync_rst $xpm/xpm_cdc/tcl/xpm_cdc_sync_rst.tcl \
    xpm_cdc_gray $xpm/xpm_cdc/tcl/xpm_cdc_gray.tcl \
    xpm_cdc_array_single $xpm/xpm_cdc/tcl/xpm_cdc_array_single.tcl \
    xpm_cdc_handshake $xpm/xpm_cdc/tcl/xpm_cdc_handshake.tcl \
    xpm_fifo_rst $xpm/xpm_fifo/tcl/xpm_fifo_rst.tcl]
set bound 0
set skipped 0
# The stock scoped scripts call get_ports for the instance's own ports; after an
# EDIF insertion in a full design those queries must be scoped explicitly, or
# they silently see top-level ports (clocks come back empty, async_rst fails).
rename get_ports ::lean_top_get_ports
proc get_ports {args} {
    if {[lsearch -exact $args -scoped_to_current_instance] < 0} {
        set args [linsert $args 0 -scoped_to_current_instance]
    }
    return [uplevel 1 [linsert $args 0 ::lean_top_get_ports]]
}
set f [open $out/xpm_scopes.tsv w]
foreach cell [get_cells -hier -quiet -filter "NAME =~ $modem/* && IS_PRIMITIVE == 0"] {
    set ref [get_property ORIG_REF_NAME $cell]
    if {$ref eq ""} {set ref [get_property REF_NAME $cell]}
    regsub {__parameterized[0-9]+$} $ref {} base_ref
    if {[dict exists $scripts $base_ref]} {
        current_instance $cell
        # A scope whose port was tied off by synthesis has nothing to constrain;
        # record it instead of aborting, and review it in the CDC report.
        set code [catch {source [dict get $scripts $base_ref]} message]
        current_instance -quiet
        if {$code} {
            puts $f "$base_ref\t[get_property NAME $cell]\tNOT_APPLIED\t[string map {\n { }} $message]"
            incr skipped
        } else {
            puts $f "$base_ref\t[get_property NAME $cell]\tAPPLIED"
            incr bound
        }
    }
}
close $f
rename get_ports ""
rename ::lean_top_get_ports get_ports
puts "LEAN_PLATFORM xpm_scopes=$bound skipped=$skipped"
stage save_inserted {write_checkpoint -force $out/system_top_inserted.dcp}
timing_line inserted
stage opt {opt_design}
stage place {place_design}
set wns [timing_line placed]
stage save_placed {write_checkpoint -force $out/system_top_placed.dcp}
if {$wns < 0} {
    stage physopt {phys_opt_design}
    timing_line physopt
}
stage route {route_design}
set wns [timing_line routed]
stage save_routed {write_checkpoint -force $out/system_top_routed.dcp}
stage reports {
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file $out/routed_timing.rpt
    report_timing -delay_type max -max_paths 50 -nworst 1 -unique_pins -file $out/routed_setup50.rpt
    report_utilization -file $out/routed_utilization.rpt
    report_utilization -hierarchical -hierarchical_depth 3 -file $out/routed_hierarchy.rpt
    report_route_status -file $out/route_status.rpt
    report_drc -file $out/routed_drc.rpt
    report_cdc -file $out/routed_cdc.rpt
    report_bus_skew -file $out/routed_bus_skew.rpt
}
# The bitstream is written regardless; it is only used on the board if the
# routed timing above has no negative slack.
stage bitstream {write_bitstream -force $out/system_top.bit}
puts "LEAN_PLATFORM_DONE"
