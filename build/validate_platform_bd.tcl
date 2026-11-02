# Reconstruct the accepted boundary wiring without generating IP or synthesis.
proc one {items label} {
    if {[llength $items] != 1} {error "Expected one $label; got $items"}
    return [lindex $items 0]
}
proc snapshot {rows} {
    # Detach native Vivado object handles before later propagation mutates them.
    return [encoding convertfrom utf-8 [encoding convertto utf-8 $rows]]
}
proc topology {} {
    set rows {}
    foreach obj [concat [get_bd_pins -hierarchical] [get_bd_ports]] {
        if {$obj eq "/ofdm_rf_boundary/tx_clk"} {continue}
        lappend rows [list scalar $obj [get_property DIR $obj] [get_property LEFT $obj] [get_property RIGHT $obj] [lsort [get_bd_nets -quiet -of_objects $obj]]]
    }
    foreach obj [concat [get_bd_intf_pins -hierarchical] [get_bd_intf_ports]] {
        lappend rows [list interface $obj [get_property MODE $obj] [get_property VLNV $obj] [lsort [get_bd_intf_nets -quiet -of_objects $obj]]]
    }
    foreach space [get_bd_addr_spaces -hierarchical] {
        foreach seg [get_bd_addr_segs -of_objects $space] {
            lappend rows [list address $space $seg [get_property OFFSET $seg] [get_property RANGE $seg]]
        }
    }
    return [snapshot [lsort $rows]]
}
proc write_rows {path rows} {
    set f [open $path w]
    foreach row $rows {puts $f $row}
    close $f
}
proc canonical_frequency_rows {rows} {
    set result {}
    foreach row $rows {
        # Vivado reloads integer Hz metadata from e.g. 100000000.0 as 100000000.
        # Only discard an all-zero fractional suffix on this declared Hz field.
        if {[lindex $row 0] eq "bus_config" && [lindex $row 2] eq "CONFIG.FREQ_HZ" &&
            [regexp {^([0-9]+)\.0+$} [lindex $row 3] unused integer]} {
            set row [lreplace $row 3 3 $integer]
        }
        lappend result $row
    }
    return [snapshot [lsort $result]]
}
proc check_library {library} {
    set library [file normalize $library]
    set repos [get_property ip_repo_paths [current_project]]
    if {[llength $repos] != 1 || ![string equal -nocase [file normalize [lindex $repos 0]] $library]} {
        error "ADI library repository must be exclusive"
    }
    set vlnvs {}
    foreach cell [get_bd_cells -hierarchical -filter {VLNV =~ analog.com:*}] {
        lappend vlnvs [get_property VLNV $cell]
    }
    if {![llength $vlnvs]} {error "No ADI cells found"}
    set rows {}
    foreach vlnv [lsort -unique $vlnvs] {
        set definition [one [get_ipdefs -all -quiet $vlnv] "definition for $vlnv"]
        if {"XML_FILE_NAME" ni [list_property $definition]} {error "Definition XML property absent: $vlnv"}
        set xml [file normalize [get_property XML_FILE_NAME $definition]]
        set prefix [string tolower "$library/"]
        if {[string first $prefix [string tolower $xml]] != 0 || ![file isfile $xml]} {
            error "ADI definition outside selected library: $vlnv $xml"
        }
        lappend rows [list $vlnv $xml]
    }
    return [snapshot $rows]
}
proc stable_connections {rows} {
    set stable {}
    foreach row $rows {
        if {[lindex $row 0] ne "scalar"} {lappend stable $row; continue}
        lassign $row kind pin direction left right net
        # Vendor interface members and widths are resolved by BD propagation.
        # Board ports and our two module interfaces must remain exact throughout.
        if {[regexp {^/[^/]+$} $pin] || [string match "/ofdm_core/*" $pin] || [string match "/ofdm_rf_boundary/*" $pin]} {
            lappend stable $row
        } elseif {$net ne ""} {
            lappend stable [list $kind $pin $direction $net]
        }
    }
    return [lsort $stable]
}
proc config_rows {kind obj} {
    set rows {}
    foreach key [lsort [list_property $obj]] {
        if {[string match "CONFIG.*" $key] && ![string match "*.VALUE_SRC" $key]} {
            lappend rows [list $kind $obj $key [get_property $key $obj]]
        }
    }
    return $rows
}
proc effective_contract {} {
    set rows {}
    foreach row [topology] {
        lassign $row kind name direction left right net
        if {$kind ne "scalar" || $net ne "" || [regexp {^/[^/]+$} $name] || [string match "/ofdm_core/*" $name] || [string match "/ofdm_rf_boundary/*" $name]} {
            lappend rows $row
        }
    }
    foreach obj [concat [get_bd_intf_pins -hierarchical] [get_bd_intf_ports]] {
        set rows [concat $rows [config_rows bus_config $obj]]
    }
    foreach obj [get_bd_cells -hierarchical] {
        set rows [concat $rows [config_rows cell_config $obj]]
    }
    return [snapshot [lsort $rows]]
}
proc settle_contract {out} {
    set previous {}
    # ADI post_propagate can update a master after its downstream IP was visited.
    # Require a fixed point, not an arbitrary number of silently accepted passes.
    for {set pass 1} {$pass <= 3} {incr pass} {
        validate_bd_design -force
        check_boundary
        set current [effective_contract]
        write_rows "$out/contract_pass$pass.txt" $current
        if {$pass > 1 && $current eq $previous} {
            puts "BD_CONTRACT_STABLE passes=$pass"
            return $current
        }
        set previous $current
    }
    error "BD contract did not stabilize within three passes"
}
proc check_boundary {} {
    if {[get_property CONFIG.DEV_TX_ENABLE [get_bd_cells ofdm_rf_boundary]] ne "1"} {error "Developer route disabled"}
    set clock [one [get_bd_nets -of_objects [get_bd_pins ofdm_core/tx_clk]] core_tx_clock]
    set boundary [one [get_bd_nets -of_objects [get_bd_pins ofdm_rf_boundary/tx_clk]] boundary_tx_clock]
    if {$clock ne $boundary} {error "Boundary TX clock differs"}
    set permission [string tolower [get_property IP_CACHE_PERMISSIONS [current_project]]]
    puts "IP_CACHE_PERMISSION=$permission"
    if {$permission ni {disable disabled}} {error "IP cache unexpectedly enabled: $permission"}
}
proc finish {bd out before library} {
    check_boundary
    set bindings [check_library $library]
    write_rows "$out/library_bindings.txt" $bindings
    if {[topology] ne $before} {error "Existing pins, connections, or addresses changed"}
    set resolved [settle_contract $out]
    set raw [topology]
    write_rows "$out/topology_after_validation.txt" $raw
    set connections_before [stable_connections $before]
    set connections_after [stable_connections $raw]
    write_rows "$out/connections_before.txt" $connections_before
    write_rows "$out/connections_after.txt" $connections_after
    if {$connections_after ne $connections_before} {error "Validation changed connections or user interface"}
    save_bd_design
    write_rows "$out/topology_validated.txt" [topology]
    close_bd_design [current_bd_design]
    open_bd_design $bd
    validate_bd_design -force
    check_boundary
    set reopened_bindings [check_library $library]
    write_rows "$out/library_bindings_reopened.txt" $reopened_bindings
    if {$reopened_bindings ne $bindings} {error "Reopen changed selected ADI definitions"}
    set reopened [effective_contract]
    write_rows "$out/contract_reopened.txt" $reopened
    write_rows "$out/topology_reopened.txt" [topology]
    if {$reopened ne $resolved} {error "Reopen changed effective IP or bus contract"}
    save_bd_design
    report_ip_status -file "$out/ip_status.rpt"
    set f [open "$out/bd_result.json" w]
    puts $f {{"status":"BD_CONTRACT_VALIDATE_REOPEN_PASS_WITH_NOTES","ip_cache":"disabled","dev_tx_enable":1,"boundary_tx_clock_matches_core":true,"stable_connections_preserved":true,"effective_ip_and_bus_contract_equal":true,"vendor_post_propagation_settled":true,"selected_adi_repository_exclusive":true,"adi_definition_paths_verified":true,"core_is_interface_stub":true,"synthesis_executed":false,"hardware_acceptance":false}}
    close $f
    close_project
}
proc run {} {
    global argv
    if {[llength $argv] != 3} {error "Expected staged_inputs adi_library fresh_project"}
    lassign $argv inputs library out
    foreach name {inputs library out} {
        set $name [file normalize [string map {\\ /} [set $name]]]
    }
    if {[version -short] ne "2023.2"} {error "Vivado 2023.2 required"}
    if {[file exists $out]} {error "Use a fresh project directory"}
    set_param general.maxThreads 1
    create_project submission_platform $out -part xc7z045ffg900-2
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
    set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
    set_property ip_repo_paths [list $library] [current_project]
    config_ip_cache -disable_cache
    update_ip_catalog
    set sources [glob "$inputs/*.v"]
    add_files -norecurse $sources
    foreach path $sources {set_property FILE_TYPE Verilog [get_files $path]}
    set constraints [glob "$inputs/*.xdc"]
    if {[llength $constraints] != 4} {error "Expected four constraint files"}
    add_files -fileset constrs_1 -norecurse $constraints
    set bd "$out/submission_platform.srcs/sources_1/bd/system/system.bd"
    file mkdir [file dirname $bd]
    file copy "$inputs/system.bd" $bd
    add_files -norecurse $bd
    open_bd_design $bd
    set before [topology]
    write_rows "$out/topology_before.txt" $before
    update_module_reference [one [get_ips -all system_ofdm_core_0] core_module]
    update_module_reference [one [get_ips -all system_ofdm_rf_boundary_0] boundary_module]
    set_property CONFIG.DEV_TX_ENABLE 1 [get_bd_cells ofdm_rf_boundary]
    set clk [one [get_bd_nets -of_objects [get_bd_pins ofdm_core/tx_clk]] core_tx_net]
    set pin [one [get_bd_pins ofdm_rf_boundary/tx_clk] boundary_tx_pin]
    if {[llength [get_bd_nets -quiet -of_objects $pin]] != 0} {error "New TX pin unexpectedly connected"}
    connect_bd_net -net $clk $pin
    finish $bd $out $before $library
}
if {[info exists bd_library_only] && $bd_library_only} {return}
if {[catch {run} message options]} {
    puts stderr "BD_VALIDATION_FAILED: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
exit 0
