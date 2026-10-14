# SPDX-License-Identifier: GPL-2.0-or-later
# Keep synthesis process parallelism separate from implementation threading.
foreach {variable parameter default maximum} {
    VIVADO_MAX_THREADS general.maxThreads 1 32
    VIVADO_SYNTH_THREADS synth.maxThreads 1 8
} {
    set value $default
    if {[info exists ::env($variable)]} {
        set value $::env($variable)
    }
    if {![string is integer -strict $value] || $value < 1 || $value > $maximum} {
        error "$variable must be an integer in \[1,$maximum\]"
    }
    set_param $parameter $value
}
puts "INFO: SCOPE build threads: general=[get_param general.maxThreads], synthesis=[get_param synth.maxThreads]"
