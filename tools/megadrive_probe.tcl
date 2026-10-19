# Console resource probes, not a board build or flash image.
set root [file normalize [file join [file dirname [info script]] ..]]
set upstream [file join $root rtl mdtang src]
if {![info exists with_sdram]} { set with_sdram 0 }
if {![info exists with_menu]} { set with_menu 0 }
set top megadrive_probe
set profile megadrive-probe
if {$with_sdram} {
    set top megadrive_sdram_probe
    set profile megadrive-sdram-probe
}
if {$with_menu} {
    set with_sdram 1
    set top megadrive_menu_probe
    set profile megadrive-menu-probe
}
set work [file join $root impl profile-build $profile]
file mkdir [file join $work impl gwsynthesis]
cd $work

foreach name {microrom.mem nanorom.mem} {
    file copy -force [file join $upstream fx68k $name] [file join $work $name]
    file copy -force [file join $upstream fx68k $name] [file join $work impl gwsynthesis $name]
}

set_device GW2AR-LV18QN88C8/I7 -device_version C
foreach dir {common fx68k jt12 jt12/adpcm jt12/mixer jt89 peripherals t80 vdp} {
    foreach path [lsort [glob -nocomplain -directory [file join $upstream $dir] *.v *.sv]] {
        add_file -type verilog $path
    }
}
add_file -type verilog [file join $upstream system.sv]
add_file -type verilog [file join $root rtl tang megadrive_probe.sv]
if {$with_sdram} {
    add_file -type verilog [file join $root rtl tang sdram.v]
    add_file -type verilog [file join $root rtl tang megadrive_sdram.sv]
    add_file -type verilog [file join $root rtl tang megadrive_sdram_probe.sv]
}
if {$with_menu} {
    # IOSys must be read before PicoRV32 to select its distributed register file.
    foreach name {iosys picorv32 font_rom textdisp simplespimaster spi_master spiflash} {
        add_file -type verilog [file join $root rtl tang iosys ${name}.v]
    }
    add_file -type verilog [file join $root rtl tang megadrive_host_bridge.sv]
    add_file -type verilog [file join $root rtl tang megadrive_menu_probe.sv]
}
add_file -type sdc [file join $root constraints megadrive_probe.sdc]
set_option -synthesis_tool gowinsynthesis
set_option -top_module $top
set_option -output_base_name $top
set_option -include_path [list [file join $upstream common] [file join $upstream vdp]]
set_option -verilog_std sysv2017
run syn
exit
