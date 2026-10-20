derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM (as the owner's other cores): the chip is clocked by the PLL's second 96 MHz output, shifted about half a period
# (rtl/pll/pll_0002.v); the pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's edge,
# captured by s2_sdram's input register three edges after the READ command -- gets a two-cycle path.  The register assignments in
# sys/sys.tcl put the SDRAM pins' registers in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# fx68k steps on its phase enables (s2_cen.sv): one every 2.7-2.9 machine clocks on average, 2.2-2 with the OSD's turbo (never closer
# than 2: s2_cen.sv holds back a pulse that would follow one directly; fx68k's longest internal path is ~12.8 ns).  Only paths inside
# the CPU are relaxed; the paths between it and the bus logic, the RAMs and DTACK stay single-cycle.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_main|*u_cpu|*}] -to [get_registers {emu|u_core|u_main|*u_cpu|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_main|*u_cpu|*}] -to [get_registers {emu|u_core|u_main|*u_cpu|*}]

# ==============================================================================
# X1-010 (modules/x1_010): the engine steps on its clock enable (16.67 MHz: one machine clock in 5 or 6), and its channel counter
# changes only on that enable, as do all the engine registers it feeds.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_x1|ch[*]}] -to [get_registers {emu|u_core|u_x1|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_x1|ch[*]}] -to [get_registers {emu|u_core|u_x1|*}]
