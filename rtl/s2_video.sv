// Allumer X1-020 / NEC DX-101 video chip (seta2.cpp), from MAME 0.289's src/devices/video/x1_020_dx_101.cpp.
//
// CPU side (a 0x80000 window; the word addresses below are of that window):
//   0x00000-0x3ffff  sprite RAM, 256 KB      (here 32 K x 64 bits: word 4a+k in bits 16k+15..16k)
//   0x40000-0x4ffff  palette RAM, xRGB_555   (32 K x 16)
//   0x60000-0x6003f  registers               (read back as written)
// (0x50000-0x5ffff, "cleared, additional palette area?", is the board's: s2_main maps it to the slow RAM.)
//
// Register 0x24 / 0x26 written non-zero: the display-list copy of vregs_w -- the list at sprite RAM 0x3000 into the private list,
// the sub-sprites each entry points at packed into sprite RAM 0x0000.., the pointers rewritten -- in MAME's order (each read sees
// the copies before it), on port A of the sprite RAM: 2 clocks per sub-sprite, ~50 us at most.  CPU accesses to the sprite RAM wait
// while it runs; the CPU itself does not.
//
// Timing: the CRTC values come from the MRA (the values the games program; MAME runs every set at 60 Hz on a 0x200 x 0x100
// raster).  MAME's raster position ("vpos": 0 = first visible line) is kept one line ahead of the picture: line N is drawn while line
// N-1 is shown, starting where MAME's raster reaches (N, 0); a raster IRQ for line N therefore comes one line before that line is
// shown, and the vblank IRQ one line before the last line ends.  While the raster IRQ is enabled the line starts `rdly` dots later,
// so that the IRQ routine's writes (Guardians: ~80 dots after the IRQ) reach the line it names, as with MAME's update_partial.
`default_nettype none

module s2_video #(
    parameter int DOT_DIV = 0               // > 0: the dot clock is the machine clock / DOT_DIV exactly (the builds); 0: dot_inc
) (
    input  logic        clk,                // 100 MHz
    input  logic        rst,

    // CPU: word address within the chip's window (A18..A1), level request held until the ack
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [18:1] cpu_addr,
    input  logic [15:0] cpu_din,
    input  logic  [1:0] cpu_be,             // {UDS, LDS}
    output logic [15:0] cpu_dout,
    output logic        cpu_ack,

    // configuration (MRA)
    input  logic [23:0] dot_inc,            // (DOT_DIV = 0) dot clock = machine clock * dot_inc / 2^24
    input  logic  [9:0] h_total,            // dots per line
    input  logic  [9:0] h_sync,             // hsync: dots 0 .. h_sync
    input  logic  [9:0] h_start,            // first displayed dot
    input  logic  [8:0] h_width,            // displayed dots (MAME's visible width)
    input  logic  [8:0] v_total,            // lines per frame
    input  logic  [8:0] v_sync,             // vsync: lines 0 .. v_sync
    input  logic  [8:0] v_start,            // first displayed line
    input  logic  [8:0] v_height,           // displayed lines (MAME's visible height)
    input  logic  [9:0] rdly,               // raster mode: dots between MAME's line start and drawing the line
    input  logic [18:0] tile_mask,          // graphics ROM: code % elements
    input  logic [19:0] tile_count,

    // interrupts
    output logic        irq_vblank,         // level: MAME's screen_vblank, from MAME's line v_height to line 0
    output logic        irq_raster,         // pulse: the raster timer fires with 0x3c bit 0 set (MAME: HOLD_LINE on INT1)

    // graphics ROM (SDRAM)
    output logic        gf_req,
    output logic [21:0] gf_addr,
    input  logic        gf_ready,
    input  logic        gf_valid,
    input  logic [63:0] gf_data,

    // video out (blank / sync / colour of one dot, changed on ce_pix)
    output logic        ce_pix,
    output logic        hblank, vblank, hsync, vsync,
    output logic  [7:0] r, g, b,

    // diagnostics
    output logic        dbg_overrun,        // pulse: a line was due while the one before was still being drawn
    output logic [15:0] dbg_line_cycles,    // clocks the last line took
    output logic [15:0] dbg_line_rows,
    output logic  [8:0] dbg_mvpos,
    output logic        dbg_line_done,      // pulse

    // simulation back door (frozen MAME states): 0 sprite RAM (64-bit word), 1 palette (word), 2 private list (64-bit), 3 register
    input  logic        bd_we,
    input  logic  [1:0] bd_sel,
    input  logic [14:0] bd_addr,
    input  logic [63:0] bd_data
);

    // ================================================================== registers
    logic [15:0] vr [32];
    initial for (int i = 0; i < 32; i++) vr[i] = 16'd0;

    // ================================================================== RAMs
    // sprite RAM: 8 byte lanes of 32 K (one RAM per lane: Quartus 17 infers byte-enable RAMs slowly).
    //   port A: CPU / copy engine / back door: address, write enables and data registered (sa_*_c the clock before), the read
    //           data a clock after that
    //   port B: renderer, address registered, read, and the 32-block read mux registered: data 3 clocks after the address
    logic [14:0] sa_addr, sa_addr_c;
    logic  [7:0] sa_we, sa_we_c;
    logic [63:0] sa_d, sa_d_c, sa_q;
    always_ff @(posedge clk) begin sa_addr <= sa_addr_c; sa_we <= sa_we_c; sa_d <= sa_d_c; end
    logic [14:0] sb_addr, sb_addr_r;
    logic [63:0] sb_q;
    genvar gl;
    generate for (gl = 0; gl < 8; gl++) begin : g_spr
        s2_dpram #(.AW(15), .DW(8)) u_lane (
            .clk(clk),
            .a_addr(sa_addr), .a_we(sa_we[gl]), .a_d(sa_d[8 * gl +: 8]), .a_q(sa_q[8 * gl +: 8]),
            .b_addr(sb_addr_r), .b_q(sb_q[8 * gl +: 8])
        );
    end endgenerate
    logic [63:0] sb_qr;
    always_ff @(posedge clk) begin sb_addr_r <= sb_addr; sb_qr <= sb_q; end

    // private list: 512 x 64, written by the copy engine, read by the renderer (1 clock)
    logic        pl_we;
    logic  [8:0] pl_wa, pl_ra;
    logic [63:0] pl_wd, pl_q;
    (* ramstyle = "no_rw_check" *) logic [63:0] plist [512];
    always_ff @(posedge clk) begin
        if (pl_we) plist[pl_wa] <= pl_wd;
        pl_q <= plist[pl_ra];
    end

    // palette RAM: 32 K x 16, port A CPU, port B the display
    logic [14:0] pa_addr;
    logic  [1:0] pa_we;
    logic [15:0] pa_d, pa_q;
    logic [14:0] pb_addr;
    logic [15:0] pb_q;
    (* ramstyle = "no_rw_check" *) logic [7:0] pal_hi [32768];
    (* ramstyle = "no_rw_check" *) logic [7:0] pal_lo [32768];
    always_ff @(posedge clk) begin
        if (pa_we[1]) pal_hi[pa_addr] <= pa_d[15:8];
        pa_q[15:8] <= pal_hi[pa_addr];
    end
    always_ff @(posedge clk) begin
        if (pa_we[0]) pal_lo[pa_addr] <= pa_d[7:0];
        pa_q[7:0] <= pal_lo[pa_addr];
    end
    always_ff @(posedge clk) pb_q <= {pal_hi[pb_addr], pal_lo[pb_addr]};

    // ================================================================== CPU access, list copy
    wire sel_spr = !cpu_addr[18];                                           // 0x00000-0x3ffff
    wire sel_pal = cpu_addr[18:16] == 3'b100;                               // 0x40000-0x4ffff
    wire sel_reg = (cpu_addr[18:16] == 3'b110) && (cpu_addr[15:6] == 10'd0); // 0x60000-0x6003f

    typedef enum logic [3:0] { C_IDLE, C_ERD, C_ERW, C_EW, C_ENT, C_SRD, C_SRW, C_SWR, C_NEXT } cst_t;
    cst_t        cst;
    logic        copy_go;
    logic  [8:0] c_i;                                                       // list entry
    logic [10:0] c_cur;                                                     // current_sprite_entry / 4 (0 .. 0x600)
    logic [63:0] c_ent;
    logic [14:0] c_src;                                                     // (sprite & 0x7fff) + j: 64-bit words, mod 0x8000
    logic  [8:0] c_j, c_n;

    typedef enum logic [1:0] { A_IDLE, A_WAIT, A_ACK } ast_t;
    ast_t        ast;
    logic        a_cnt;
    wire         copy_busy = (cst != C_IDLE) || copy_go;
    wire         a_take    = (ast == A_IDLE) && cpu_req && !(sel_spr && copy_busy);

    // (a CPU read: the address goes in at A_IDLE, the RAM reads it at the first A_WAIT clock, the data is taken at the second)
    always_comb begin
        sa_addr_c = cpu_addr[17:3];
        sa_we_c   = '0;
        sa_d_c    = {4{cpu_din}};
        case (cst)
            C_ERD:  sa_addr_c = 15'h0600 + {6'd0, c_i};
            C_SRD:  sa_addr_c = c_src;
            C_SWR:  begin sa_addr_c = {4'd0, c_cur}; sa_we_c = 8'hff; sa_d_c = sa_q; end
            default: begin
                if (a_take && cpu_we && sel_spr) begin
                    case (cpu_addr[2:1])
                        2'd0: sa_we_c = {6'd0, cpu_be};
                        2'd1: sa_we_c = {4'd0, cpu_be, 2'd0};
                        2'd2: sa_we_c = {2'd0, cpu_be, 4'd0};
                        default: sa_we_c = {cpu_be, 6'd0};
                    endcase
                end
            end
        endcase
        if (bd_we && bd_sel == 2'd0) begin sa_addr_c = bd_addr; sa_we_c = 8'hff; sa_d_c = bd_data; end
    end

    always_ff @(posedge clk) begin
        cpu_ack <= 1'b0;
        pa_we   <= 2'b00;
        if (bd_we && bd_sel == 2'd1) begin pa_addr <= bd_addr; pa_d <= bd_data[15:0]; pa_we <= 2'b11; end
        if (rst) begin
            ast <= A_IDLE;
        end else case (ast)
            A_IDLE: if (a_take) begin
                pa_addr <= cpu_addr[15:1];
                pa_d    <= cpu_din;
                if (cpu_we && sel_pal) pa_we <= cpu_be;
                a_cnt <= 1'b0;
                ast   <= A_WAIT;
            end
            A_WAIT: begin
                a_cnt <= 1'b1;
                if (a_cnt) begin
                    if (sel_spr)      cpu_dout <= sa_q[16 * cpu_addr[2:1] +: 16];
                    else if (sel_pal) cpu_dout <= pa_q;
                    else if (sel_reg) cpu_dout <= vr[cpu_addr[5:1]];
                    else              cpu_dout <= 16'h0000;
                    cpu_ack <= 1'b1;
                    ast <= A_ACK;
                end
            end
            A_ACK: if (!cpu_req) ast <= A_IDLE;
            default: ast <= A_IDLE;
        endcase
    end

    // register writes: COMBINE_DATA; the copy on a non-zero write to 0x24 / 0x26; the raster timer re-armed by any write to 0x3c
    wire       reg_wr  = a_take && cpu_we && sel_reg;
    wire [4:0] reg_idx = cpu_addr[5:1];
    logic      rast_arm;
    always_ff @(posedge clk) begin
        rast_arm <= 1'b0;
        copy_go  <= 1'b0;
        if (reg_wr) begin
            if (cpu_be[1]) vr[reg_idx][15:8] <= cpu_din[15:8];
            if (cpu_be[0]) vr[reg_idx][7:0]  <= cpu_din[7:0];
            if ((reg_idx == 5'h12 || reg_idx == 5'h13) && cpu_din != 16'd0) copy_go <= 1'b1;
            if (reg_idx == 5'h1e) rast_arm <= 1'b1;
        end
        if (bd_we && bd_sel == 2'd3) vr[bd_addr[4:0]] <= bd_data[15:0];
    end

    // the copy (vregs_w, case 0x24 / 0x26)
    always_ff @(posedge clk) begin
        pl_we <= 1'b0;
        if (bd_we && bd_sel == 2'd2) begin pl_we <= 1'b1; pl_wa <= bd_addr[8:0]; pl_wd <= bd_data; end
        if (rst) cst <= C_IDLE;
        else case (cst)
            C_IDLE: if (copy_go) begin c_i <= 9'd0; c_cur <= 11'd0; cst <= C_ERD; end
            C_ERD:  cst <= C_ERW;                                        // the entry at sprite RAM 0x3000 / 2 + i * 4 words
            C_ERW:  cst <= C_EW;
            C_EW:   begin c_ent <= sa_q; cst <= C_ENT; end
            C_ENT: begin
                // num, xoffs, yoffs as they are; sprite = ((current_sprite_entry / 4) & 0x7fff) | (sprite & 0x8000)
                // (the end marker's entry with sprite == 0 gets | 0x4000: MAME's penbros hack, the pointer filtered when drawing)
                pl_we <= 1'b1;
                pl_wa <= c_i;
                pl_wd <= {c_ent[63], (c_ent[15] && c_ent[63:48] == 16'd0), 3'd0, c_cur, c_ent[47:0]};
                c_src <= c_ent[62:48];
                c_j   <= 9'd0;
                c_n   <= {1'b0, c_ent[7:0]} + 9'd1;
                cst   <= (c_cur < 11'h600) ? C_SRD : C_NEXT;                 // nothing more fits: the sub-sprites are skipped
            end
            C_SRD: cst <= C_SRW;                                         // read source j
            C_SRW: cst <= C_SWR;
            C_SWR: begin                                                 // write it at current_sprite_entry
                c_cur <= c_cur + 11'd1;
                c_src <= c_src + 15'd1;
                c_j   <= c_j + 9'd1;
                cst   <= (c_j + 9'd1 == c_n || c_cur + 11'd1 == 11'h600) ? C_NEXT : C_SRD;
            end
            C_NEXT: begin
                if (c_ent[15] || c_i == 9'd511) cst <= C_IDLE;
                else begin c_i <= c_i + 9'd1; cst <= C_ERD; end
            end
            default: cst <= C_IDLE;
        endcase
    end

    // ================================================================== timing
    // the dot clock: a whole number of machine clocks per dot in the builds (a direct video output, e.g. a RetroTINK 4K's DV1,
    // samples on a fixed grid of machine clocks), else a phase accumulator
    logic [24:0] dacc = '0;
    logic  [4:0] dcnt = '0;
    always_ff @(posedge clk) begin
        if (DOT_DIV != 0) begin
            dcnt   <= (dcnt == 5'(DOT_DIV - 1)) ? 5'd0 : dcnt + 5'd1;
            ce_pix <= (dcnt == 5'd0);
        end else begin
            dacc   <= {1'b0, dacc[23:0]} + {1'b0, dot_inc};
            ce_pix <= dacc[24];
        end
    end
    logic [9:0] hc;
    logic [8:0] vc;
    always_ff @(posedge clk) begin
        if (rst) begin hc <= '0; vc <= '0; end
        else if (ce_pix) begin
            if (hc == h_total - 10'd1) begin
                hc <= '0;
                vc <= (vc == v_total - 9'd1) ? 9'd0 : vc + 9'd1;
            end else hc <= hc + 10'd1;
        end
    end
    wire [9:0] h_end = h_start + {1'b0, h_width};
    wire [8:0] v_end = v_start + v_height;

    // MAME's vpos of the line being drawn: (vc - v_start) mod v_total, + 1 from dot h_start on; two registered steps, so mvpos
    // follows hc / vc 2 clocks late (lstart is delayed to match)
    wire signed [10:0] vl0  = $signed({2'd0, vc}) - $signed({2'd0, v_start}) + ((hc >= h_start) ? 11'sd1 : 11'sd0);
    logic signed [10:0] vl1;
    logic        [8:0]  mvpos;
    always_ff @(posedge clk) begin
        vl1   <= (vl0 < 0) ? (vl0 + $signed({2'd0, v_total})) : vl0;
        mvpos <= (vl1 >= $signed({2'd0, v_total})) ? 9'(vl1 - $signed({2'd0, v_total})) : vl1[8:0];
    end
    assign dbg_mvpos = mvpos;
    logic       lstart, lstart0, lstart1;                                 // MAME's line mvpos has just begun
    always_ff @(posedge clk) begin
        lstart0 <= ce_pix && (hc == h_start - 10'd1);
        lstart1 <= lstart0;
        lstart  <= lstart1;
    end

    // ================================================================== zoom / offset (draw_sprites)
    wire [26:0] yoffset = 27'h7ffffff - {vr[5'h0d][10:0], vr[5'h0c]};
    wire [26:0] yz0     = {vr[5'h0f][10:0], vr[5'h0e]};
    wire        yinv    = yz0[26];
    wire [26:0] yzoom   = yinv ? (27'h0 - yz0) : yz0;                     // 0x8000000 - yzoom, in 27 bits
    wire signed [10:0] xoff_int = $signed(vr[5'h09][10:0]);               // ((r12 << 16 | r10) & 0x7ffffff) >> 16, signed
    wire [31:0] xz0     = {vr[5'h0b], vr[5'h0a]};
    wire [31:0] xzoom   = xz0[26] ? (32'h0800_0000 - xz0) : xz0;

    // inc2 = 2^32 / xzoom (uint32), recomputed when xzoom changes: a restoring divider of the 33-bit dividend 2^32
    logic [31:0] inc2 = 32'h0001_0000;
    logic [31:0] dv_den, dv_last = 32'h0001_0000;
    logic [32:0] dv_rem, dv_q;
    logic  [5:0] dv_n;
    logic        dv_run = 1'b0;
    wire  [33:0] dv_t = {dv_rem, dv_q[32]};
    always_ff @(posedge clk) begin
        if (!dv_run) begin
            if (xzoom != dv_last && xzoom != 32'd0) begin
                dv_den <= xzoom; dv_last <= xzoom; dv_rem <= 33'd0; dv_q <= 33'h1_0000_0000; dv_n <= 6'd33; dv_run <= 1'b1;
            end
        end else begin
            dv_q <= {dv_q[31:0], (dv_t >= {2'd0, dv_den})};
            dv_rem <= (dv_t >= {2'd0, dv_den}) ? 33'(dv_t - {2'd0, dv_den}) : dv_t[32:0];
            dv_n <= dv_n - 6'd1;
            if (dv_n == 6'd1) begin
                dv_run <= 1'b0;
                inc2 <= {dv_q[30:0], (dv_t >= {2'd0, dv_den})};
            end
        end
    end

    // yy for line y: ((y * yzoom + yoffset) & 0x7ffffff) >> 16, signed at 0x400 (only when the zoom register is "negative")
    logic  [8:0] ln;
    logic [35:0] yprod;
    always_ff @(posedge clk) yprod <= {27'd0, ln} * {9'd0, yzoom};
    wire  [26:0] ysum = yprod[26:0] + yoffset;
    wire signed [10:0] yy = yinv ? $signed(ysum[26:16]) : $signed({2'd0, ln});

    // ================================================================== line scheduler
    logic        rs_start, rs_busy, rs_done;
    logic        r_pend, r_drawing;
    logic  [9:0] r_wait;
    logic [15:0] r_cyc, r_rows;
    wire         blank_scr = vr[5'h18][0] || (xzoom == 32'd0);           // 0x30 bit 0, or no x zoom: nothing drawn
    wire         rast_en   = vr[5'h1e][0];

    always_ff @(posedge clk) begin
        rs_start <= 1'b0;
        dbg_overrun <= 1'b0;
        dbg_line_done <= rs_done;
        if (rst) begin
            r_pend <= 1'b0; r_drawing <= 1'b0;
        end else begin
            if (lstart && mvpos < v_height) begin
                if (r_pend || r_drawing) dbg_overrun <= 1'b1;
                ln     <= mvpos;
                r_pend <= 1'b1;
                r_wait <= rast_en ? rdly : 10'd0;
            end else if (r_pend && ce_pix && r_wait != 10'd0) r_wait <= r_wait - 10'd1;
            if (r_pend && r_wait == 10'd0 && !r_drawing && !rs_busy && !dv_run && !lstart) begin
                r_pend <= 1'b0;
                rs_start <= 1'b1; r_drawing <= 1'b1;          // (blanked: the renderer only clears the line)
            end
            if (rs_done) begin r_drawing <= 1'b0; dbg_line_cycles <= r_cyc; dbg_line_rows <= r_rows; end
        end
    end

    // display side of the line buffer
    logic        dsp_rd;
    logic  [8:0] dsp_line, dsp_x;
    logic [14:0] dsp_q;

    s2_render u_render (
        .clk(clk), .rst(rst),
        .start(rs_start), .blank(blank_scr), .lb_sel(ln[0]), .realscanline(ln), .scanline(yy), .xoff_int(xoff_int), .xzoom(inc2),
        .width(h_width), .tile_mask(tile_mask), .tile_count(tile_count), .busy(rs_busy), .done(rs_done),
        .pl_addr(pl_ra), .pl_q(pl_q),
        .sr_addr(sb_addr), .sr_q(sb_qr),
        .gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
        .dsp_rd(dsp_rd), .dsp_sel(dsp_line[0]), .dsp_x(dsp_x), .dsp_q(dsp_q),
        .st_rows(r_rows), .st_cycles(r_cyc)
    );

    // ================================================================== interrupts
    always_ff @(posedge clk) begin
        if (rst) irq_vblank <= 1'b0;
        else if (lstart && mvpos == v_height) irq_vblank <= 1'b1;
        else if (lstart && mvpos == 9'd0) irq_vblank <= 1'b0;
    end

    // raster: a write to 0x3c arms MAME's one-shot timer for (m_rasterposition, hpos): hpos 0 (the start of that line), or the
    // current hpos + 0x100 (half a line on) when that line is the current one; when it fires with 0x3c bit 0 set: the IRQ
    logic        rt_line_armed, rt_half_armed;
    logic [15:0] rt_line;
    logic  [9:0] rt_half;
    always_ff @(posedge clk) begin
        irq_raster <= 1'b0;
        if (rst) begin rt_line_armed <= 1'b0; rt_half_armed <= 1'b0; end
        else if (rast_arm) begin
            if (vr[5'h1f] == {7'd0, mvpos}) begin
                rt_half_armed <= 1'b1; rt_line_armed <= 1'b0; rt_half <= {1'b0, h_total[9:1]};
            end else begin
                rt_line_armed <= 1'b1; rt_half_armed <= 1'b0; rt_line <= vr[5'h1f];
            end
        end else begin
            if (rt_line_armed && lstart && {7'd0, mvpos} == rt_line) begin
                rt_line_armed <= 1'b0;
                if (vr[5'h1e][0]) irq_raster <= 1'b1;
            end
            if (rt_half_armed && ce_pix) begin
                if (rt_half == 10'd0) begin
                    rt_half_armed <= 1'b0;
                    if (vr[5'h1e][0]) irq_raster <= 1'b1;
                end else rt_half <= rt_half - 10'd1;
            end
        end
    end

    // ================================================================== display
    // At a dot (ce_pix) the counters show dot hc of line vc: the line buffer is read, the pixel comes 3 clocks later, the palette 2
    // more, and the colour is set by the next dot -- together with the blanks / syncs of the same dot.
    always_comb begin
        dsp_line = vc - v_start;
        dsp_x    = 9'(hc - h_start);
        dsp_rd   = ce_pix && (hc >= h_start) && (hc < h_end) && (vc >= v_start) && (vc < v_end);
    end
    logic  [5:0] dsp_d;
    logic        hb0, vb0, hs0, vs0;
    always_ff @(posedge clk) begin
        dsp_d <= {dsp_d[4:0], dsp_rd};
        if (dsp_d[2]) pb_addr <= dsp_q;
        if (ce_pix) begin
            hb0 <= !((hc >= h_start) && (hc < h_end));
            vb0 <= !((vc >= v_start) && (vc < v_end));
            hs0 <= (hc <= h_sync);
            vs0 <= (vc <= v_sync);
        end
        if (dsp_d[4]) begin
            r <= {pb_q[14:10], pb_q[14:12]};
            g <= {pb_q[9:5],   pb_q[9:7]};
            b <= {pb_q[4:0],   pb_q[4:2]};
        end
        if (dsp_d[5]) begin hblank <= hb0; vblank <= vb0; hsync <= hs0; vsync <= vs0; end
        if (ce_pix && !dsp_rd) begin
            // outside the picture the blanks / syncs follow the counters directly and the colour is black
            hblank <= !((hc >= h_start) && (hc < h_end));
            vblank <= !((vc >= v_start) && (vc < v_end));
            hsync  <= (hc <= h_sync);
            vsync  <= (vc <= v_sync);
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end
        if (rst) dsp_d <= '0;
    end

endmodule
`default_nettype wire
