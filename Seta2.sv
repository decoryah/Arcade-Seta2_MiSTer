//============================================================================
//
//  Seta "newer hardware" (TMP68301 + X1-020 / DX-101 + X1-010, 1994-2000) -- MAME's seta/seta2.cpp -- for MiSTer:
//  Guardians / Denjin Makai II, Mobile Suit Gundam EX Revue, Penguin Brothers / A-Blast, Puzzle De Bowling, Kosodate Quiz My Angel
//  1 and 2, Wakakusamonogatari Mahjong Yonshimai.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/seta/seta2.cpp) and devices (src/devices/video/x1_020_dx_101.cpp,
//  src/devices/cpu/m68000/tmp68301.cpp, src/devices/sound/x1_010.cpp, src/devices/machine/eepromser.cpp).
//  The 68000 is fx68k (Jorge Cwik); the X1-010 is ppriest's x1_010.sv (Arcade-Seta_MiSTer); the platform layer follows the owner's
//  other cores (crospang-mister, ohmygod-mister, metro-mister).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
reg          grd_game = 1'b0, gx_game = 1'b0;      // Guardians (any board) / Gundam EX is loaded: their CPU speed options (OSD)
reg          gun_game = 1'b0;                      // a light-gun game (Sammy's board, map 7) is loaded: its gun options (OSD)
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale (as the owner's other cores: video_freak's SCALE counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer,
// 3 HV-Integer+, 4 HV-Integer)
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;
	3'd2:    scale_sel = 3'd4;
	3'd3:    scale_sel = 3'd2;
	3'd4:    scale_sel = 3'd3;
	default: scale_sel = 3'd0;
endcase
wire  [1:0] ar     = status[122:121];
wire        fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx    = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : {10'd0, ar - 2'd1};
wire [11:0] ary    = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.SETA2;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[14],CRT Adjust,Off,On;",
	"H1P1O[19:15],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[27:21],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[40:36],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"H4O[46:45],Crosshair,Off,P1,P2,P1+P2;",
	"H4O[48:47],P1 stick,Auto,Aim,D-pad;",
	"H4O[50:49],P2 stick,Auto,Aim,D-pad;",
	"H4O[52:51],Mouse aims,P1,P2,Off;",
	"H4O[53],Autosave NVRAM,On,Off;",
	"H4T[54],Save NVRAM;",
	"H4-;",
	"DIP;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,-18 dB;",
	"O[12],Pause,Off,On;",
	"H2O[42],Turbo CPU (23.4 MHz),Off,On;",
	"H3O[44:43],CPU speed,Native 16.27 MHz,Turbo 20.33 MHz,Turbo 22.36 MHz;",
	"O[13],Sync widths,Standard,Board;",
	"O[20],SDRAM read capture,Normal,Late;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin;",
	"jn,A,B,X,Y,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

// Three builds (Quartus revisions, rtl/pll/pll_0002.v): the machine clock is a whole multiple of the board's dot clock, so the dots
// are a fixed number of machine clocks (a direct video output, e.g. a RetroTINK 4K's DV1, needs that):
//   Seta2     (seta2)     gundamex, mj4simai, myangel, myangel2, pzlbowl: 32.53047 MHz / 4 x 11 = 89.4588 MHz, 11 clocks per dot
//   Seta2Grd  (seta2grd)  grdians, grdiansa, grdiansbl:                  50 MHz / 8 x 15         = 93.75 MHz,   15 clocks per dot
//   Seta2Pen  (seta2pen)  penbros, ablast:                               28 MHz / 4 x 13         = 91 MHz,      13 clocks per dot
`ifdef SETA2_GRD
localparam [31:0] CLK_HZ = 32'd93_750_000;
localparam int   DOT_DIV = 15;
`elsif SETA2_PEN
localparam [31:0] CLK_HZ = 32'd91_000_000;
localparam int   DOT_DIV = 13;
`else
localparam [31:0] CLK_HZ = 32'd89_458_793;
localparam int   DOT_DIV = 11;
`endif

wire clk_sys;           // the machine (enables for the CPU, the X1-010 and the dots)
wire clk_sdram;         // the same, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_upload;
wire   [7:0] ioctl_din;
localparam [7:0] NV_INDEX = 8'd4;     // the light-gun games' battery RAM file: the MRA's <nvram index="4" size="8192"/> (below)
wire         nv_req;
wire         ioctl_wait;

wire  [31:0] joystick_0, joystick_1;
wire  [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({11'd0, ~gun_game, ~gx_game, ~grd_game, ~status[14], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_req),
	.ioctl_upload_index(NV_INDEX),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
);

///////////////////////   DIP SWITCHES (from the MRA)   ///////////////////////

// ioctl index 254: byte 0 = DSW1 (MAME's port bits 7:0), byte 1 = DSW2, byte 2 = board jumpers (gundamex: bit 0 Language,
// 1 = English); a 1 is "off" (active low)
reg [7:0] sw[3];
initial begin sw[0] = 8'hFF; sw[1] = 8'hFF; sw[2] = 8'hFF; end
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && (ioctl_addr[26:2] == 25'd0) && (ioctl_addr[1:0] != 2'd3)) sw[ioctl_addr[1:0]] <= ioctl_dout;
end

///////////////////////   CONFIGURATION (the image's header)   ///////////////////////

wire [7:0] cfg[64];
// header bytes (tools/make_mra.py):
//   0 'S'  1 '2'  2 map  3 flags (bit 0: 32.53 MHz / 2 CPU, bit 1: EEPROM, bit 2: myangel inputs, bit 3: mahjong inputs,
//   bit 4: pzlbowl SYSTEM, bit 5: gundamex SYSTEM / IN0 / IN1, bit 6: no button 3)
//   4..6 dot_inc   8/9 h_total  10/11 h_sync  12/13 h_start  14/15 h_width  16/17 v_total  18/19 v_sync  20/21 v_start
//   22/23 v_height  24..26 tile_mask  28..30 tile_count  32 sample pages - 1  (16-bit values little-endian)
wire  [2:0] cfg_map    = cfg[2][2:0];
wire  [7:0] cfg_flags  = cfg[3];
wire [23:0] dot_inc    = {cfg[6], cfg[5], cfg[4]};

// The CRT timing: the header's (the CRTC values the game programs, but Guardians' and Penguin Brothers' totals: 262 lines, see
// tools/seta2_cfg.py RASTER), or the build's boards' while no image is loaded (the header starts "S2"), so that the picture -- and
// the OSD with Main_MiSTer's messages, e.g. a missing zip -- is always there.
// Sync widths (OSD): "Standard" caps the H sync at ~4.7 us and the V sync at 3 lines, their leading edges where the game has them;
// "Board": as programmed (Guardians 7.5 us and 4 lines, Penguin Brothers 9.1 us: too long for some TVs -- a dark picture, unsteady
// lines).
`ifdef SETA2_GRD
localparam [9:0] D_HTOT = 10'd409, D_HSYNC = 10'd46, D_HSTART = 10'd89,  HS_CAP = 10'd28;   // 6.25 MHz: 29 dots = 4.64 us
localparam [8:0] D_HWID = 9'd304,  D_VTOT  = 9'd262, D_VSYNC  = 9'd3,    D_VSTART = 9'd20, D_VHGT = 9'd232;
`elsif SETA2_PEN
localparam [9:0] D_HTOT = 10'd445, D_HSYNC = 10'd63, D_HSTART = 10'd101, HS_CAP = 10'd32;   // 7 MHz: 33 dots = 4.71 us
localparam [8:0] D_HWID = 9'd320,  D_VTOT  = 9'd262, D_VSYNC  = 9'd3,    D_VSTART = 9'd15, D_VHGT = 9'd224;
`else
localparam [9:0] D_HTOT = 10'd517, D_HSYNC = 10'd32, D_HSTART = 10'd88,  HS_CAP = 10'd37;   // 8.13 MHz: 38 dots = 4.67 us
localparam [8:0] D_HWID = 9'd384,  D_VTOT  = 9'd262, D_VSYNC  = 9'd1,    D_VSTART = 9'd15, D_VHGT = 9'd240;
`endif
wire        hdr_ok     = (cfg[0] == 8'h53) && (cfg[1] == 8'h32);

// Turbo CPU (Guardians) / CPU speed (Gundam EX), after the Guardians and Gundam EX MiSTer cores: the 68000 alone runs faster, the
// X1-010, the TMP68301 timers and the video keep the board's rates (rtl/s2_cen.sv).  The most is a quarter of the machine clock
// (Seta2.sdc gives fx68k's paths two clocks): 23.44 MHz in Guardians' core file, 22.36 MHz in Gundam EX's; +25 % is 20.33 MHz.
reg   [1:0] turbo = 2'd0;
always @(posedge clk_sys) begin
	grd_game <= hdr_ok && (cfg_map == 3'd0);
	gx_game  <= hdr_ok && (cfg_map == 3'd1);
	gun_game <= hdr_ok && (cfg_map == 3'd7);
	turbo    <= grd_game ? {status[42], 1'b0} : gx_game ? ((status[44:43] == 2'd3) ? 2'd2 : status[44:43]) : 2'd0;
end
wire  [9:0] h_total    = hdr_ok ? {cfg[9][1:0],  cfg[8]}  : D_HTOT;
wire  [9:0] h_sync_g   = hdr_ok ? {cfg[11][1:0], cfg[10]} : D_HSYNC;
wire  [9:0] h_start    = hdr_ok ? {cfg[13][1:0], cfg[12]} : D_HSTART;
wire  [8:0] h_width    = hdr_ok ? {cfg[15][0],   cfg[14]} : D_HWID;
wire  [8:0] v_total    = hdr_ok ? {cfg[17][0],   cfg[16]} : D_VTOT;
wire  [8:0] v_sync_g   = hdr_ok ? {cfg[19][0],   cfg[18]} : D_VSYNC;
wire  [8:0] v_start    = hdr_ok ? {cfg[21][0],   cfg[20]} : D_VSTART;
wire  [8:0] v_height   = hdr_ok ? {cfg[23][0],   cfg[22]} : D_VHGT;
wire  [9:0] h_sync     = (status[13] || h_sync_g <= HS_CAP) ? h_sync_g : HS_CAP;
wire  [8:0] v_sync     = (status[13] || v_sync_g <= 9'd2)   ? v_sync_g : 9'd2;
wire [18:0] tile_mask  = {cfg[26][2:0], cfg[25], cfg[24]};
wire [19:0] tile_count = {cfg[30][3:0], cfg[29], cfg[28]};
wire  [4:0] snd_pages  = cfg[32][4:0];

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 / 6 coin, 9 service (MAME's defaults); the mahjong keys (MAME's defaults: A-N, Kan LCtrl, Pon LAlt,
// Chi Space, Reach LShift, Ron Z, Bet 2, Flip Flop Y, Last Chance RAlt, Take Score RCtrl, Double Up RShift, Big Enter,
// Small Backspace)
reg k_start1, k_start2, k_coin1, k_coin2, k_svc;
reg [13:0] k_mj;            // A..N
reg k_kan, k_pon, k_chi, k_reach, k_ron, k_bet, k_ff, k_last, k_score, k_dbl, k_big, k_small;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: k_start1 <= ps2_key[9];
			9'h01E: begin k_start2 <= ps2_key[9]; k_bet <= ps2_key[9]; end
			9'h02E: k_coin1  <= ps2_key[9];
			9'h036: k_coin2  <= ps2_key[9];
			9'h046: k_svc    <= ps2_key[9];
			9'h01C: k_mj[0]  <= ps2_key[9];   // A
			9'h032: k_mj[1]  <= ps2_key[9];   // B
			9'h021: k_mj[2]  <= ps2_key[9];   // C
			9'h023: k_mj[3]  <= ps2_key[9];   // D
			9'h024: k_mj[4]  <= ps2_key[9];   // E
			9'h02B: k_mj[5]  <= ps2_key[9];   // F
			9'h034: k_mj[6]  <= ps2_key[9];   // G
			9'h033: k_mj[7]  <= ps2_key[9];   // H
			9'h043: k_mj[8]  <= ps2_key[9];   // I
			9'h03B: k_mj[9]  <= ps2_key[9];   // J
			9'h042: k_mj[10] <= ps2_key[9];   // K
			9'h04B: k_mj[11] <= ps2_key[9];   // L
			9'h03A: k_mj[12] <= ps2_key[9];   // M
			9'h031: k_mj[13] <= ps2_key[9];   // N
			9'h014: k_kan    <= ps2_key[9];
			9'h011: k_pon    <= ps2_key[9];
			9'h029: k_chi    <= ps2_key[9];
			9'h012: k_reach  <= ps2_key[9];
			9'h01A: k_ron    <= ps2_key[9];
			9'h035: k_ff     <= ps2_key[9];
			9'h111: k_last   <= ps2_key[9];
			9'h114: k_score  <= ps2_key[9];
			9'h059: k_dbl    <= ps2_key[9];
			9'h05A: k_big    <= ps2_key[9];
			9'h066: k_small  <= ps2_key[9];
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4..7 buttons 1..4, 8 start, 9 coin (the service coin: the keyboard's 9)
wire j1_r = joystick_0[0], j1_l = joystick_0[1], j1_d = joystick_0[2], j1_u = joystick_0[3];
wire j2_r = joystick_1[0], j2_l = joystick_1[1], j2_d = joystick_1[2], j2_u = joystick_1[3];
wire [3:0] j1_b = joystick_0[7:4], j2_b = joystick_1[7:4];
wire start1 = joystick_0[8] | k_start1, start2 = joystick_1[8] | k_start2;
// coins as MAME's PORT_IMPULSE(5): a press reaches the game as 5 frames however long it is held
wire        dbg_vbl;
wire        coin1_in = joystick_0[9] | k_coin1, coin2_in = joystick_1[9] | k_coin2;
reg   [2:0] coin1_n = 3'd0, coin2_n = 3'd0;
reg         coin1_d, coin2_d, cvbl_d;
always @(posedge clk_sys) begin
	coin1_d <= coin1_in; coin2_d <= coin2_in; cvbl_d <= dbg_vbl;
	if (coin1_in && !coin1_d) coin1_n <= 3'd5; else if (dbg_vbl && !cvbl_d && coin1_n != 3'd0) coin1_n <= coin1_n - 3'd1;
	if (coin2_in && !coin2_d) coin2_n <= 3'd5; else if (dbg_vbl && !cvbl_d && coin2_n != 3'd0) coin2_n <= coin2_n - 3'd1;
end
wire coin1  = coin1_n != 3'd0, coin2 = coin2_n != 3'd0;
wire svc    = k_svc;
wire b3_on  = !cfg_flags[6];

// the driver's ports (active low); bits the driver marks unknown read 1
wire [15:0] in_dsw1 = {8'hff, sw[0]};
wire [15:0] in_dsw2 = {8'hff, sw[1]};
reg  [15:0] in_p1, in_p2, in_sys, in_ex0, in_ex1;
always @* begin
	if (cfg_flags[2]) begin
		// myangel / myangel2: bit 3 B4, 4 B3, 5 B2, 6 B1, 7 start
		in_p1 = {8'hff, ~{start1, j1_b[0], j1_b[1], j1_b[2], j1_b[3]}, 3'b111};
		in_p2 = {8'hff, ~{start2, j2_b[0], j2_b[1], j2_b[2], j2_b[3]}, 3'b111};
	end else begin
		// left, right, up, down, B1, B2, B3, start
		in_p1 = {8'hff, ~{start1, j1_b[2] & b3_on, j1_b[1], j1_b[0], j1_d, j1_u, j1_r, j1_l}};
		in_p2 = {8'hff, ~{start2, j2_b[2] & b3_on, j2_b[1], j2_b[0], j2_d, j2_u, j2_r, j2_l}};
	end
	// SYSTEM: coin 1, coin 2, service 1, test (the test switch is the OSD's Service Mode DIP)
	if (cfg_flags[5])      in_sys = {8'hff, 2'b11, sw[2][0], 2'b11, ~svc, ~coin2, ~coin1};   // gundamex: bit 5 the language jumper
	else if (cfg_flags[4]) in_sys = {8'hff, 1'b0, 3'b111, 1'b1, ~svc, ~coin2, ~coin1};       // pzlbowl: bit 7 custom (random)
	else                   in_sys = {8'hff, 4'b1111, 1'b1, ~svc, ~coin2, ~coin1};
	in_ex0 = {15'h7fff, ~j1_b[3]};                                                       // gundamex IN0 / IN1: button 4
	in_ex1 = {15'h7fff, ~j2_b[3]};
end

// The light-gun games (Sammy's board, map 7): the guns -- the left stick, the d-pad or the mouse aims, button 1 is the trigger,
// button 2 the pump (rtl/s2_guns.sv) -- and the board's ports (rtl/s2_samports.sv), which replace the joystick ports above
wire [15:0] gun1, gun2;
wire  [1:0] gun_trig, gun_pump;
wire [23:0] rgb_core, rgb_gun;
wire [15:0] sp_buttons, sp_trigger, sp_pump, sp_coin, sp_gun1, sp_gun2;
s2_samports u_samports
(
	.layout(cfg[33][1:0]), .start1(start1), .start2(start2), .coin1(coin1), .coin2(coin2), .svc(svc),
	.trig(gun_trig), .pump(gun_pump), .gun1(gun1), .gun2(gun2),
	.p_buttons(sp_buttons), .p_trigger(sp_trigger), .p_pump(sp_pump), .p_coin(sp_coin), .p_gun1(sp_gun1), .p_gun2(sp_gun2)
);

// mj4simai: mahjong_matrix_2p_bet_wup (+ _ff), KEY0..4 player 1, KEY5..9 player 2 (the keyboard plays player 1)
wire [5:0] mj_keys[10];
assign mj_keys[0] = ~{start1, k_kan, k_mj[12], k_mj[8], k_mj[4], k_mj[0]};
assign mj_keys[1] = ~{k_bet, k_reach, k_mj[13], k_mj[9], k_mj[5], k_mj[1]};
assign mj_keys[2] = ~{1'b0, k_ron, k_chi, k_mj[10], k_mj[6], k_mj[2]};
assign mj_keys[3] = ~{1'b0, k_ff, k_pon, k_mj[11], k_mj[7], k_mj[3]};
assign mj_keys[4] = ~{k_small, k_big, 1'b0, k_dbl, k_score, k_last};
assign mj_keys[5] = ~{start2, 5'd0};
assign mj_keys[6] = 6'h3f;
assign mj_keys[7] = 6'h3f;
assign mj_keys[8] = 6'h3f;
assign mj_keys[9] = 6'h3f;

///////////////////////   MEMORY   ///////////////////////

wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        mem_init = ~pll_locked | RESET;
wire        mem_ready, dl_busy, dl_wait, fl_busy;

// Fast load (as the owner's Cross Pang core): with address= on the MRA's index-0 <rom>, Main_MiSTer copies the image into the DDR3
// and sends a download without data that starts with ioctl_addr = the image's length; s2_mem then reads the header and copies the
// graphics into the SDRAM.  An older Main_MiSTer sends the image the ordinary way.
reg         rom_dl_d = 1'b0;
reg         fast_dl  = 1'b0;
reg  [26:0] fast_len;
always @(posedge clk_sys) begin
	rom_dl_d <= rom_dl;
	if (rom_dl && !rom_dl_d) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr; end
	else if (!fl_busy && !rom_dl && fl_seen) fast_dl <= 1'b0;
end
wire fl_go = fast_dl && rom_dl_d && !rom_dl;
reg  fl_seen;
always @(posedge clk_sys) begin
	if (fl_go) fl_seen <= 1'b1;
	else if (!fast_dl) fl_seen <= 1'b0;
end
assign ioctl_wait = dl_wait;

wire        gf_req, gf_ready, gf_valid;
wire [21:0] gf_addr;
wire [63:0] gf_data;
wire        pf_req, pf_wr, pf_done;
wire [21:5] pf_addr;
wire  [1:0] pf_idx;
wire [63:0] pf_data;
wire        sr_req, sr_we, sr_ack;
wire [18:1] sr_addr;
wire [15:0] sr_din, sr_dout;
wire  [1:0] sr_be;
wire        sn_req, sn_ack;
wire [21:0] sn_addr;
wire [63:0] sn_data;
wire  [6:0] ee_raddr;
wire  [7:0] ee_q;

// the download's bytes, registered (timing)
reg        dl_we_r;
reg [26:0] dl_addr_r;
reg  [7:0] dl_data_r;
always @(posedge clk_sys) begin
	dl_we_r   <= rom_dl && ioctl_wr && !fast_dl;
	dl_addr_r <= ioctl_addr;
	dl_data_r <= ioctl_dout;
end

s2_mem #(.CLK_HZ(CLK_HZ)) u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .rd_late(status[20]), .ready(mem_ready),
	.dl_we(dl_we_r), .dl_addr(dl_addr_r), .dl_data(dl_data_r), .dl_wait(dl_wait), .dl_busy(dl_busy),
	.fl_go(fl_go), .fl_len(fast_len), .fl_busy(fl_busy), .cfg(cfg),
	.ee_addr(ee_raddr), .ee_q(ee_q),
	.gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
	.pf_req(pf_req), .pf_addr(pf_addr), .pf_wr(pf_wr), .pf_idx(pf_idx), .pf_data(pf_data), .pf_done(pf_done),
	.sr_req(sr_req), .sr_we(sr_we), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be), .sr_ack(sr_ack), .sr_dout(sr_dout),
	.sn_req(sn_req), .sn_addr(sn_addr), .sn_ack(sn_ack), .sn_data(sn_data),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   THE MACHINE   ///////////////////////

wire reset_sw = RESET | status[0] | buttons[1];
wire loading  = rom_dl | fast_dl | dl_busy | fl_busy | ~mem_ready;
wire ee_busy;
reg  mc_rst = 1'b1;
wire        nv_dl;
always @(posedge clk_sys) mc_rst <= reset_sw | loading | nv_dl | ee_busy | ~pll_locked;

// the light-gun games' battery RAM to and from the SD card (rtl/s2_nvram.sv)
wire [12:0] nv_b_addr;
wire        nv_b_we;
wire  [7:0] nv_b_din, nv_b_q;
wire        nv_written;
s2_nvram #(.INDEX(NV_INDEX)) u_nvram (
	.clk(clk_sys), .gun_game(gun_game), .rom_dl(rom_dl),
	.ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index[7:0]),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_din(ioctl_din), .nv_req(nv_req), .nv_dl(nv_dl),
	.osd(OSD_STATUS), .autosave_off(status[53]), .save(status[54]),
	.nv_b_addr(nv_b_addr), .nv_b_we(nv_b_we), .nv_b_din(nv_b_din), .nv_b_q(nv_b_q), .nv_written(nv_written)
);

// the EEPROM image from the header into the 93C46 (64 big-endian words): copied once the download has finished, the machine held
// in reset meanwhile; a plain reset keeps what the game has written since
reg  [7:0] ee_cnt = 8'd130;
reg        ee_we;
reg  [5:0] ee_wa;
reg [15:0] ee_wd;
reg  [7:0] ee_hi;
assign ee_raddr = ee_cnt[6:0];
assign ee_busy  = ee_cnt != 8'd130;
always @(posedge clk_sys) begin
	ee_we <= 1'b0;
	if (loading) ee_cnt <= 8'd0;
	else if (ee_busy) begin
		ee_cnt <= ee_cnt + 8'd1;
		// ee_q follows ee_raddr a clock later: byte ee_cnt - 1
		if (ee_cnt != 8'd0) begin
			if (!ee_cnt[0]) begin ee_we <= 1'b1; ee_wa <= ee_cnt[6:1] - 6'd1; ee_wd <= {ee_hi, ee_q}; end
			else ee_hi <= ee_q;
		end
	end
end

wire        ce_pix, hblank, vblank, hsync, vsync;
wire  [7:0] r, g, b;
wire signed [15:0] audio;
wire        dbg_overrun, cpu_halted;

s2_core #(.CLK_HZ(CLK_HZ), .DOT_DIV(DOT_DIV)) u_core
(
	.clk(clk_sys), .rst(mc_rst), .pause(status[12]), .turbo(turbo),
	.cfg_map(cfg_map), .cfg_alt_clk(cfg_flags[0]), .cfg_eeprom(cfg_flags[1]), .cfg_snd_pages(snd_pages),
	.dot_inc(dot_inc), .h_total(h_total), .h_sync(h_sync), .h_start(h_start), .h_width(h_width),
	.v_total(v_total), .v_sync(v_sync), .v_start(v_start), .v_height(v_height), .rdly(10'd144),
	.tile_mask(tile_mask), .tile_count(tile_count), .cache_inval(rom_dl | fast_dl | mem_init),
	.in_p1(gun_game ? sp_buttons : in_p1), .in_p2(gun_game ? sp_trigger : in_p2), .in_sys(gun_game ? sp_coin : in_sys), .in_dsw1(in_dsw1), .in_dsw2(in_dsw2), .in_ex0(gun_game ? sp_gun1 : in_ex0), .in_ex1(gun_game ? sp_gun2 : in_ex1), .in_ex2(sp_pump),
	.nv_b_addr(nv_b_addr), .nv_b_we(nv_b_we), .nv_b_din(nv_b_din), .nv_b_q(nv_b_q), .nv_written(nv_written),
	.mj_keys(mj_keys),
	.ee_init_we(ee_we), .ee_init_addr(ee_wa), .ee_init_data(ee_wd),
	.gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
	.pf_req(pf_req), .pf_addr(pf_addr), .pf_wr(pf_wr), .pf_idx(pf_idx), .pf_data(pf_data), .pf_done(pf_done),
	.sr_req(sr_req), .sr_we(sr_we), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be), .sr_ack(sr_ack), .sr_dout(sr_dout),
	.sn_req(sn_req), .sn_addr(sn_addr), .sn_ack(sn_ack), .sn_data(sn_data),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.audio(audio),
	.dbg_overrun(dbg_overrun), .dbg_vbl(dbg_vbl), .cpu_halted(cpu_halted)
);

///////////////////////   AUDIO   ///////////////////////

// MAME: the X1-010's two outputs into the mono speaker at 1.0 (s2_core); "Normal" is that level
wire signed [15:0] aud = audio >>> status[9:8];
assign AUDIO_L = aud;
assign AUDIO_R = aud;

///////////////////////   VIDEO   ///////////////////////

s2_guns u_guns
(
	.clk(clk_sys), .rst(mc_rst | ~gun_game),
	.joy0(joystick_0), .joy1(joystick_1), .ana0(joystick_l_analog_0), .ana1(joystick_l_analog_1), .mouse(ps2_mouse),
	.mode0(status[48:47]), .mode1(status[50:49]), .ms_who(status[52:51]),
	.gun1(gun1), .gun2(gun2), .trig(gun_trig), .pump(gun_pump),
	.show(gun_game ? status[46:45] : 2'b00), .ce(ce_pix), .hblank(hblank), .vblank(vblank), .rgb_in(rgb_core), .rgb_out(rgb_gun)
);
assign      rgb_core = (mc_rst || !hdr_ok) ? 24'd0 : {r, g, b};
wire [23:0] rgb_in = rgb_gun;                     // the light guns' crosshairs drawn in (OSD "Crosshair"), else the picture as it is
wire        vga_de_mix;

// CRT Adjust (OSD page of the same name): H-Size, H-Position and V-Shift of the picture on a 15 kHz analog output, through rmonic79's line buffer
// (rtl/s2_crtadj.sv, modules/crt_adjust).  The sync pulses keep their rate, so the monitor stays locked.  It does nothing while the scandoubler is in use
// (Scandoubler Fx or MiSTer.ini's forced_scandoubler); the HDMI picture follows it too, so it is for the analog output (leave it Off for HDMI / direct video).
wire        ca_on = status[14] & ~((|status[5:3]) | forced_scandoubler);
wire        ca_ce, ca_hblank, ca_vblank, ca_hs, ca_vs;
wire [23:0] ca_rgb;
s2_crtadj #(.DOT_DIV(DOT_DIV), .VTOTAL(262)) u_crtadj
(
	.clk(clk_sys), .i_on(ca_on), .i_hsize_f(status[19:15]), .i_hpos_f(status[27:21]), .i_vshift_f(status[40:36]),
	.i_hstart(h_start), .i_hwidth(h_width), .i_vtotal(v_total),
	.i_ce(ce_pix), .i_hblank(hblank), .i_vblank(vblank), .i_hs(hsync), .i_vs(vsync), .i_rgb(rgb_in),
	.o_ce(ca_ce), .o_hblank(ca_hblank), .o_vblank(ca_vblank), .o_hs(ca_hs), .o_vs(ca_vs), .o_rgb(ca_rgb)
);

arcade_video #(.WIDTH(384), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ca_ce),
	.RGB_in(ca_rgb),
	.HBlank(ca_hblank),
	.VBlank(ca_vblank),
	.HSync(ca_hs),
	.VSync(ca_vs),
	.fx(status[5:3]),
	.VGA_DE(vga_de_mix)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_mix),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while the machine is held (a ROM loading), blinks once per frame while it runs, fast once a line was late
reg        led_vbl, led_ovr, vbl_d;
reg [23:0] led_cnt;
always @(posedge clk_sys) begin
	led_cnt <= led_cnt + 24'd1;
	vbl_d <= dbg_vbl;
	if (dbg_vbl && !vbl_d) led_vbl <= ~led_vbl;
	if (mc_rst) led_ovr <= 1'b0;
	else if (dbg_overrun) led_ovr <= 1'b1;
end
assign LED_USER = mc_rst ? 1'b1 : led_ovr ? led_cnt[22] : led_vbl;

endmodule
