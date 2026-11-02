# No project, synthesis or implementation is opened here.
if {[version -short] ne "2023.2"} {
    puts stderr "SUBMISSION_TOOL_VERSION_FAIL expected=2023.2 actual=[version -short]"
    exit 1
}
puts "SUBMISSION_TOOL_VERSION_PASS 2023.2"
exit 0
