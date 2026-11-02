# Generate all BD output products, the top wrapper and compile order for a
# copied, accepted BD project. No synthesis or implementation.
# Acceptance is decided afterwards by compare_bd_state.py on the saved project;
# the Tcl property snapshots written here are diagnostics only, because fresh
# sessions re-render equal values (1e+08, 100.0, <Select> for disabled params).
proc run_outputs {} {
    global argv
    if {[version -short] ne "2023.2" || [llength $argv] != 3} {
        error "Expected Vivado 2023.2 and: project_xpr adi_library fresh_receipt_dir"
    }
    lassign $argv xpr library receipt
    foreach name {xpr library receipt} {
        set $name [file normalize [string map {\\ /} [set $name]]]
    }
    if {[file exists $receipt]} {error "Use a fresh receipt directory"}
    file mkdir $receipt
    set ::bd_library_only 1
    uplevel #0 [list source [file join [file dirname [info script]] validate_platform_bd.tcl]]
    open_project $xpr
    set project_dir [file normalize [get_property DIRECTORY [current_project]]]
    set_property ip_repo_paths [list $library] [current_project]
    config_ip_cache -disable_cache
    update_ip_catalog
    set bd [one [get_files */system.bd] system_bd]
    open_bd_design $bd
    check_boundary
    write_rows "$receipt/diag_contract_opened.txt" [effective_contract]
    validate_bd_design -force
    check_boundary
    set bindings [check_library $library]
    write_rows "$receipt/library_bindings.txt" $bindings
    foreach ip [get_ips -all] {
        set output [file normalize [get_property IP_OUTPUT_DIR $ip]]
        if {[string first [string tolower "$project_dir/"] [string tolower $output]] != 0} {
            error "IP output escaped copied project: $ip $output"
        }
    }
    set start [clock milliseconds]
    puts "FULL_BD_OUTPUTS_BEGIN"
    generate_target all $bd
    set seconds [expr {([clock milliseconds] - $start) / 1000.0}]
    puts "FULL_BD_OUTPUTS_GENERATED $seconds"
    set wrappers [make_wrapper -files $bd -top]
    if {[llength $wrappers] != 1 || ![file isfile [lindex $wrappers 0]]} {error "Top wrapper missing"}
    add_files -norecurse $wrappers
    set_property top system_top [current_fileset]
    update_compile_order -fileset sources_1
    check_boundary
    if {[check_library $library] ne $bindings} {error "Output generation changed selected ADI definitions"}
    write_rows "$receipt/diag_contract_after.txt" [effective_contract]
    save_bd_design
    set empty {}
    foreach ip [get_ips -all] {
        set output [get_property IP_OUTPUT_DIR $ip]
        if {![file isdirectory $output] || ![llength [glob -nocomplain -directory $output *]]} {lappend empty $ip}
    }
    if {[llength $empty]} {error "IP outputs missing: $empty"}
    report_ip_status -file "$receipt/ip_status.rpt"
    set order [get_files -compile_order sources -used_in synthesis]
    if {![llength $order]} {error "Empty synthesis compile order"}
    write_rows "$receipt/compile_order.txt" $order
    set f [open "$receipt/native_result.json" w]
    puts $f "{\"status\":\"FULL_BD_OUTPUT_GENERATION_COMPLETE\",\"generation_seconds\":$seconds,\"ip_count\":[llength [get_ips -all]],\"compile_order_files\":[llength $order],\"core_is_interface_stub\":true,\"synthesis_executed\":false,\"implementation_executed\":false,\"hardware_acceptance\":false}"
    close $f
    close_project
}
if {[catch {run_outputs} message options]} {
    puts stderr "PLATFORM_OUTPUT_GENERATION_FAILED: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
exit 0
