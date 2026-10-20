// Allumer X1-020 / NEC DX-101 line renderer (seta2.cpp): draws one line of the sprite list into a line buffer.
//
// Written from MAME 0.289's src/devices/video/x1_020_dx_101.cpp (draw_sprites_line, drawgfx_line, draw_pixel, get_tile), whose
// executable copy is tools/seta2_ref.py (pixel-exact against MAME on the captured frames). Every expression below names the line of
// that code it implements; the arithmetic widths are chosen so that the results equal C's int / uint32 results for every value the
// registers and the sprite RAM can hold.
//
// Pipeline, in order (the order of the list is the drawing order: later entries on top):
//
//   walker     reads the private list (the copy made at register 0x26) entry by entry and the sub-sprites of each entry from the
//              sprite RAM (64-bit port: one sub-sprite per read)
//   ytest      MAME's "does the sprite cover this scanline" test; a covered sub-sprite becomes one command: a row of 1..8 tiles of a
//              "normal" sprite, or the window of a "floating tilemap" on this line
//   expander   turns a command into tile rows (code, line of the tile, screen position): sprite rows directly; tilemap windows column
//              by column, reading each column's tile from the sprite RAM (priority over the walker on the shared read port). Rows
//              without a visible pixel are dropped here (MAME draws and clips them; the picture is the same)
//   fetch      the 8 bytes of the tile row from the graphics ROM (SDRAM; in order)
//   drawer     8 pixels per clock into an 8-bank line buffer at zoom 1 (one bank per x mod 8); one pixel per clock when zoomed
//              (MAME's two loops of drawgfx_line), and read-modify-write for shadow sprites
//
// The line buffer holds two lines (`lb_sel` picks the one drawn; the display reads the other through dsp_* and clears each pixel
// after reading it, so a line starts clear = pen 0, MAME's bitmap.fill(palette().pen(0))).
`default_nettype none

module s2_render (
    input  logic        clk,
    input  logic        rst,

    // line control
    input  logic        start,              // pulse: draw the line below into buffer lb_sel
    input  logic        blank,              // with start: only clear the line (the screen is blanked: pen 0)
    input  logic        lb_sel,
    input  logic  [8:0] realscanline,       // y (0 .. height-1)
    input  logic signed [10:0] scanline,    // MAME's yy: the line after the global y zoom / offset
    input  logic signed [10:0] xoff_int,    // xoffset >> 16 (the global x offset, whole pixels)
    input  logic [31:0] xzoom,              // MAME's inc2 = 2^32 / the zoom register (0x10000 = 1)
    input  logic  [8:0] width,              // visible width: pixels 0 .. width-1 are drawn
    input  logic [18:0] tile_mask,          // the graphics ROM's tiles: code % elements = (code & mask) - (>= count ? count : 0)
    input  logic [19:0] tile_count,
    output logic        busy,
    output logic        done,               // pulse: the line is complete

    // private display list (512 entries x {sprite, yoffs, xoffs, num}), read 1 clock after the address
    output logic  [8:0] pl_addr,
    input  logic [63:0] pl_q,

    // sprite RAM (32 K x 64: word 4a+k in bits 16k+15..16k), read 3 clocks after the address
    output logic [14:0] sr_addr,
    input  logic [63:0] sr_q,

    // graphics ROM tile rows: 8-byte units (byte q of a row = bit plane q), in order
    output logic        gf_req,
    output logic [21:0] gf_addr,            // unit address = (tile code % elements) * 8 + row
    input  logic        gf_ready,           // the request is taken this clock
    input  logic        gf_valid,           // a row arrives
    input  logic [63:0] gf_data,

    // display side of the line buffer: read pixel dsp_x of buffer dsp_sel (2 clocks), cleared behind the read
    input  logic        dsp_rd,
    input  logic        dsp_sel,
    input  logic  [8:0] dsp_x,
    output logic [14:0] dsp_q,

    // statistics for the bench
    output logic [15:0] st_rows,            // tile rows drawn on this line
    output logic [15:0] st_cycles           // clocks from start to done
);

    // ================================================================== the line's parameters (latched at start)
    logic        lsel;
    logic  [8:0] ry;                         // realscanline
    logic signed [10:0] yy;                  // scanline
    logic signed [10:0] xo;                  // xoff_int
    logic [31:0] xz;                         // xzoom (inc2)
    logic  [8:0] wid;
    always_ff @(posedge clk) if (start) begin
        lsel <= lb_sel; ry <= realscanline; yy <= scanline; xo <= xoff_int; xz <= xzoom; wid <= width;
    end

    // ================================================================== walker
    // State: the list entry e (pl_addr), then its sub-sprites k = 0 .. num.  The private list read takes one clock; entries are read
    // ahead (pl_addr is the next entry while the current one's sub-sprites go out).
    typedef enum logic [2:0] { W_IDLE, W_E0, W_E1, W_SUB, W_DONE } wst_t;
    wst_t        wst;
    logic  [8:0] e;                          // entry being read
    // the current entry
    logic        en_last;                    // num bit 15: the end marker
    logic        en_nozoom, en_opaque, en_gsize, en_shadow, en_tmap;
    logic  [2:0] en_gfx;
    logic  [5:0] en_gsx, en_gsy;             // global sizes (xoffs / yoffs bits 15..10)
    logic  [9:0] en_xoffs;                   // xoffs & 0x3ff
    logic signed [10:0] en_yoffs;            // yoffs & 0x3ff, sign-extended at 0x200
    logic [14:0] en_ptr;                     // sprite & 0x7fff: the sub-sprites' first 64-bit word
    logic  [8:0] en_n;                       // (num & 0xff) + 1
    logic  [8:0] k;                          // sub-sprite index

    // sprite RAM port: the expander's column reads win; the walker's go when the port is free
    logic        ex_sr_req;                  // expander wants the port this clock
    logic [14:0] ex_sr_addr;
    logic        wk_issue;                   // the walker reads a sub-sprite this clock
    logic        cmd_full;                   // the command FIFO cannot take the reads in flight

    wire  [63:0] e_q = pl_q;
    wire         e_valid_ptr = (e_q[62:48] < 15'h0600);          // (sprite & 0x7fff) < 0x3000 / 2 / 4

    always_comb begin
        wk_issue = (wst == W_SUB) && !ex_sr_req && !cmd_full;
        sr_addr  = ex_sr_req ? ex_sr_addr : (en_ptr + {6'd0, k});
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wst <= W_IDLE;
        end else begin
            case (wst)
                W_IDLE: if (start) begin e <= 9'd0; pl_addr <= 9'd0; wst <= blank ? W_DONE : W_E0; end
                W_E0: wst <= W_E1;                               // pl_q follows pl_addr a clock later
                W_E1: begin
                    // latch entry e (pl_q): num = w0, xoffs = w1, yoffs = w2, sprite = w3
                    en_last   <= e_q[15];
                    en_nozoom <= e_q[14];
                    en_opaque <= e_q[13];
                    en_gsize  <= e_q[12];
                    en_shadow <= e_q[11] & ~e_q[14];             // nozoom: use_shadow = false
                    en_gfx    <= e_q[10:8];
                    en_n      <= {1'b0, e_q[7:0]} + 9'd1;
                    en_gsx    <= e_q[31:26];
                    en_xoffs  <= e_q[25:16];
                    en_gsy    <= e_q[47:42];
                    en_yoffs  <= {e_q[41], e_q[41:32]};          // 10 bits, signed at 0x200
                    en_tmap   <= e_q[63];
                    en_ptr    <= e_q[62:48];
                    k         <= 9'd0;
                    if (e_valid_ptr) wst <= W_SUB;
                    else if (e_q[15] || e == 9'd511) wst <= W_DONE;
                    else begin e <= e + 9'd1; pl_addr <= e + 9'd1; wst <= W_E0; end
                end
                W_SUB: if (wk_issue) begin
                    // MAME: `if (s2 >= end) break;` -- s2 < 0x600 * 4 + 256 * 4 words here, never at the end of the sprite RAM
                    k <= k + 9'd1;
                    if (k + 9'd1 == en_n) begin
                        if (en_last || e == 9'd511) wst <= W_DONE;
                        else begin e <= e + 9'd1; pl_addr <= e + 9'd1; wst <= W_E0; end
                    end
                end
                W_DONE: if (start) begin e <= 9'd0; pl_addr <= 9'd0; wst <= blank ? W_DONE : W_E0; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // the entry's parameters travel with each read (the entry may change before the data returns)
    typedef struct packed {
        logic        nozoom, opaque, gsize, shadow, tmap;
        logic [2:0]  gfx;
        logic [5:0]  gsx, gsy;
        logic [9:0]  xoffs;
        logic signed [10:0] yoffs;
    } ent_t;
    ent_t ent_now, ent_d1, ent_d2, ent_d3;
    logic v_d1, v_d2, v_d3;
    always_comb begin
        ent_now = '{nozoom: en_nozoom, opaque: en_opaque, gsize: en_gsize, shadow: en_shadow, tmap: en_tmap, gfx: en_gfx,
                    gsx: en_gsx, gsy: en_gsy, xoffs: en_xoffs, yoffs: en_yoffs};
    end
    always_ff @(posedge clk) begin
        v_d1 <= wk_issue && !rst; ent_d1 <= ent_now;
        v_d2 <= v_d1 && !rst;     ent_d2 <= ent_d1;
        v_d3 <= v_d2 && !rst;     ent_d3 <= ent_d2;
    end

    // ================================================================== ytest (sub-sprite in sr_q, entry in ent_d3)
    // usedscanline: realscanline for "nozoom" entries, else the zoomed line
    wire  [15:0] w0 = sr_q[15:0], w1 = sr_q[31:16], w2 = sr_q[47:32], w3 = sr_q[63:48];
    wire signed [11:0] L = ent_d3.nozoom ? $signed({3'd0, ry}) : {yy[10], yy};
    wire signed [10:0] gyoff = ent_d3.nozoom ? -11'sd144 : 11'sd0;       // -0x90
    wire        [7:0]  gxoff = ent_d3.nozoom ? 8'h80 : 8'h00;

    // --- floating tilemap
    //   sy = s2[1] & 0x3ff; sy += global_yoffset; sy &= 0x3ff; if (sy & 0x200) sy -= 0x400;
    wire        [9:0]  t_sy10 = w1[9:0] + gyoff[9:0];
    wire signed [10:0] t_sy   = {t_sy10[9], t_sy10};
    //   height = ((global or local size & 0xfc00) >> 10) + 1
    wire        [6:0]  t_h    = {1'b0, (ent_d3.gsize ? ent_d3.gsy : w1[15:10])} + 7'd1;
    //   firstline = (sy + yoffs) & 0x3ff; sign at 0x200
    wire        [9:0]  t_fl10 = t_sy[9:0] + ent_d3.yoffs[9:0];
    wire signed [12:0] t_fl   = {{3{t_fl10[9]}}, t_fl10};
    //   endline = firstline + height * 0x10 - 1;  if (endline & 0x200) endline -= 0x400;   (on the whole int: firstline in
    //   -512..511, so endline in -497..1534 before the correction; 13 bits hold it and the result)
    wire signed [12:0] t_el0  = t_fl + $signed({2'd0, t_h, 4'd0}) - 13'sd1;
    wire signed [12:0] t_el   = t_el0[9] ? (t_el0 - 13'sd1024) : t_el0;
    wire signed [12:0] Lw     = {L[11], L};
    wire        t_cover = (t_el >= t_fl) ? !(t_fl > Lw || t_el < Lw) : !(Lw > t_el && Lw < t_fl);
    //   sx = s2[0] & 0x3ff; sx -= global_xoffset;  width = (size & 0xfc00) >> 10
    wire signed [11:0] t_sx   = $signed({2'd0, w0[9:0]}) - $signed({4'd0, gxoff});
    wire        [5:0]  t_w    = ent_d3.gsize ? ent_d3.gsx : w0[15:10];
    //   firstcolumn = sx + xoffs; firstcolumn = (firstcolumn & 0x1ff) - (firstcolumn & 0x200);  lastcolumn = fc + width * 16 - 1
    wire        [9:0]  t_fc10 = t_sx[9:0] + ent_d3.xoffs;
    wire signed [10:0] t_fc   = {t_fc10[9], t_fc10};
    wire signed [11:0] t_lc   = {t_fc[10], t_fc} + $signed({2'd0, t_w, 4'd0}) - 12'sd1;
    // (concatenations are unsigned in SystemVerilog: every compare below is between signed operands)
    wire signed [11:0] t_fcw  = $signed({t_fc[10], t_fc});
    wire        t_xvis  = (t_w != 6'd0) && !( t_fcw > ($signed({3'd0, wid}) - 12'sd1) ) && !( t_lc < 12'sd0 );
    //   scrolly = (s2[3] & 0x1ff) + global_yoffset; sourceline = (usedscanline - scrolly) & 0x1ff
    wire        [8:0]  t_srcl = L[8:0] - (w3[8:0] + gyoff[8:0]);
    //   dx = sx + (scrollx & 0x3ff) + xoffs + 0x10   (only mod 1024 matters below)
    wire        [9:0]  t_dx   = t_sx[9:0] + w2[9:0] + ent_d3.xoffs + 10'h010;

    // --- normal sprite
    //   sy = s2[1] & 0x1ff; if (sy & 0x100) sy -= 0x200; sy += global_yoffset; sy &= 0x3ff;
    wire        [9:0]  n_sy   = {w1[8], w1[8:0]} + gyoff[9:0];
    //   sizey = (1 << ((size & 0x0c00) >> 10)) - 1
    wire        [1:0]  n_syc  = ent_d3.gsize ? ent_d3.gsy[1:0] : w1[11:10];
    wire        [1:0]  n_sxc  = ent_d3.gsize ? ent_d3.gsx[1:0] : w0[11:10];
    wire        [3:0]  n_hgt  = 4'd1 << n_syc;                               // sizey + 1
    //   firstline = (sy + yoffs) & 0x3ff; endline = (firstline + (sizey + 1) * 8 - 1) & 0x3ff; both signed at 0x200
    wire        [9:0]  n_fl10 = n_sy + ent_d3.yoffs[9:0];
    wire        [9:0]  n_el10 = n_fl10 + {3'd0, n_hgt, 3'd0} - 10'd1;
    wire signed [12:0] n_fl   = {{3{n_fl10[9]}}, n_fl10};
    wire signed [12:0] n_el   = {{3{n_el10[9]}}, n_el10};
    wire        n_cover = (n_el >= n_fl) ? !(n_fl > Lw || n_el < Lw) : !(Lw > n_el && Lw < n_fl);
    //   line = usedscanline - firstline; y = line >> 3; line &= 7   (mod 1024: the cases where C's value is negative are reads
    //   outside the sprite in MAME, which never happen in the games)
    wire        [9:0]  n_line = Lw[9:0] - n_fl10;
    //   sx = (s2[0] + xoffs); sx = (sx & 0x1ff) - (sx & 0x200); sx -= global_xoffset
    wire        [9:0]  n_sx10 = w0[9:0] + ent_d3.xoffs;
    wire signed [11:0] n_sx   = $signed({{2{n_sx10[9]}}, n_sx10}) - $signed({4'd0, gxoff});
    //   code = s2[3] + ((attr & 7) << 16); flipx = attr & 0x10; flipy = attr & 0x08; color = attr >> 5 (0x7ff for nozoom)
    wire        [18:0] n_code = {w2[2:0], w3};
    wire        n_fx = w2[4], n_fy = w2[3];
    wire        [10:0] n_col  = ent_d3.nozoom ? 11'h7ff : w2[15:5];
    //   basecode = (code & ~((sizex + 1) * (sizey + 1) - 1)) + ((flipy ? sizey - y : y) * (sizex + 1)) + (flipx ? sizex : 0)
    wire        [3:0]  n_hm1   = n_hgt - 4'd1;
    wire        [2:0]  n_sizey = n_hm1[2:0];                                 // (1 << c) - 1, c = 0..3 -> 0, 1, 3, 7
    wire        [3:0]  n_wid   = 4'd1 << n_sxc;
    wire        [3:0]  n_wm1   = n_wid - 4'd1;
    wire        [2:0]  n_sizex = n_wm1[2:0];
    wire        [6:0]  n_area  = 7'd1 << (n_sxc + n_syc);                    // (sizex + 1) * (sizey + 1)
    wire        [2:0]  n_yrow  = n_fy ? (n_sizey - n_line[5:3]) : n_line[5:3];
    wire        [18:0] n_base  = (n_code & ~{12'd0, n_area - 7'd1}) + ({16'd0, n_yrow} << n_sxc) + (n_fx ? {16'd0, n_sizex} : 19'd0);

    // ================================================================== command FIFO
    typedef struct packed {
        logic        tmap;
        logic        nozoom, opaque, shadow;
        logic [2:0]  gfx;
        // normal row
        logic [18:0] code;                   // basecode
        logic [2:0]  sizex;
        logic        fx, fy;
        logic [2:0]  line;                   // row within the tile (before flipy)
        logic [10:0] color;
        logic signed [11:0] sx;              // sprite-space x of the first tile
        // tilemap window
        logic [4:0]  page;
        logic        t16;
        logic [8:0]  srcl;                   // sourceline
        logic [9:0]  dx;                     // dx mod 1024
        logic signed [10:0] fc;              // firstcolumn
        logic signed [11:0] lc;              // lastcolumn
    } cmd_t;

    localparam int CQ = 16;
    cmd_t        cq [CQ];
    logic  [4:0] cq_wp, cq_rp;
    wire  [4:0]  cq_cnt = cq_wp - cq_rp;
    assign cmd_full = (cq_cnt >= 5'(CQ - 5));        // room for the three reads in flight and this clock's
    wire         cq_empty = (cq_wp == cq_rp);
    logic        cq_pop;

    logic        y_push;
    cmd_t        y_cmd;
    always_comb begin
        y_cmd = '0;
        y_cmd.tmap   = ent_d3.tmap;
        y_cmd.nozoom = ent_d3.nozoom;
        y_cmd.opaque = ent_d3.opaque;
        y_cmd.shadow = ent_d3.shadow;
        y_cmd.gfx    = ent_d3.gfx;
        y_cmd.code   = n_base;
        y_cmd.sizex  = n_sizex;
        y_cmd.fx     = n_fx;
        y_cmd.fy     = n_fy;
        y_cmd.line   = n_line[2:0];
        y_cmd.color  = n_col;
        y_cmd.sx     = n_sx;
        y_cmd.page   = w2[14:10];
        y_cmd.t16    = w2[15];
        y_cmd.srcl   = t_srcl;
        y_cmd.dx     = t_dx;
        y_cmd.fc     = t_fc;
        y_cmd.lc     = t_lc;
        y_push = v_d3 && (ent_d3.tmap ? (t_cover && t_xvis) : n_cover);
    end

    always_ff @(posedge clk) begin
        if (rst || start) begin
            cq_wp <= '0; cq_rp <= '0;
        end else begin
            if (y_push) begin cq[cq_wp[3:0]] <= y_cmd; cq_wp <= cq_wp + 5'd1; end
            if (cq_pop) cq_rp <= cq_rp + 5'd1;
        end
    end
    cmd_t cq_head;
    assign cq_head = cq[cq_rp[3:0]];

    // ================================================================== expander
    // A command at the FIFO's head is worked off tile by tile.  Its tiles leave as "tile requests" (code, line, x position, draw
    // parameters) into the row stage, which multiplies the position by the zoom, drops invisible rows and issues the fetch.
    typedef enum logic [1:0] { X_IDLE, X_ROW, X_TMAP } xst_t;
    xst_t        xst;
    cmd_t        xc;                         // the command being expanded
    logic  [3:0] xi;                         // normal: tile index 0 .. sizex
    logic signed [11:0] xv, xv_hi;           // tilemap: the column's dst_x and the last one

    // tile requests into the row stage (registered)
    typedef struct packed {
        logic [18:0] code;
        logic [2:0]  line;                   // after flipy
        logic signed [11:0] pos;             // dst_x (tilemap) or sx + x * 8 (sprite), before the global offset
        logic        nozoom, opaque, shadow, fx;
        logic [2:0]  gfx;
        logic [10:0] color;
    } treq_t;

    // tilemap column read: issued in X_TMAP, the tile word returns 3 clocks later (sr_q) with its parameters in tc_d3
    typedef struct packed {
        logic        v;
        logic        half;                   // xtile & 1: the pair in words 2,3
        logic        xbit;                   // bit 3 of x * 8 (16x16: right half)
        logic        ybit;                   // bit 3 of sourceline (16x16: lower half)
        logic        t16;
        logic [2:0]  tline;                  // sourceline & 7
        logic signed [11:0] pos;
        logic        nozoom, opaque, shadow;
        logic [2:0]  gfx;
    } tcol_t;
    tcol_t       tc_now, tc_d1, tc_d2, tc_d3;

    // first column: the smallest v >= max(firstcolumn - 8, -512) with v = dx (mod 8); last: min(lastcolumn, 511)
    wire signed [10:0] hc_fc  = $signed(cq_head.fc);
    wire signed [11:0] hc_lc  = $signed(cq_head.lc);
    wire signed [11:0] hc_lo0 = $signed({hc_fc[10], hc_fc}) - 12'sd8;
    wire signed [11:0] hc_lo  = (hc_lo0 < -12'sd512) ? -12'sd512 : hc_lo0;
    wire        [2:0]  hc_adj = cq_head.dx[2:0] - hc_lo[2:0];
    wire signed [11:0] hc_v0  = hc_lo + $signed({9'd0, hc_adj});
    wire signed [11:0] hc_hi  = (hc_lc > 12'sd511) ? 12'sd511 : hc_lc;

    // the column of dst_x = xv: x = ((xv - dx) & 0x3ff) >> 3;  xtile = x (8x8) or x >> 1 (16x16); ytile = sourceline >> 3 or >> 4,
    // ^ 0x1f, & 0x1f; the pair of words at 2 * (page * 0x800 + (ytile << 6) + xtile)
    wire        [9:0]  xc_xd   = xv[9:0] - xc.dx;
    wire        [6:0]  xc_x    = xc_xd[9:3];
    wire        [5:0]  xc_xt   = xc.t16 ? {1'b0, xc_x[6:1]} : xc_x[5:0];
    wire        [4:0]  xc_yt   = (xc.t16 ? xc.srcl[8:4] : xc.srcl[7:3]) ^ 5'h1f;

    logic        tr_v;
    treq_t       tr;
    logic        row_full;                   // the row stage cannot take more

    always_comb begin
        ex_sr_req  = (xst == X_TMAP) && !row_full;
        ex_sr_addr = {xc.page, xc_yt, xc_xt[5:1]};
        tc_now = '0;
        tc_now.v      = ex_sr_req;
        tc_now.half   = xc_xt[0];
        tc_now.xbit   = xc_x[0];
        tc_now.ybit   = xc.srcl[3];
        tc_now.t16    = xc.t16;
        tc_now.tline  = xc.srcl[2:0];
        tc_now.pos    = xv;
        tc_now.nozoom = xc.nozoom;
        tc_now.opaque = xc.opaque;
        tc_now.shadow = xc.shadow;
        tc_now.gfx    = xc.gfx;
    end

    always_ff @(posedge clk) begin
        tc_d1 <= tc_now;
        tc_d2 <= tc_d1;
        tc_d3 <= tc_d2;
        if (rst || start) begin tc_d1.v <= 1'b0; tc_d2.v <= 1'b0; tc_d3.v <= 1'b0; end
    end

    // the tilemap's tile word (get_tile): attr = s3[0], code = s3[1] + ((attr & 7) << 16), 16x16: code &= ~3, + 1 / + 2 by the half
    wire [15:0] tm_attr = tc_d3.half ? sr_q[47:32] : sr_q[15:0];
    wire [15:0] tm_lo   = tc_d3.half ? sr_q[63:48] : sr_q[31:16];
    wire        tm_fx   = tm_attr[4], tm_fy = tm_attr[3];
    wire [18:0] tm_code0 = {tm_attr[2:0], tm_lo};
    wire [18:0] tm_code  = tc_d3.t16 ? {tm_code0[18:2], (tc_d3.ybit ^ tm_fy), (tc_d3.xbit ^ tm_fx)} : tm_code0;

    always_ff @(posedge clk) begin
        tr_v  <= 1'b0;
        cq_pop <= 1'b0;
        if (rst || start) begin
            xst <= X_IDLE;
        end else begin
            // a tilemap column's tile word arrives: one tile request
            if (tc_d3.v) begin
                tr_v      <= 1'b1;
                tr.code   <= tm_code;
                tr.line   <= tm_fy ? ~tc_d3.tline : tc_d3.tline;   // drawgfx_line: if (flipy) line = 7 - line
                tr.pos    <= tc_d3.pos;
                tr.nozoom <= tc_d3.nozoom;
                tr.opaque <= tc_d3.opaque;
                tr.shadow <= tc_d3.shadow;
                tr.fx     <= tm_fx;
                tr.gfx    <= tc_d3.gfx;
                tr.color  <= tm_attr[15:5];
            end
            case (xst)
                X_IDLE: if (!cq_empty && !cq_pop) begin
                    xc     <= cq_head;
                    cq_pop <= 1'b1;
                    xi     <= 4'd0;
                    xv     <= hc_v0;
                    xv_hi  <= hc_hi;
                    if (cq_head.tmap) begin
                        if (hc_v0 <= hc_hi) xst <= X_TMAP;
                    end else xst <= X_ROW;
                end
                X_ROW: if (!row_full && !tc_d1.v && !tc_d2.v && !tc_d3.v) begin
                    // basecode += code_inc per tile; realsx = sx + x * 8
                    tr_v      <= 1'b1;
                    tr.code   <= xc.code + (xc.fx ? -{15'd0, xi} : {15'd0, xi});
                    tr.line   <= xc.fy ? ~xc.line : xc.line;
                    tr.pos    <= xc.sx + $signed({5'd0, xi, 3'd0});
                    tr.nozoom <= xc.nozoom;
                    tr.opaque <= xc.opaque;
                    tr.shadow <= xc.shadow;
                    tr.fx     <= xc.fx;
                    tr.gfx    <= xc.gfx;
                    tr.color  <= xc.color;
                    xi <= xi + 4'd1;
                    if (xi[2:0] == xc.sizex) xst <= X_IDLE;
                end
                X_TMAP: if (ex_sr_req) begin
                    xv <= xv + 12'sd8;
                    if (xv + 12'sd8 > xv_hi) xst <= X_IDLE;
                end
                default: xst <= X_IDLE;
            endcase
        end
    end

    // ================================================================== row stage: position x zoom, visibility, fetch
    //   realsx = (pos - (usedxoffset >> 16)) * usedxzoom      (uint32, used as int: s32)
    // nozoom entries: usedxoffset = 0, usedxzoom = 0x10000.
    // Three clocks: the operands, the product (DSP), the extent; then the visibility test and the push into the fetch / parameter
    // FIFOs.
    logic        r1_v;
    treq_t       r1;
    logic signed [12:0] r1_d;                 // pos - xoff
    logic [31:0] r1_z;
    always_ff @(posedge clk) begin
        r1_v <= tr_v && !(rst || start);
        r1   <= tr;
        r1_d <= tr.nozoom ? {tr.pos[11], tr.pos} : ({tr.pos[11], tr.pos} - {{2{xo[10]}}, xo});
        r1_z <= tr.nozoom ? 32'h0001_0000 : xz;
    end
    logic        r2_v;
    treq_t       r2;
    logic [31:0] r2_sx;                       // realsx (16.16, two's complement)
    logic [31:0] r2_z;
    always_ff @(posedge clk) begin
        r2_v  <= r1_v && !(rst || start);
        r2    <= r1;
        r2_sx <= 32'($signed(r1_d) * $signed({1'b0, r1_z}));
        r2_z  <= r1_z;
    end
    // a third clock: the row's extent and the tile number, then the visibility test and the push
    // visible: some position of the row in [0, width << 16): the row covers [realsx, realsx + 8 * zoom)  (both loops of drawgfx_line)
    // tile code % elements (m_realtilenumber)
    wire [18:0] r2_cm  = r2.code & tile_mask;
    logic        r3_v;
    treq_t       r3;
    logic [31:0] r3_sx, r3_z;
    logic [18:0] r3_kz [8];                   // m * zoom (m = 0..7), for the shrunk rows' column positions
    logic signed [36:0] r3_hi;
    logic [18:0] r3_cod;
    always_ff @(posedge clk) begin
        r3_v   <= r2_v && !(rst || start);
        r3     <= r2;
        r3_sx  <= r2_sx;
        r3_z   <= r2_z;
        for (int m = 0; m < 8; m++) r3_kz[m] <= 19'(r2_z[15:0]) * 19'(m);
        r3_hi  <= $signed({{5{r2_sx[31]}}, r2_sx}) + $signed({2'd0, r2_z, 3'd0});
        r3_cod <= ({1'b0, r2_cm} >= tile_count) ? 19'({1'b0, r2_cm} - tile_count) : r2_cm;
    end
    wire signed [36:0] r3_lo  = {{5{r3_sx[31]}}, r3_sx};
    wire               r3_vis = (r3_lo < $signed({12'd0, wid, 16'd0})) && (r3_hi > 37'sd0);
    logic       [23:0] r3_scy;
    always_comb for (int m = 0; m < 8; m++) begin
        logic [18:0] f;
        f = {3'd0, r3_sx[15:0]} + r3_kz[m];
        r3_scy[3 * m +: 3] = f[18:16];
    end

    // fetch requests and their draw parameters, in order
    typedef struct packed {
        logic [31:0] sx;
        logic [31:0] zoom;
        logic [14:0] color16;                 // color << 4 (the low 15 bits: realcolor + pen is masked with 0x7fff)
        logic        fx, opaque, shadow;
        logic [2:0]  gfx;
        logic [23:0] scy;                     // shrink: ((sx & 0xffff) + m * zoom) >> 16 for m = 7..0, 3 bits each
    } dprm_t;
    localparam int FQ = 16;
    logic [21:0] fq_a [FQ];
    dprm_t       pq   [FQ];
    logic  [4:0] fq_wp, fq_rp, pq_rp;         // fq_rp: next to request, pq_rp: next to draw
    wire   [4:0] fq_used = fq_wp - pq_rp;     // requests not yet drawn
    assign row_full = (fq_used >= 5'(FQ - 8)) ;  // tc_d1..3, tr, r1, r2, r3 and this clock's column read in flight
    wire         fq_pend = (fq_wp != fq_rp);
    assign gf_req  = fq_pend;
    assign gf_addr = fq_a[fq_rp[3:0]];

    logic        drw_pop;
    always_ff @(posedge clk) begin
        if (rst || start) begin
            fq_wp <= '0; fq_rp <= '0; pq_rp <= '0;
        end else begin
            if (r3_v && r3_vis) begin
                fq_a[fq_wp[3:0]] <= {r3_cod, r3.line};
                pq[fq_wp[3:0]]   <= '{sx: r3_sx, zoom: r3_z, color16: {r3.color[10:0], 4'd0}, fx: r3.fx, opaque: r3.opaque,
                                      shadow: r3.shadow, gfx: r3.gfx, scy: r3_scy};
                fq_wp <= fq_wp + 5'd1;
            end
            if (gf_req && gf_ready) fq_rp <= fq_rp + 5'd1;
            if (drw_pop) pq_rp <= pq_rp + 5'd1;
        end
    end

    // the rows as they come back from the ROM (in order), queued for the drawer
    logic [63:0] dq [FQ];
    logic  [4:0] dq_wp, dq_rp;
    always_ff @(posedge clk) begin
        if (rst || start) begin dq_wp <= '0; dq_rp <= '0; end
        else begin
            if (gf_valid) begin dq[dq_wp[3:0]] <= gf_data; dq_wp <= dq_wp + 5'd1; end
            if (drw_pop) dq_rp <= dq_rp + 5'd1;
        end
    end
    wire        dq_av  = (dq_wp != dq_rp);
    wire [63:0] dq_h   = dq[dq_rp[3:0]];
    dprm_t pq_h;
    assign pq_h = pq[pq_rp[3:0]];

    // ================================================================== drawer
    // BPP_MASK_TABLE: {gfx_mask, gfx_shift, shadow} per colour depth mode
    function automatic [15:0] bppt(input [2:0] m);   // {mask[7:0], shift[3:0], shadow[3:0]}
        case (m)
            3'd0: bppt = {8'hff, 4'd0, 4'd4};
            3'd1: bppt = {8'h30, 4'd4, 4'd2};
            3'd2: bppt = {8'h07, 4'd0, 4'd3};
            3'd3: bppt = {8'hff, 4'd0, 4'd0};
            3'd4: bppt = {8'h0f, 4'd0, 4'd3};
            3'd5: bppt = {8'hf0, 4'd4, 4'd4};
            3'd6: bppt = {8'h3f, 4'd0, 4'd5};
            default: bppt = {8'hff, 4'd0, 4'd8};
        endcase
    endfunction

    // the line buffer: 8 banks (x mod 8) x {line, x >> 3}
    logic        lb_we   [8];
    logic  [6:0] lb_wa   [8];
    logic [14:0] lb_wd   [8];
    logic  [6:0] lb_ra   [8];
    logic [14:0] lb_rq   [8];
    logic  [6:0] dr_a;
    logic  [2:0] dr_b, dr_b1;
    logic [14:0] dr_q   [8];
    genvar gb;
    generate for (gb = 0; gb < 8; gb++) begin : g_lb
        // port A: the drawer (one address per clock: the write's, else the shadow read's); the line is cleared through it too
        // port B: the display (read only)
        s2_dpram #(.AW(7), .DW(15)) u_bank (
            .clk(clk),
            .a_addr(lb_we[gb] ? lb_wa[gb] : lb_ra[gb]), .a_we(lb_we[gb]), .a_d(lb_wd[gb]), .a_q(lb_rq[gb]),
            .b_addr(dr_a), .b_q(dr_q[gb])
        );
    end endgenerate

    // display side: read at dsp_rd, the pixel 3 clocks later
    always_ff @(posedge clk) begin
        dr_a  <= {dsp_sel, dsp_x[8:3]};
        dr_b  <= dsp_x[2:0];
        dr_b1 <= dr_b;
        dsp_q <= dr_q[dr_b1];
    end

    // the pens of a row: byte q of the row is bit plane q; pixel (column) c is bit 7 - c
    function automatic [7:0] pen_of(input [63:0] row, input [2:0] c);
        for (int q = 0; q < 8; q++) pen_of[q] = row[8 * q + (7 - c)];
    endfunction

    // drawer: rows come through two registered stages, then D_IDLE takes one per clock.  Zoom 1 (realsx whole, zoom 0x10000)
    // and shrink (zoom < 1), both without shadow, write all of the row at once; otherwise the pixel loop (D_PIX), one position per
    // clock, with a read of the destination before each shadow write.
    //   H1  the row and its parameters, from the FIFO heads
    //   H2  precomputed from H1: the row's 8 pens (mask and shift applied), the fast path's 8 writes in pixel order (position,
    //       value, enable), the pixel loop's start values
    typedef enum logic [2:0] { D_IDLE, D_PIX, D_SRD, D_SRQ, D_SWR } dst_t;
    dst_t        dst;
    logic        clr;

    // ---- H1
    logic        h1_v, h2_v;
    logic [63:0] h1_row;
    dprm_t       h1_p;
    wire         h2_take = h2_v && (dst == D_IDLE) && !clr && !(rst || start);
    wire         h2_free = !h2_v || h2_take;
    wire         h1_free = !h1_v || h2_free;
    assign drw_pop = dq_av && h1_free && !(rst || start);
    always_ff @(posedge clk) begin
        if (rst || start) h1_v <= 1'b0;
        else if (h1_free) h1_v <= dq_av;
        if (h1_free) begin h1_row <= dq_h; h1_p <= pq_h; end
    end

    // ---- H2 (from H1)
    wire  [15:0] bp1 = bppt(h1_p.gfx);
    logic  [7:0] h1_pen [8];                  // column c's pen
    logic        h1_fwe [8];                  // fast path, pixel i (x = X + i): enable, line buffer address, value
    logic  [6:0] h1_fwa [8];
    logic [14:0] h1_fwd [8];
    wire signed [15:0] h1_x0 = $signed(h1_p.sx[31:16]);
    always_comb begin
        for (int c = 0; c < 8; c++) h1_pen[c] = (pen_of(h1_row, 3'(c)) & bp1[15:8]) >> bp1[7:4];
        for (int i = 0; i < 8; i++) begin
            logic signed [15:0] p;
            logic [7:0] pn;
            p  = h1_x0 + 16'(i);
            pn = h1_pen[h1_p.fx ? 7 - i : i];
            h1_fwe[i] = (p >= 16'sd0) && (p < $signed({7'd0, wid})) && (pn != 8'd0 || h1_p.opaque);
            h1_fwa[i] = {lsel, p[8:3]};
            h1_fwd[i] = h1_p.color16 + {7'd0, pn};
        end
    end
    // shrink (zoom < 1) without shadow, all 8 columns in one clock: column k lands at floor((sx + m z) / 2^16), m = k (flipx 7 - k),
    // = (sx >> 16) + ((sx & 0xffff) + m z) >> 16 (0..7 on); the row's positions are consecutive within 8 pixels, so they are in 8
    // different banks; columns on the same pixel overwrite in column order (MAME's loop), so the last one with a pen wins (D_IDLE)
    logic        h1_swe [8];
    logic  [2:0] h1_sbk [8];
    logic  [6:0] h1_swa [8];
    logic [14:0] h1_swd [8];
    always_comb begin
        for (int k = 0; k < 8; k++) begin
            logic [2:0] cy;
            logic signed [16:0] p;
            cy = h1_p.fx ? h1_p.scy[3 * (7 - k) +: 3] : h1_p.scy[3 * k +: 3];     // (the row stage's sums)
            p = $signed({h1_x0[15], h1_x0}) + $signed({14'd0, cy});
            h1_swe[k] = (p >= 17'sd0) && (p < $signed({8'd0, wid})) && (h1_pen[k] != 8'd0 || h1_p.opaque);
            h1_sbk[k] = p[2:0];
            h1_swa[k] = {lsel, p[8:3]};
            h1_swd[k] = h1_p.color16 + {7'd0, h1_pen[k]};
        end
    end
    logic        h2_fast;
    logic        h2_sfast;                    // shrink without shadow: the 8 columns in one clock
    logic        h2_swe [8];
    logic  [2:0] h2_sbk [8];
    logic  [6:0] h2_swa [8];
    logic [14:0] h2_swd [8];
    logic  [2:0] h2_rot;                      // X mod 8: pixel i goes to bank (X + i) mod 8
    logic        h2_fwe [8];
    logic  [6:0] h2_fwa [8];
    logic [14:0] h2_fwd [8];
    logic  [7:0] h2_pen [8];
    dprm_t       h2_p;
    logic  [3:0] h2_shad;
    logic        h2_shrink;
    logic signed [35:0] h2_sx, h2_end, h2_dx;
    logic  [3:0] h2_col;
    always_ff @(posedge clk) begin
        if (rst || start) h2_v <= 1'b0;
        else if (h2_free) h2_v <= h1_v;
        if (h2_free) begin
            h2_fast  <= (h1_p.zoom == 32'h0001_0000) && (h1_p.sx[15:0] == 16'd0) && !h1_p.shadow;
            h2_sfast <= (h1_p.zoom < 32'h0001_0000) && !h1_p.shadow;
            h2_rot   <= h1_p.sx[18:16];
            for (int i = 0; i < 8; i++) begin
                h2_fwe[i] <= h1_fwe[i]; h2_fwa[i] <= h1_fwa[i]; h2_fwd[i] <= h1_fwd[i]; h2_pen[i] <= h1_pen[i];
                h2_swe[i] <= h1_swe[i]; h2_sbk[i] <= h1_sbk[i]; h2_swa[i] <= h1_swa[i]; h2_swd[i] <= h1_swd[i];
            end
            h2_p    <= h1_p;
            h2_shad <= h1_p.shadow ? bp1[3:0] : 4'd0;
            if (h1_p.zoom < 32'h0001_0000) begin
                // shrink: the column is the iteration, the position runs backwards with flipx (from x0 + 7z)
                h2_shrink <= 1'b1;
                h2_sx  <= h1_p.fx ? ($signed({{4{h1_p.sx[31]}}, h1_p.sx}) + $signed({1'b0, h1_p.zoom, 3'd0}) - $signed({4'd0, h1_p.zoom}))
                                  : $signed({{4{h1_p.sx[31]}}, h1_p.sx});
                h2_dx  <= h1_p.fx ? -$signed({4'd0, h1_p.zoom}) : $signed({4'd0, h1_p.zoom});
                h2_col <= 4'd0;
            end else begin
                h2_shrink <= 1'b0;
                h2_sx  <= $signed({{4{h1_p.sx[31]}}, h1_p.sx});
                h2_end <= $signed({{4{h1_p.sx[31]}}, h1_p.sx}) + $signed({1'b0, h1_p.zoom, 3'd0});
                h2_col <= h1_p.fx ? 4'd7 : 4'd0;
            end
        end
    end

    // ---- pixel loop (MAME's two loops of drawgfx_line), one position per clock; a shadow pixel reads its destination first
    //   shrink  (zoom < 1): column k (0..7) at base + k * z, flipx: at base + (7 - k) * z     (x0, x1, dx of the C code)
    //   enlarge (zoom >= 1): positions base, base + 1.0, ... while < base + 8z; the column steps (+1, flipx -1) when countx >= z
    logic  [7:0] d_pen8 [8];                  // the row's pens by column
    dprm_t       d_p;
    logic  [3:0] d_shad;
    logic signed [35:0] d_sx, d_end;          // 16.16 position; enlarge: the loop's end (x0 + 8z)
    logic signed [35:0] d_dx;                 // shrink: the step
    logic        d_shrink;
    logic  [3:0] d_col;                       // the column
    logic  [3:0] d_it;                        // shrink: iterations done
    logic [32:0] d_cnt;                       // enlarge: countx
    logic  [8:0] d_px;                        // shadow: the pixel
    logic  [7:0] d_pen;

    wire  [7:0] s_pen = d_pen8[d_col[2:0]];
    wire        s_in  = (d_sx >= 36'sd0) && (d_sx < $signed({11'd0, wid, 16'd0}));
    wire        s_drw = s_in && (s_pen != 8'd0 || d_p.opaque);
    wire  [8:0] s_px  = d_sx[24:16];
    // the next position and whether the row is finished after this one
    logic signed [35:0] nx_sx;
    logic  [3:0] nx_col, nx_it;
    logic [32:0] nx_cnt;
    logic        nx_fin;
    always_comb begin
        nx_sx = d_sx; nx_col = d_col; nx_it = d_it; nx_cnt = d_cnt; nx_fin = 1'b0;
        if (d_shrink) begin
            nx_sx  = d_sx + d_dx;
            nx_col = d_col + 4'd1;
            nx_it  = d_it + 4'd1;
            nx_fin = (d_it == 4'd7);
        end else begin
            nx_sx  = d_sx + 36'sh10000;
            if (d_cnt + 33'h10000 >= {1'b0, d_p.zoom}) begin
                nx_col = d_p.fx ? (d_col - 4'd1) : (d_col + 4'd1);
                nx_cnt = d_cnt + 33'h10000 - {1'b0, d_p.zoom};
            end else nx_cnt = d_cnt + 33'h10000;
            nx_fin = !(d_sx + 36'sh10000 < d_end);
        end
    end

    logic [15:0] rows_cnt, cyc_cnt;
    logic  [5:0] clr_cnt;
    assign st_rows = rows_cnt;
    assign st_cycles = cyc_cnt;

    always_ff @(posedge clk) begin
        for (int b = 0; b < 8; b++) lb_we[b] <= 1'b0;
        if (rst || start) begin
            dst <= D_IDLE;
            clr <= !rst;                      // the line's half of the buffer is cleared first (pen 0: bitmap.fill(pen(0)))
            clr_cnt <= 6'd0;
            if (start) rows_cnt <= 16'd0;
        end else if (clr) begin
            for (int b = 0; b < 8; b++) begin lb_we[b] <= 1'b1; lb_wa[b] <= {lsel, clr_cnt}; lb_wd[b] <= 15'd0; end
            clr_cnt <= clr_cnt + 6'd1;
            if (clr_cnt == 6'd63) clr <= 1'b0;
        end else case (dst)
            D_IDLE: if (h2_take) begin
                rows_cnt <= rows_cnt + 16'd1;
                if (h2_fast) begin
                    // pixel i to bank (X + i) mod 8
                    for (int b = 0; b < 8; b++) begin
                        lb_we[b] <= h2_fwe[3'(b) - h2_rot]; lb_wa[b] <= h2_fwa[3'(b) - h2_rot]; lb_wd[b] <= h2_fwd[3'(b) - h2_rot];
                    end
                end else if (h2_sfast) begin
                    // each bank: the last column (in drawing order) that lands in it with a pen
                    for (int b = 0; b < 8; b++)
                        for (int k = 0; k < 8; k++)
                            if (h2_swe[k] && h2_sbk[k] == 3'(b)) begin lb_we[b] <= 1'b1; lb_wa[b] <= h2_swa[k]; lb_wd[b] <= h2_swd[k]; end
                end else begin
                    for (int c = 0; c < 8; c++) d_pen8[c] <= h2_pen[c];
                    d_p      <= h2_p;
                    d_shad   <= h2_shad;
                    d_cnt    <= 33'd0;
                    d_it     <= 4'd0;
                    d_shrink <= h2_shrink;
                    d_sx     <= h2_sx;
                    d_end    <= h2_end;
                    d_dx     <= h2_dx;
                    d_col    <= h2_col;
                    dst      <= D_PIX;
                end
            end

            D_PIX: begin
                if (s_drw && d_shad != 4'd0) begin
                    // shadow: dest = (dest & pen_mask) | (pen << pen_shift): read the destination, write in D_SWR
                    d_px  <= s_px;
                    d_pen <= s_pen;
                    lb_ra[s_px[2:0]] <= {lsel, s_px[8:3]};
                    dst <= D_SRD;
                end else begin
                    if (s_drw) begin
                        lb_we[s_px[2:0]] <= 1'b1;
                        lb_wa[s_px[2:0]] <= {lsel, s_px[8:3]};
                        lb_wd[s_px[2:0]] <= d_p.color16 + {7'd0, s_pen};
                    end
                    d_sx <= nx_sx; d_col <= nx_col; d_it <= nx_it; d_cnt <= nx_cnt;
                    if (nx_fin) dst <= D_IDLE;
                end
            end
            D_SRD: dst <= D_SRQ;                      // the RAM reads lb_ra
            D_SRQ: dst <= D_SWR;                      // lb_rq valid
            D_SWR: begin
                lb_we[d_px[2:0]] <= 1'b1;
                lb_wa[d_px[2:0]] <= {lsel, d_px[8:3]};
                lb_wd[d_px[2:0]] <= (lb_rq[d_px[2:0]] & ((15'd1 << (4'd15 - d_shad)) - 15'd1)) |
                                    15'({7'd0, d_pen} << (4'd15 - d_shad));
                d_sx <= nx_sx; d_col <= nx_col; d_it <= nx_it; d_cnt <= nx_cnt;
                dst <= nx_fin ? D_IDLE : D_PIX;
            end
            default: dst <= D_IDLE;
        endcase
    end

    // ================================================================== simulation trace (+tline=N: line N's commands and rows)
`ifdef VERILATOR
    int tline = -1;
    initial if (!$value$plusargs("tline=%d", tline)) tline = -1;
    always_ff @(posedge clk) if (int'(ry) == tline) begin
        if (v_d3) $display("[tl] sub ent tmap=%0d w=%h %h %h %h cover n=%0d t=%0d xvis=%0d push=%0d L=%0d t_fl=%0d t_el=%0d fc=%0d lc=%0d",
                           ent_d3.tmap, w0, w1, w2, w3, n_cover, t_cover, t_xvis, y_push, Lw, t_fl, t_el, t_fc, t_lc);
        if (r3_v) $display("[tl] row code=%h line=%0d sx=%h vis=%0d", r3.code, r3.line, r3_sx, r3_vis);
        if (wst == W_E1) $display("[tl] entry %0d q=%h", e, pl_q);
    end
`endif

    // ================================================================== line done
    wire idle_all = (wst == W_DONE) && !v_d1 && !v_d2 && !v_d3 && cq_empty && (xst == X_IDLE) && !tc_d1.v && !tc_d2.v && !tc_d3.v && !tr_v && !r1_v &&
                    !r2_v && !r3_v && (fq_wp == pq_rp) && !h1_v && !h2_v && (dst == D_IDLE) && !clr;
    logic run;
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin run <= 1'b0; cyc_cnt <= 16'd0; end
        else if (start) begin run <= 1'b1; cyc_cnt <= 16'd0; end
        else if (run) begin
            cyc_cnt <= cyc_cnt + 16'd1;
            if (idle_all && cyc_cnt > 16'd2) begin run <= 1'b0; done <= 1'b1; end
        end
    end
    assign busy = run;

endmodule
`default_nettype wire
