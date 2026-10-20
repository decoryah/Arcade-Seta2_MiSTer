// Clock enables from the machine clock (MCLK Hz, the build's: Seta2.sv): the TMP68301 / X1-010 clock of the board, 50 MHz / 3 =
// 16.667 MHz, or on the P0-113A boards (gundamex, grdiansa, grdiansbl: MAME's seta2_32m) 32.53047 MHz / 2 = 16.265 MHz.
//
// A phase accumulator makes a pulse stream at exactly 2 x the CPU clock (a pulse every 2 or 3 machine clocks); the 68000's two
// phases alternate on it, and `tick` (one per CPU clock: the X1-010's clock and the TMP68301 timers' count) comes with phi2.
// `hold` stops the stream (the OSD pause).
//
// `turbo` (the OSD's Turbo CPU / CPU speed, Guardians and Gundam EX only, after the Guardians and Gundam EX MiSTer cores) runs the
// 68000 alone faster: 1 = +25 %, 2 = MCLK / 4, the most there is: Seta2.sdc gives fx68k's internal paths two machine clocks, so its
// phase enables must never come closer than that (its longest internal path is ~12.8 ns, a machine clock 10.7-11.2 ns).  `tick`
// stays on the board's clock: the X1-010, the TMP68301 timers (Guardians' music tempo) and the video keep their rates.  With
// turbo = 0 the phases are the board stream itself, as they always were.
`default_nettype none
module s2_cen #(
    parameter [31:0] MCLK = 32'd96_000_000
) (
    input  logic       clk,
    input  logic       alt,                                 // 1: 16.265 MHz
    input  logic       hold,
    input  logic [1:0] turbo,
    output logic       cen_phi1, cen_phi2,
    output logic       tick
);
    localparam [31:0] STEP_A  = 32'd33_333_333;             // 2 x 50 MHz / 3   (rounded: 1e-8 off)
    localparam [31:0] STEP_B  = 32'd32_530_470;             // 2 x 32.53047 MHz / 2
    localparam [31:0] STEP_A5 = 32'd41_666_667;             // the same, +25 %
    localparam [31:0] STEP_B5 = 32'd40_663_088;
    localparam [31:0] STEP_M  = MCLK / 32'd2;               // a phase every 2 machine clocks

    // the board's stream
    logic [31:0] acc = 32'd0;
    logic        c2  = 1'b0;
    wire  [31:0] nxt = acc + (alt ? STEP_B : STEP_A);
    always_ff @(posedge clk) begin
        if (hold) c2 <= 1'b0;
        else if (nxt >= MCLK) begin acc <= nxt - MCLK; c2 <= 1'b1; end
        else begin acc <= nxt; c2 <= 1'b0; end
    end

    // the turbo stream (a step of at most MCLK / 2 never gives two pulses on consecutive clocks)
    logic [31:0] acc_t = 32'd0;
    logic        c2t   = 1'b0;
    wire  [31:0] step_t = (turbo == 2'd1) ? (alt ? STEP_B5 : STEP_A5) : STEP_M;
    wire  [31:0] nxt_t  = acc_t + step_t;
    always_ff @(posedge clk) begin
        if (hold) c2t <= 1'b0;
        else if (nxt_t >= MCLK) begin acc_t <= nxt_t - MCLK; c2t <= 1'b1; end
        else begin acc_t <= nxt_t; c2t <= 1'b0; end
    end

    // the CPU's phase pulses: never on two consecutive clocks, also when the setting changes between the streams (a pulse that would
    // follow one directly waits a clock)
    logic fired = 1'b0, pend = 1'b0;
    wire  want = (turbo == 2'd0) ? c2 : c2t;
    wire  fire = (want || pend) && !fired;
    always_ff @(posedge clk) begin
        fired <= fire;
        pend  <= hold ? 1'b0 : ((want || pend) && fired);
    end

    logic ph = 1'b0, pht = 1'b0;
    always_ff @(posedge clk) begin
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        tick     <= 1'b0;
        if (fire) begin
            ph <= ~ph;
            if (ph) cen_phi2 <= 1'b1;
            else cen_phi1 <= 1'b1;
        end
        if (c2) begin
            pht <= ~pht;
            if (pht) tick <= 1'b1;
        end
    end
endmodule
`default_nettype wire
