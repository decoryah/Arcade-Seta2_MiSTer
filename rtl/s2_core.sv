// The seta2.cpp machine: TMP68301 (fx68k + s2_tmp68301 in s2_main), the X1-020 / DX-101 video chip (s2_video), the X1-010
// (ppriest's x1_010.sv: MAME's x1_010.cpp transcribed), the 93C46 EEPROM (gundamex), the program cache.  The memories outside
// (SDRAM, DDR3) are s2_mem's: graphics rows, program cache fills, slow RAM and sample bytes go there.
`default_nettype none
module s2_core #(
    parameter [31:0] CLK_HZ  = 32'd96_000_000,    // the machine clock (the build's: Seta2.sv)
    parameter int    DOT_DIV = 0                  // machine clocks per dot (0: the header's dot_inc accumulator)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        pause,
    input  logic  [1:0] turbo,              // the 68000 alone faster: 1 = +25 %, 2 = the machine clock / 4 (s2_cen.sv)

    // configuration (MRA header, s2_mem)
    input  logic  [2:0] cfg_map,
    input  logic        cfg_alt_clk,        // CPU / X1-010 at 32.53047 MHz / 2
    input  logic        cfg_eeprom,         // the 93C46 on the parallel port (gundamex)
    input  logic  [4:0] cfg_snd_pages,      // x1snd size / 128 KB - 1
    input  logic [23:0] dot_inc,
    input  logic  [9:0] h_total, h_sync, h_start,
    input  logic  [8:0] h_width,
    input  logic  [8:0] v_total, v_sync, v_start, v_height,
    input  logic  [9:0] rdly,
    input  logic [18:0] tile_mask,
    input  logic [19:0] tile_count,
    input  logic        cache_inval,

    // inputs (as the driver's ports, active low)
    // the light-gun games' battery RAM: its second port (s2_main) and the game's writes
    input  logic [12:0] nv_b_addr,
    input  logic        nv_b_we,
    input  logic  [7:0] nv_b_din,
    output logic  [7:0] nv_b_q,
    output logic        nv_written,
    input  logic [15:0] in_p1, in_p2, in_sys, in_dsw1, in_dsw2, in_ex0, in_ex1, in_ex2,
    input  logic [5:0]  mj_keys [10],       // mj4simai: KEY0..4 (player 1), KEY5..9 (player 2), active low
    // EEPROM image
    input  logic        ee_init_we,
    input  logic  [5:0] ee_init_addr,
    input  logic [15:0] ee_init_data,

    // graphics ROM
    output logic        gf_req,
    output logic [21:0] gf_addr,
    input  logic        gf_ready,
    input  logic        gf_valid,
    input  logic [63:0] gf_data,
    // program cache fills
    output logic        pf_req,
    output logic [21:5] pf_addr,
    input  logic        pf_wr,
    input  logic  [1:0] pf_idx,
    input  logic [63:0] pf_data,
    input  logic        pf_done,
    // slow RAM
    output logic        sr_req,
    output logic        sr_we,
    output logic [18:1] sr_addr,
    output logic [15:0] sr_din,
    output logic  [1:0] sr_be,
    input  logic        sr_ack,
    input  logic [15:0] sr_dout,
    // X1-010 samples
    output logic        sn_req,
    output logic [21:0] sn_addr,
    input  logic        sn_ack,
    input  logic [63:0] sn_data,          // the whole DDR3 beat

    // video / audio
    output logic        ce_pix, hblank, vblank, hsync, vsync,
    output logic  [7:0] r, g, b,
    output logic signed [15:0] audio,

    output logic        dbg_overrun, dbg_vbl,
    output logic        cpu_halted
);
    // ------------------------------------------------------------------ clocks
    logic cen_phi1, cen_phi2, tick;
    s2_cen #(.MCLK(CLK_HZ)) u_cen (.clk(clk), .alt(cfg_alt_clk), .hold(pause), .turbo(turbo), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .tick(tick));

    // ------------------------------------------------------------------ main board
    logic        rom_req, rom_ack;
    logic [21:1] rom_addr;
    logic [15:0] rom_data;
    logic        v_req, v_we, v_ack;
    logic [18:1] v_addr;
    logic [15:0] v_din, v_dout;
    logic  [1:0] v_be;
    logic        x_req, x_we, x_uds, x_lds;
    logic [12:0] x_addr;
    logic [15:0] x_din, x_dout;
    logic  [7:0] snd_bank [8];
    logic  [7:0] key_row;
    logic        irq_vblank, irq_raster;
    logic [15:0] par_in, par_out;
    logic        par_wr;
    logic        ee_do;

    // mj4simai_key_r: the rows selected by key_row (bits 0..4), ANDed: 0xffc0 | result
    logic [15:0] in_key0, in_key1;
    always_comb begin
        logic [5:0] k0, k1;
        k0 = 6'h3f; k1 = 6'h3f;
        for (int i = 0; i < 5; i++) if (key_row[i]) begin k0 = k0 & mj_keys[i]; k1 = k1 & mj_keys[5 + i]; end
        in_key0 = {10'h3ff, k0};
        in_key1 = {10'h3ff, k1};
    end

    // the parallel port: gundamex reads the EEPROM's DO at bit 3 (the other bits 0); the others' callback is the default 0xffff
    // the parallel port's pins: Gundam EX's 93C46 data out; the light-gun board's second DIP bank (MAME: "DSW2 // fffd0a.w")
    assign par_in = cfg_eeprom ? {12'd0, ee_do, 3'd0} : (cfg_map == 3'd7) ? in_dsw2 : 16'hffff;

    s2_main u_main (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cpu_tick(tick), .cfg_map(cfg_map),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .sr_req(sr_req), .sr_we(sr_we), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be), .sr_ack(sr_ack), .sr_dout(sr_dout),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_din(v_din), .v_be(v_be), .v_ack(v_ack), .v_dout(v_dout),
        .x_req(x_req), .x_we(x_we), .x_addr(x_addr), .x_din(x_din), .x_uds(x_uds), .x_lds(x_lds), .x_dout(x_dout),
        .snd_bank(snd_bank),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_dsw1(in_dsw1), .in_dsw2(in_dsw2), .in_ex0(in_ex0), .in_ex1(in_ex1), .in_ex2(in_ex2),
        .nv_b_addr(nv_b_addr), .nv_b_we(nv_b_we), .nv_b_din(nv_b_din), .nv_b_q(nv_b_q), .nv_written(nv_written),
        .in_key0(in_key0), .in_key1(in_key1), .key_row(key_row),
        .irq_vblank(irq_vblank), .irq_raster(irq_raster),
        .par_in(par_in), .par_out(par_out), .par_wr(par_wr),
        .cpu_halted(cpu_halted), .dbg_pc_addr()
    );

    s2_cache u_cache (
        .clk(clk), .inval(cache_inval), .busy(),
        .req(rom_req), .addr(rom_addr), .ack(rom_ack), .data(rom_data),
        .fill_req(pf_req), .fill_addr(pf_addr), .fill_wr(pf_wr), .fill_idx(pf_idx), .fill_data(pf_data), .fill_done(pf_done)
    );

    s2_eeprom u_eeprom (
        .clk(clk), .rst(rst),
        .wr(par_wr && cfg_eeprom), .cs_in(par_out[2]), .clk_in(par_out[1]), .di_in(par_out[0]), .dout(ee_do),
        .init_we(ee_init_we), .init_addr(ee_init_addr), .init_data(ee_init_data),
        .rd_addr(6'd0), .rd_data(), .dirty()
    );

    // ------------------------------------------------------------------ video
    s2_video #(.DOT_DIV(DOT_DIV)) u_video (
        .clk(clk), .rst(rst),
        .cpu_req(v_req), .cpu_we(v_we), .cpu_addr(v_addr), .cpu_din(v_din), .cpu_be(v_be), .cpu_dout(v_dout), .cpu_ack(v_ack),
        .dot_inc(dot_inc), .h_total(h_total), .h_sync(h_sync), .h_start(h_start), .h_width(h_width),
        .v_total(v_total), .v_sync(v_sync), .v_start(v_start), .v_height(v_height), .rdly(rdly),
        .tile_mask(tile_mask), .tile_count(tile_count),
        .irq_vblank(irq_vblank), .irq_raster(irq_raster),
        .gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
        .dbg_overrun(dbg_overrun), .dbg_line_cycles(), .dbg_line_rows(), .dbg_mvpos(), .dbg_line_done(),
        .bd_we(1'b0), .bd_sel(2'd0), .bd_addr(15'd0), .bd_data(64'd0)
    );
    assign dbg_vbl = irq_vblank;

    // ------------------------------------------------------------------ sound
    // the X1-010 reads its 1 MB sample space through 8 banks of 128 KB (seta2_state::x1_map / sound_bank_w): page = bank % pages
    logic        x1_rom_req, x1_rom_valid;
    logic [19:0] x1_rom_addr;
    logic  [7:0] x1_rom_data;
    logic signed [15:0] x1_l, x1_r;
    x1_010 u_x1 (
        .clk(clk), .reset(rst), .ce(tick),
        .cpu_req(x_req), .cpu_we(x_we), .cpu_addr(x_addr), .cpu_wdata(x_din), .cpu_uds(x_uds), .cpu_lds(x_lds), .cpu_rdata(x_dout),
        .rom_req(x1_rom_req), .rom_addr(x1_rom_addr), .rom_valid(x1_rom_valid), .rom_data(x1_rom_data),
        .audio_l(x1_l), .audio_r(x1_r), .audio_stb(),
        .dbg_samples(), .dbg_overrun(), .dbg_rom_reads()
    );
    // a 16-beat direct-mapped cache of the sample bytes (a playing channel reads consecutive bytes: ~8 per DDR3 beat)
    logic [63:0] sc_dat [16];
    logic [14:0] sc_tag [16];
    logic [15:0] sc_val;
    logic        sc_look;
    logic [21:0] sc_a;
    always_ff @(posedge clk) begin
        x1_rom_valid <= 1'b0;
        sc_look <= 1'b0;
        if (rst) begin sn_req <= 1'b0; sc_val <= 16'd0; end
        else begin
            if (x1_rom_req) begin
                sc_a    <= {snd_bank[x1_rom_addr[19:17]][4:0] & cfg_snd_pages, x1_rom_addr[16:0]};
                sc_look <= 1'b1;
            end
            if (sc_look) begin
                if (sc_val[sc_a[6:3]] && sc_tag[sc_a[6:3]] == sc_a[21:7]) begin
                    x1_rom_valid <= 1'b1; x1_rom_data <= sc_dat[sc_a[6:3]][8 * sc_a[2:0] +: 8];
                end else begin
                    sn_req <= 1'b1; sn_addr <= sc_a;
                end
            end
            if (sn_req && sn_ack) begin
                sn_req <= 1'b0;
                sc_dat[sn_addr[6:3]] <= sn_data; sc_tag[sn_addr[6:3]] <= sn_addr[21:7]; sc_val[sn_addr[6:3]] <= 1'b1;
                x1_rom_valid <= 1'b1; x1_rom_data <= sn_data[8 * sn_addr[2:0] +: 8];
            end
        end
    end
    // MAME routes both outputs to the mono speaker at 1.0: L + R, clipped
    wire signed [16:0] mix = x1_l + x1_r;
    always_ff @(posedge clk) audio <= (mix > 17'sd32767) ? 16'sd32767 : (mix < -17'sd32768) ? -16'sd32768 : mix[15:0];

endmodule
`default_nettype wire
