// CRT Adjust: H-Size, H-Position and V-Shift of the analog picture from the OSD (page "CRT Adjust"), for a 15 kHz CRT.
//
// The picture goes through the one-line buffer of rmonic79's crt_adjust (modules/crt_adjust, GPL-3.0-or-later, MiSTer-CRT-Adjust): the CONTENT is stretched / shifted
// in the buffer while the horizontal sync stays native and the vertical sync is delayed by whole lines, so the CRT keeps its lock while the picture is moved.  This is
// the glue the upstream's core-side snippet describes (after the Metro core's rtl/metro_crtadj.sv): it decodes the OSD fields, makes the buffer's read clock enable
// and switches between the native stream and the adjusted one.
//
//   i_on = 0  : the stream passes untouched (the module is not in the path).
//   H-Size    : i_hsize_f, signed 5 bits, -16 .. +15: a dot lasts (64 + n) / 64 of a native dot, so a step is 1/64 of the picture's width in every build (DOT_DIV
//               clocks per dot: 11, 13 or 15).  The picture grows about its own centre: the module counts its read-out from the horizontal sync, so the content is
//               shifted back by C * n / (64 + n) dots, C = the picture's centre in dots after the sync (i_hstart + i_hwidth / 2).
//   H-Position: i_hpos_f = OSD index 0 .. 96: 0 .. 48 are +0 .. +48 dots to the right, 49 .. 96 are -48 .. -1 (to the left).
//   V-Shift   : i_vshift_f, signed 5 bits, -16 .. +15 lines (positive = down: the vertical sync comes earlier).
//
// The seta2 stream starts a line with its horizontal sync (dot 0) and changes the vertical blank at that same dot, so the buffer line that starts at a sync rise holds
// that line's picture; the module's own vertical gate (the blank sampled at the sync rise, one line later for the read side) then matches the line it emits.
`default_nettype none
module s2_crtadj #(
    parameter int DOT_DIV = 15,                 // machine clocks per dot (the build's)
    parameter int VTOTAL  = 262                 // the longest frame (lines): sizes the module's vertical-sync shift register
) (
    input  wire               clk,
    input  wire               i_on,
    input  wire        [4:0]  i_hsize_f,
    input  wire        [6:0]  i_hpos_f,
    input  wire        [4:0]  i_vshift_f,
    input  wire        [9:0]  i_hstart,         // the raster in force (the MRA's): picture start (dots after the sync rise), width, lines per frame
    input  wire        [8:0]  i_hwidth,
    input  wire        [8:0]  i_vtotal,
    input  wire               i_ce, i_hblank, i_vblank, i_hs, i_vs,
    input  wire        [23:0] i_rgb,
    output wire               o_ce, o_hblank, o_vblank, o_hs, o_vs,
    output wire        [23:0] o_rgb
);
    // ---- the OSD values, taken over at the dot rate
    logic               on_q = 1'b0;
    logic signed [4:0]  hsize_s = '0;
    logic        [4:0]  hsize_q = '0;
    logic signed [8:0]  hpos_s = '0;
    logic signed [6:0]  vs_t = '0;
    logic        [8:0]  vshort = '0;                 // lines the frame in force is shorter than VTOTAL
    logic        [9:0]  centre = '0;
    always_ff @(posedge clk) if (i_ce) begin
        on_q    <= i_on;
        hsize_s <= $signed(i_hsize_f);
        hsize_q <= i_hsize_f;
        hpos_s  <= (i_hpos_f <= 7'd48) ? $signed({2'b00, i_hpos_f}) : ($signed({2'b00, i_hpos_f}) - 9'sd97);
        // the picture is read a line after it is written, so the sync is delayed one line to keep its place; a positive V-Shift moves the picture down, which is the
        // sync coming earlier
        vs_t    <= 7'sd1 - $signed({i_vshift_f[4], i_vshift_f[4], i_vshift_f});
        vshort  <= (i_vtotal < 9'(VTOTAL)) ? 9'(VTOTAL) - i_vtotal : 9'd0;
        centre  <= i_hstart + {2'b00, i_hwidth[8:1]};
    end

    // the module delays the sync by "VTOTAL - n" lines for a negative n, which in a shorter frame (Gundam EX: 261) is not "its own total - n": negative values are made
    // that many lines more negative
    wire signed [6:0] vs_a = vs_t[6] ? (vs_t - $signed({1'b0, vshort[5:0]})) : vs_t;

    // the content shift that keeps the picture's centre in place: round(-C * n / (64 + n)) = -(C * k(n) + 2048) >> 12, k(n) = round(4096 * n / (64 + n))
    logic signed [11:0] kn;
    always_comb case (hsize_q)                 // the OSD field: 1 .. 15 = +1 .. +15, 16 .. 31 = -16 .. -1
        5'd1: kn =  12'sd63;      5'd2: kn =  12'sd124;     5'd3: kn =  12'sd183;     5'd4: kn =  12'sd241;
        5'd5: kn =  12'sd297;     5'd6: kn =  12'sd351;     5'd7: kn =  12'sd404;     5'd8: kn =  12'sd455;
        5'd9: kn =  12'sd505;     5'd10: kn =  12'sd554;    5'd11: kn =  12'sd601;    5'd12: kn =  12'sd647;
        5'd13: kn =  12'sd692;    5'd14: kn =  12'sd735;    5'd15: kn =  12'sd778;    5'd16: kn = -12'sd1365;
        5'd17: kn = -12'sd1254;   5'd18: kn = -12'sd1147;   5'd19: kn = -12'sd1044;   5'd20: kn = -12'sd945;
        5'd21: kn = -12'sd850;    5'd22: kn = -12'sd759;    5'd23: kn = -12'sd670;    5'd24: kn = -12'sd585;
        5'd25: kn = -12'sd503;    5'd26: kn = -12'sd424;    5'd27: kn = -12'sd347;    5'd28: kn = -12'sd273;
        5'd29: kn = -12'sd201;    5'd30: kn = -12'sd132;    5'd31: kn = -12'sd65;
        default: kn = 12'sd0;
    endcase
    logic signed [22:0] cprod = '0;
    logic signed [8:0]  hcen = '0;
    logic signed [8:0]  hoff = '0;
    logic signed [5:0]  voff = '0;
    localparam logic signed [8:0] HBIAS = -9'sd1;  // cancels the module's own one-dot delay of the picture
    wire signed [22:0] cshift = cprod >>> 12;
    always_ff @(posedge clk) begin
        cprod <= $signed({1'b0, centre}) * kn + 23'sd2048;
        hcen  <= -cshift[8:0];
        if (i_ce) begin
            hoff <= hpos_s + hcen + HBIAS;
            voff <= vs_a[5:0];
        end
    end

    // ---- the read clock enable: one source dot every DOT_DIV * (64 + H-Size) / 64 clocks (64ths of a clock), restarted on the module's horizontal sync reference
    logic hs_ref, hs_ref_d = 1'b0;
    always_ff @(posedge clk) hs_ref_d <= hs_ref;
    wire  hs_ref_rise = hs_ref && !hs_ref_d;

    localparam int PB = DOT_DIV * 64;                                                // a native dot in 64ths of a clock
    wire  [11:0] rd_period = 12'(PB) + 12'($signed(hsize_s) * DOT_DIV);              // 48 .. 79 x DOT_DIV
    logic [11:0] rd_acc = '0;
    wire         rd_tick   = (rd_acc + 12'd64) >= rd_period;
    always_ff @(posedge clk) begin
        if      (hs_ref_rise) rd_acc <= '0;
        else if (rd_tick)     rd_acc <= rd_acc + 12'd64 - rd_period;
        else                  rd_acc <= rd_acc + 12'd64;
    end
    wire rd_ce = on_q ? rd_tick : i_ce;

    // ---- the buffer
    logic [7:0] str_r, str_g, str_b;
    logic       str_hs, str_vs, str_hb, str_vb;
    crt_adjust #(.VTOTAL(VTOTAL), .HTOTAL(520), .HPOS_MODE(1)) u_adj (   // 1 = the content moves, the horizontal sync stays native (HTOTAL, the longest line, sizes only the other mode's register)
        .clk(clk), .pxl_cen(i_ce), .pxl2_cen(rd_ce), .active(on_q),
        .hsize(hsize_s), .hoffset(hoff), .voffset(voff),
        .r_in(i_rgb[23:16]), .g_in(i_rgb[15:8]), .b_in(i_rgb[7:0]),
        .hs_in(i_hs), .vs_in(i_vs), .hb_in(i_hblank | i_vblank), .vb_in(i_vblank),
        .r_out(str_r), .g_out(str_g), .b_out(str_b),
        .hs_out(str_hs), .vs_out(str_vs), .hb_out(str_hb), .vb_out(str_vb),
        .hs_ref_out(hs_ref)
    );

    // ---- the outputs.  Adjusted: the module's blank already holds the vertical one (its vb_out is the native, one line ahead of the picture it emits), and nothing of the
    // picture is shown inside the horizontal sync pulse
    assign o_ce     = on_q ? rd_ce  : i_ce;
    assign o_rgb    = on_q ? {str_r, str_g, str_b} : i_rgb;
    assign o_hs     = on_q ? str_hs : i_hs;
    assign o_vs     = on_q ? str_vs : i_vs;
    assign o_hblank = on_q ? (str_hb | str_hs) : i_hblank;
    assign o_vblank = on_q ? 1'b0 : i_vblank;

endmodule
`default_nettype wire
