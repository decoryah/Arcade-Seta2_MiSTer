`timescale 1ns/10ps
module pll_0002(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);

	// The machine clock of the build (Seta2.sv: a whole multiple of the board's dot clock) and the SDRAM chip's clock: the same,
	// about half a period early, as JTFRAME's for MiSTer SDRAM (-4971 ps at 98.3 MHz; this core's 96 MHz build: -5078 ps, i.e.
	// -0.4875 period), which the controller's READ+3 capture (rd_late = 0) is built for.
	assign outclk_2 = 1'b0;

	altera_pll #(
`ifdef SETA2_GRD
		.fractional_vco_multiplier("false"),            // 50 x 15 = 750 MHz VCO, / 8 = 93.75 MHz
		.output_clock_frequency0("93.750000 MHz"),
		.output_clock_frequency1("93.750000 MHz"),
		.phase_shift1("-5200 ps"),
`elsif SETA2_PEN
		.fractional_vco_multiplier("false"),            // 50 x 91 / 5 = 910 MHz VCO, / 10 = 91 MHz
		.output_clock_frequency0("91.000000 MHz"),
		.output_clock_frequency1("91.000000 MHz"),
		.phase_shift1("-5357 ps"),
`else
		.fractional_vco_multiplier("true"),             // 32.53047 MHz / 4 x 11
		.output_clock_frequency0("89.458792 MHz"),
		.output_clock_frequency1("89.458792 MHz"),
		.phase_shift1("-5449 ps"),
`endif
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
