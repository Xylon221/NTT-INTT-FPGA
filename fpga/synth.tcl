# Non-project Vivado synthesis scaffold. Run from any working directory.
# PART is deliberately mandatory: the source screenshot names no FPGA device.
# Example (replace the placeholder with a real target):
# PART=YOUR_FPGA_PART LOG_N=13 USE_TFG=1 vivado -mode batch -source fpga/synth.tcl

set project_root [file normalize [file join [file dirname [info script]] ..]]
cd $project_root

if {![info exists ::env(PART)] || [string trim $::env(PART)] eq ""} {
    error "Set PART to the real FPGA part number; no device is assumed by this reproduction."
}
set part [string trim $::env(PART)]
set log_n 13
set use_tfg 1
if {[info exists ::env(LOG_N)]} { set log_n $::env(LOG_N) }
if {[info exists ::env(USE_TFG)]} { set use_tfg $::env(USE_TFG) }
if {![string is integer -strict $log_n] || $log_n < 1 || $log_n > 20} {
    error "LOG_N must be an integer from 1 to 20, matching the RTL supported range."
}
if {$use_tfg ni {0 1}} { error "USE_TFG must be 0 or 1." }
set mode [expr {$use_tfg ? "tfg" : "rom"}]
set output_dir [file join $project_root build synth_$mode]
if {[info exists ::env(OUT_DIR)] && $::env(OUT_DIR) ne ""} {
    set output_dir [file normalize $::env(OUT_DIR)]
}
file mkdir $output_dir

# Python-generated ROM tables must match LOG_N; generated metadata remains the
# source of truth. See README for the vector generation command.
set rom_fwd [file join $project_root build vectors rom_forward.hex]
set rom_inv [file join $project_root build vectors rom_inverse.hex]
if {!$use_tfg} {
    set manifest_file [file join $project_root build vectors config.json]
    if {![file isfile $manifest_file]} {
        error "Missing $manifest_file; generate matching vectors before ROM synthesis."
    }
    set manifest_handle [open $manifest_file r]
    set manifest [read $manifest_handle]
    close $manifest_handle
    foreach {key expected} [list log_n $log_n q 2013265921 primitive_root 31] {
        set pattern [format {"%s"\s*:\s*([0-9]+)} $key]
        if {![regexp $pattern $manifest unused actual] || $actual != $expected} {
            error "ROM metadata mismatch for $key; expected $expected. Regenerate vectors."
        }
    }
    set expected_words [expr {1 << ($log_n - 1)}]
    foreach init_file [list $rom_fwd $rom_inv] {
        if {![file isfile $init_file]} {
            error "Missing $init_file; generate matching vectors before ROM synthesis."
        }
        set init_handle [open $init_file r]
        set words [regexp -all -inline {\S+} [read $init_handle]]
        close $init_handle
        if {[llength $words] != $expected_words} {
            error "ROM length mismatch in $init_file; expected $expected_words words."
        }
    }
}

foreach source_name {mod_mul.sv butterfly.sv twiddle_gen.sv ntt_core.sv} {
    set source_file [file join $project_root rtl $source_name]
    if {![file isfile $source_file]} { error "Missing RTL source: $source_file" }
    read_verilog -sv $source_file
}

set generics [list LOG_N=$log_n USE_TFG=$use_tfg]
lappend generics ROM_FWD_FILE=\"$rom_fwd\" ROM_INV_FILE=\"$rom_inv\"
read_xdc [file join $project_root fpga constraints.xdc]
synth_design -top ntt_core -part $part -generic $generics

report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_summary.rpt]
report_timing -max_paths 10 -file [file join $output_dir timing_paths.rpt]
write_checkpoint -force [file join $output_dir synthesized.dcp]

set metadata [open [file join $output_dir run_info.txt] w]
puts $metadata "Vivado: [version -short]"
puts $metadata "PART: $part"
puts $metadata "LOG_N: $log_n"
puts $metadata "USE_TFG: $use_tfg"
puts $metadata "Requested clock period: 10 ns (preliminary constraint)"
puts $metadata "Synthesis only. No place/route, board test, achieved Fmax or power claim."
close $metadata
puts "Synthesis outputs: $output_dir"
