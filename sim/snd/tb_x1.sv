// Sound bench: the X1-010 (modules/x1_010) with s2_core's sample banking and mix, its register writes and the bank writes replayed
// from MAME (tools/lua/x1log.lua) by tb_x1.cpp at MAME's times; the sample ROM is the driver's "x1snd" region (C++ side).
`default_nettype none
module tb_x1 (
    input  logic        clk,                // 96 MHz
    input  logic        rst,
    input  logic        alt,                // 32.53047 MHz / 2
    // register write (one clock)
    input  logic        x_req,
    input  logic [12:0] x_addr,
    input  logic [15:0] x_din,
    input  logic        x_uds, x_lds,
    // sample ROM: request out, byte in (C++ answers after a latency)
    output logic        rom_req,
    output logic [19:0] rom_addr,
    input  logic        rom_valid,
    input  logic  [7:0] rom_data,
    output logic signed [15:0] audio,
    output logic        stb
);
    logic cen_phi1, cen_phi2, tick;
    s2_cen u_cen (.clk(clk), .alt(alt), .hold(1'b0), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .tick(tick));
    logic signed [15:0] l, r;
    x1_010 u_x1 (
        .clk(clk), .reset(rst), .ce(tick),
        .cpu_req(x_req), .cpu_we(1'b1), .cpu_addr(x_addr), .cpu_wdata(x_din), .cpu_uds(x_uds), .cpu_lds(x_lds), .cpu_rdata(),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
        .audio_l(l), .audio_r(r), .audio_stb(stb),
        .dbg_samples(), .dbg_overrun(), .dbg_rom_reads()
    );
    wire signed [16:0] mix = l + r;
    always_ff @(posedge clk) audio <= (mix > 17'sd32767) ? 16'sd32767 : (mix < -17'sd32768) ? -16'sd32768 : mix[15:0];
endmodule
`default_nettype wire
