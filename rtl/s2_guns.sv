// SPDX-License-Identifier: GPL-3.0-or-later
//
// The light guns of Sammy's hunting games (MAME 0.289 seta2.cpp, INPUT_PORTS deerhunt / wschamp: IPT_LIGHTGUN_X / _Y), after ppriest's
// gx_guns.sv (Lethal Enforcers II in the konamigx core) and the Zombie Raid guns of his Arcade-Seta_MiSTer.
//
// Each player's aim is a held position v = 0..255 per axis across the picture, moved by
//   the left stick   absolutely, past a dead zone of 8: -128..127 across the picture, which is what Sinden and GUN4IR guns present
//   the d-pad        two units a frame while held
//   the mouse        relatively, for the player the OSD gives it; its left button is the trigger, its right the pump
// The stick's mode, per player (OSD): Auto (an axis pushed to 96 or more moves as the d-pad does -- arcade sticks on gamepad
// encoders; below that, absolutely), Aim (always absolute) or D-pad (any deflection moves as the d-pad).
//
// The ports read v as MAME's lightgun fields do, linearly across the picture: X = 0x25 + v * 160 / 255 (PORT_MINMAX 0x25, 0xC5),
// Y = 0x08 + v * 240 / 255 (0x0800..0xF800, the high byte), here (v * 161) >> 8 and (v * 241) >> 8, exact at both ends.
// Button 1 is the trigger, button 2 the pump.  The crosshair (OSD) marks v / 256 of the 320 x 240 picture, as MAME draws its own.
`default_nettype none
module s2_guns (
    input  wire        clk,
    input  wire        rst,                 // the guns to the centre
    input  wire [31:0] joy0, joy1,          // joystick_0 / 1: right, left, down, up, B1, B2 from bit 0
    input  wire [15:0] ana0, ana1,          // joystick_l_analog_0 / 1: { Y, X }, signed
    input  wire [24:0] mouse,               // hps_io's ps2_mouse: bit 24 toggles a packet, Y positive up
    input  wire  [1:0] mode0, mode1,        // the sticks: 0 Auto, 1 Aim, 2 D-pad
    input  wire  [1:0] ms_who,              // the mouse: 0 P1, 1 P2, 2 off
    output reg  [15:0] gun1, gun2,          // { Y, X } in MAME's units
    output reg   [1:0] trig, pump,          // { P2, P1 }

    // the crosshair, drawn into the picture
    input  wire  [1:0] show,                // bit 0 P1, bit 1 P2
    input  wire        ce,                  // the dot enable of the stream below
    input  wire        hblank, vblank,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);
    // the inputs, registered here
    reg  [31:0] j [0:1];
    reg  [15:0] a [0:1];
    reg  [24:0] ms;
    reg         ms_t, vbl_l;
    always @(posedge clk) begin
        j[0] <= joy0; j[1] <= joy1; a[0] <= ana0; a[1] <= ana1;
        ms <= mouse; ms_t <= ms[24]; vbl_l <= vblank;
    end
    wire       ms_ev  = ms[24] ^ ms_t;
    wire       frame  = vblank && !vbl_l;
    wire [1:0] ms_sel = { ms_who == 2'd1, ms_who == 2'd0 };
    wire [1:0] mode [0:1];
    assign mode[0] = mode0; assign mode[1] = mode1;

    localparam [7:0] DEAD = 8'd8;           // below this the axis is at rest
    localparam [7:0] FULL = 8'd96;          // at or above it, Auto moves as the d-pad

    function [7:0] mag(input [7:0] v);      // of a signed byte
        mag = v[7] ? 8'd0 - v : v;
    endfunction
    function [7:0] step(input [7:0] v, input signed [9:0] d);   // v + d, held to 0..255
        reg signed [10:0] t;
        begin
            t = $signed({3'b000, v}) + {d[9], d};
            step = t < 11'sd0 ? 8'd0 : t > 11'sd255 ? 8'd255 : t[7:0];
        end
    endfunction

    reg  [7:0] vx [0:1];
    reg  [7:0] vy [0:1];
    reg  [7:0] ax, ay;
    reg        sx, sy, lx, ly;
    reg  [3:0] dir;                         // up, down, left, right
    integer g;
    always @(posedge clk) begin
        for (g = 0; g < 2; g = g + 1) begin
            ax = a[g][7:0]; ay = a[g][15:8];
            lx = mag(ax) >= DEAD; ly = mag(ay) >= DEAD;
            sx = mode[g] == 2'd2 ? lx : mode[g] == 2'd1 ? 1'b0 : mag(ax) >= FULL;
            sy = mode[g] == 2'd2 ? ly : mode[g] == 2'd1 ? 1'b0 : mag(ay) >= FULL;
            dir = { j[g][3] | (ay[7] & sy), j[g][2] | (!ay[7] & sy),
                    j[g][1] | (ax[7] & sx), j[g][0] | (!ax[7] & sx) };
            if (rst) begin
                vx[g] <= 8'h80; vy[g] <= 8'h80;
            end else if (ms_ev && ms_sel[g]) begin
                vx[g] <= step(vx[g], $signed({ {2{ms[4]}}, ms[15:8] }));
                vy[g] <= step(vy[g], -$signed({ {2{ms[5]}}, ms[23:16] }));
            end else begin
                if (dir[1:0] != 2'b00) begin
                    if (frame) vx[g] <= step(vx[g], dir[0] ? 10'sd2 : -10'sd2);
                end else if (lx) vx[g] <= ax ^ 8'h80;
                if (dir[3:2] != 2'b00) begin
                    if (frame) vy[g] <= step(vy[g], dir[2] ? 10'sd2 : -10'sd2);
                end else if (ly) vy[g] <= ay ^ 8'h80;
            end
        end
    end

    always @(posedge clk) begin
        trig <= { j[1][4] | (ms_sel[1] & ms[0]), j[0][4] | (ms_sel[0] & ms[0]) };
        pump <= { j[1][5] | (ms_sel[1] & ms[1]), j[0][5] | (ms_sel[0] & ms[1]) };
    end

    // the ports
    wire [7:0] vx0 = vx[0], vx1 = vx[1], vy0 = vy[0], vy1 = vy[1];
    reg [15:0] mx0, mx1, my0, my1;
    always @(posedge clk) begin
        mx0 <= {8'd0, vx0} * 16'd161; mx1 <= {8'd0, vx1} * 16'd161;
        my0 <= {8'd0, vy0} * 16'd241; my1 <= {8'd0, vy1} * 16'd241;
        gun1 <= { 8'h08 + my0[15:8], 8'h25 + mx0[15:8] };
        gun2 <= { 8'h08 + my1[15:8], 8'h25 + mx1[15:8] };
    end

    // ---------------------------------------------------------- the crosshair
    // the picture's dot / line counters, from the stream's blanks
    reg  [8:0] hc, vc;
    reg        hbl_l, act_l;
    always @(posedge clk) if (ce) begin
        hbl_l <= hblank;
        if (vblank) vc <= 9'd0;
        else if (hblank && !hbl_l && act_l) vc <= vc + 9'd1;            // the end of a picture line
        hc <= hblank ? 9'd0 : hc + 9'd1;
        act_l <= !hblank && !vblank;
    end

    // v / 256 of the picture
    reg  [8:0] cx0, cy0, cx1, cy1;
    always @(posedge clk) begin
        cx0 <= 9'(({9'd0, vx0} * 17'd320) >> 8); cy0 <= 9'(({9'd0, vy0} * 17'd240) >> 8);
        cx1 <= 9'(({9'd0, vx1} * 17'd320) >> 8); cy1 <= 9'(({9'd0, vy1} * 17'd240) >> 8);
    end

    function on_cross(input [8:0] x, input [8:0] y, input [8:0] cx, input [8:0] cy);
        reg [8:0] dx, dy;
        begin
            dx = x >= cx ? x - cx : cx - x;
            dy = y >= cy ? y - cy : cy - y;
            on_cross = (dx == 9'd0 && dy <= 9'd6 && dy >= 9'd2) || (dy == 9'd0 && dx <= 9'd6 && dx >= 9'd2);
        end
    endfunction

    wire c0 = show[0] && on_cross(hc, vc, cx0, cy0);
    wire c1 = show[1] && on_cross(hc, vc, cx1, cy1);
    always @* begin
        rgb_out = rgb_in;
        if (!hblank && !vblank) begin
            if (c0) rgb_out = 24'hff2020;
            else if (c1) rgb_out = 24'h20ff20;
        end
    end

    initial begin
        vx[0] = 8'h80; vx[1] = 8'h80; vy[0] = 8'h80; vy[1] = 8'h80;
        hc = 9'd0; vc = 9'd0; hbl_l = 1'b0; act_l = 1'b0; trig = 2'b00; pump = 2'b00;
    end
endmodule
`default_nettype wire
