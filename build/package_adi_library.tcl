# Package explicit IP dependencies from a clean tracked-source export only.
# Args: source_root fresh_receipt_dir library_path ...
proc run {} {
    global argv
    if {[version -short] ne "2023.2"} {error "Vivado 2023.2 required"}
    if {[llength $argv] < 3} {error "Expected source_root fresh_receipt_dir library paths"}
    set source_root [file normalize [string map {\\ /} [lindex $argv 0]]]
    set receipt [file normalize [string map {\\ /} [lindex $argv 1]]]
    set paths [lrange $argv 2 end]
    if {[file exists $receipt]} {error "Use a fresh receipt directory"}
    foreach path $paths {
        if {![regexp {^[a-z0-9_/]+$} $path] || [string match "/*" $path]} {error "Invalid library path"}
        set dir "$source_root/library/$path"
        if {![file isfile "$dir/[file tail $path]_ip.tcl"]} {error "Missing packaging script: $path"}
        if {[file exists "$dir/component.xml"]} {error "Already packaged; reuse its prior result: $path"}
    }
    file mkdir $receipt
    set ::env(ADI_HDL_DIR) $source_root
    set ::env(REQUIRED_VIVADO_VERSION) 2023.2
    set ::env(ADI_VIVADO_IP_LIBRARY) user
    unset -nocomplain ::env(ADI_IGNORE_VERSION_CHECK)
    set ::IGNORE_VERSION_CHECK 0
    set_param general.maxThreads 1
    set log [open "$receipt/packages.tsv" w]
    puts $log "path\tseconds\tartifact"
    foreach path $paths {
        set dir "$source_root/library/$path"
        cd $dir
        set start [clock milliseconds]
        uplevel #0 [list source "$dir/[file tail $path]_ip.tcl"]
        if {$path eq "interfaces"} {
            set artifact "$dir/if_xcvr_cm.xml"
        } elseif {$path eq "jesd204/interfaces"} {
            set artifact "$dir/jesd204_rx_cfg.xml"
        } else {
            set artifact "$dir/component.xml"
        }
        if {![file isfile $artifact]} {error "Packaging artifact absent: $path"}
        if {[llength [get_projects -quiet]]} {close_project}
        set seconds [expr {([clock milliseconds] - $start) / 1000.0}]
        puts $log "$path\t$seconds\t$artifact"
        flush $log
        puts "ADI_PACKAGE_COMPLETE $path $seconds"
    }
    close $log
    set f [open "$receipt/native_result.json" w]
    puts $f "{\"status\":\"ADI_SELECTED_PACKAGING_COMPLETE\",\"packages\":[llength $paths],\"synthesis_executed\":false,\"official_board_build_executed\":false}"
    close $f
}
if {[catch {run} message options]} {
    puts stderr "ADI_PACKAGING_FAILED: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
exit 0
