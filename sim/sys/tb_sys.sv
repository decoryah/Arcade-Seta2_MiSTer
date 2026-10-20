// Whole-machine bench of the seta2 core: s2_core + s2_mem (with the SDRAM chip model); the DDR3 is the C++ driver's
// (tb_sys.cpp).  The configuration header comes in through the loader's byte port as an ordinary download would bring it; the
// ROM contents are put into the SDRAM model and the DDR3 model by the driver (the fast-load copy of 32 MB would take minutes of
// simulation; sim/sys/run.sh +fastload runs it for real).  Inputs and the EEPROM image loading are as in Seta2.sv.
`default_nettype none
module tb_sys #(
    parameter [31:0] CLK_HZ  = 32'd96_000_000,    // a build's machine clock / clocks per dot (Seta2.sv; run.sh VFLAGS)
    parameter int    DOT_DIV = 0
) (
    input  logic        clk,
    input  logic        sd_init,
    input  logic        mc_rst_in,

    // loader byte port
    input  logic        dl_we,
    input  logic [26:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait, dl_busy,
    input  logic        fl_go,
    input  logic [26:0] fl_len,
    output logic        fl_busy,
    output logic        sd_ready,

    // inputs: joystick bits as Seta2.sv's (0 R, 1 L, 2 D, 3 U, 4..7 buttons, 8 start, 9 coin, 10 service), DIPs
    input  logic [15:0] joy1, joy2,
    input  logic  [7:0] dsw1, dsw2, jumpers,
    input  logic        pause,
    input  logic  [9:0] rdly,

    // DDR3
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE,

    output logic        ce_pix, hblank, vblank, hsync, vsync,
    output logic  [7:0] r, g, b,
    output logic signed [15:0] audio,
    output logic        dbg_overrun, cpu_halted, mc_rst
);
    logic [7:0] cfg [64];
    wire  [2:0] cfg_map    = cfg[2][2:0];
    wire  [7:0] cfg_flags  = cfg[3];

    logic        gf_req, gf_ready, gf_valid, pf_req, pf_wr, pf_done, sr_req, sr_we, sr_ack, sn_req, sn_ack;
    logic [21:0] gf_addr, sn_addr;
    logic [63:0] gf_data, pf_data;
    logic [21:5] pf_addr;
    logic  [1:0] pf_idx, sr_be;
    logic [18:1] sr_addr;
    logic [15:0] sr_din, sr_dout;
    logic [63:0] sn_data;
    logic  [7:0] ee_q;
    logic  [6:0] ee_raddr;

    wire  [15:0] dq;
    logic [12:0] sa;
    logic  [1:0] sba;
    logic        dqml, dqmh, ncs, nwe, nras, ncas, cke, sclk;

    s2_mem #(.CLK_HZ(CLK_HZ)) u_mem (
        .clk(clk), .clk_sdram(clk), .init(sd_init), .rd_late(1'b0), .ready(sd_ready),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait), .dl_busy(dl_busy),
        .fl_go(fl_go), .fl_len(fl_len), .fl_busy(fl_busy), .cfg(cfg), .ee_addr(ee_raddr), .ee_q(ee_q),
        .gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
        .pf_req(pf_req), .pf_addr(pf_addr), .pf_wr(pf_wr), .pf_idx(pf_idx), .pf_data(pf_data), .pf_done(pf_done),
        .sr_req(sr_req), .sr_we(sr_we), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be), .sr_ack(sr_ack), .sr_dout(sr_dout),
        .sn_req(sn_req), .sn_addr(sn_addr), .sn_ack(sn_ack), .sn_data(sn_data),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(sba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke), .SDRAM_CLK(sclk),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
        .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );
    sdram_bl4_model #(.AW(24)) u_chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(ncs), .ras_n(nras), .cas_n(ncas), .we_n(nwe), .cke(cke)
    );

    // (mc_rst_in stands for Seta2.sv's reset and ROM download)
    wire loading = mc_rst_in | dl_busy | fl_busy | ~sd_ready;
    wire ee_busy;
    always_ff @(posedge clk) mc_rst <= loading | ee_busy;

    // the EEPROM image (Seta2.sv): copied once the loading has finished
    logic  [7:0] ee_cnt = 8'd130;
    logic        ee_we;
    logic  [5:0] ee_wa;
    logic [15:0] ee_wd;
    logic  [7:0] ee_hi;
    assign ee_raddr = ee_cnt[6:0];
    assign ee_busy  = ee_cnt != 8'd130;
    always_ff @(posedge clk) begin
        ee_we <= 1'b0;
        if (loading) ee_cnt <= 8'd0;
        else if (ee_busy) begin
            ee_cnt <= ee_cnt + 8'd1;
            if (ee_cnt != 8'd0) begin
                if (!ee_cnt[0]) begin ee_we <= 1'b1; ee_wa <= ee_cnt[6:1] - 6'd1; ee_wd <= {ee_hi, ee_q}; end
                else ee_hi <= ee_q;
            end
        end
    end

    // inputs (Seta2.sv)
    wire j1_r = joy1[0], j1_l = joy1[1], j1_d = joy1[2], j1_u = joy1[3];
    wire j2_r = joy2[0], j2_l = joy2[1], j2_d = joy2[2], j2_u = joy2[3];
    wire [3:0] j1_b = joy1[7:4], j2_b = joy2[7:4];
    wire start1 = joy1[8], start2 = joy2[8], svc = joy1[10] | joy2[10];
    // coins as MAME's PORT_IMPULSE(5) (Seta2.sv)
    logic       dbg_vbl;
    logic [2:0] coin1_n = 3'd0, coin2_n = 3'd0;
    logic       coin1_d, coin2_d, cvbl_d;
    always_ff @(posedge clk) begin
        coin1_d <= joy1[9]; coin2_d <= joy2[9]; cvbl_d <= dbg_vbl;
        if (joy1[9] && !coin1_d) coin1_n <= 3'd5; else if (dbg_vbl && !cvbl_d && coin1_n != 3'd0) coin1_n <= coin1_n - 3'd1;
        if (joy2[9] && !coin2_d) coin2_n <= 3'd5; else if (dbg_vbl && !cvbl_d && coin2_n != 3'd0) coin2_n <= coin2_n - 3'd1;
    end
    wire coin1 = coin1_n != 3'd0, coin2 = coin2_n != 3'd0;
    wire b3_on  = !cfg_flags[6];
    wire [15:0] in_dsw1 = {8'hff, dsw1};
    wire [15:0] in_dsw2 = {8'hff, dsw2};
    logic [15:0] in_p1, in_p2, in_sys, in_ex0, in_ex1;
    always_comb begin
        if (cfg_flags[2]) begin
            in_p1 = {8'hff, ~{start1, j1_b[0], j1_b[1], j1_b[2], j1_b[3]}, 3'b111};
            in_p2 = {8'hff, ~{start2, j2_b[0], j2_b[1], j2_b[2], j2_b[3]}, 3'b111};
        end else begin
            in_p1 = {8'hff, ~{start1, j1_b[2] & b3_on, j1_b[1], j1_b[0], j1_d, j1_u, j1_r, j1_l}};
            in_p2 = {8'hff, ~{start2, j2_b[2] & b3_on, j2_b[1], j2_b[0], j2_d, j2_u, j2_r, j2_l}};
        end
        if (cfg_flags[5])      in_sys = {8'hff, 2'b11, jumpers[0], 2'b11, ~svc, ~coin2, ~coin1};
        else if (cfg_flags[4]) in_sys = {8'hff, 1'b0, 3'b111, 1'b1, ~svc, ~coin2, ~coin1};
        else                   in_sys = {8'hff, 4'b1111, 1'b1, ~svc, ~coin2, ~coin1};
        in_ex0 = {15'h7fff, ~j1_b[3]};
        in_ex1 = {15'h7fff, ~j2_b[3]};
    end
    logic [5:0] mj_keys [10];
    always_comb begin
        for (int i = 0; i < 10; i++) mj_keys[i] = 6'h3f;
        mj_keys[0][5] = ~start1;
        mj_keys[5][5] = ~start2;
    end

    // +turbo=N: the CPU speed setting (0 the board's, 1 +25 %, 2 the machine clock / 4)
    logic [1:0] turbo_sel = 2'd0;
    initial begin
        int tv;
        if ($value$plusargs("turbo=%d", tv)) turbo_sel = 2'(tv);
    end

    s2_core #(.CLK_HZ(CLK_HZ), .DOT_DIV(DOT_DIV)) u_core (
        .clk(clk), .rst(mc_rst), .pause(pause), .turbo(turbo_sel),
        .cfg_map(cfg_map), .cfg_alt_clk(cfg_flags[0]), .cfg_eeprom(cfg_flags[1]), .cfg_snd_pages(cfg[32][4:0]),
        .dot_inc({cfg[6], cfg[5], cfg[4]}),
        .h_total({cfg[9][1:0], cfg[8]}), .h_sync({cfg[11][1:0], cfg[10]}), .h_start({cfg[13][1:0], cfg[12]}), .h_width({cfg[15][0], cfg[14]}),
        .v_total({cfg[17][0], cfg[16]}), .v_sync({cfg[19][0], cfg[18]}), .v_start({cfg[21][0], cfg[20]}), .v_height({cfg[23][0], cfg[22]}),
        .rdly(rdly), .tile_mask({cfg[26][2:0], cfg[25], cfg[24]}), .tile_count({cfg[30][3:0], cfg[29], cfg[28]}),
        .cache_inval(mc_rst_in),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_dsw1(in_dsw1), .in_dsw2(in_dsw2), .in_ex0(in_ex0), .in_ex1(in_ex1),
        .mj_keys(mj_keys),
        .ee_init_we(ee_we), .ee_init_addr(ee_wa), .ee_init_data(ee_wd),
        .gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
        .pf_req(pf_req), .pf_addr(pf_addr), .pf_wr(pf_wr), .pf_idx(pf_idx), .pf_data(pf_data), .pf_done(pf_done),
        .sr_req(sr_req), .sr_we(sr_we), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be), .sr_ack(sr_ack), .sr_dout(sr_dout),
        .sn_req(sn_req), .sn_addr(sn_addr), .sn_ack(sn_ack), .sn_data(sn_data),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
        .audio(audio), .dbg_overrun(dbg_overrun), .dbg_vbl(dbg_vbl), .cpu_halted(cpu_halted)
    );

    // +vwlog=FILE: every CPU write the video chip takes, "frame offset data mask" (offset from the chip's base, as
    // tools/capture.py --wlog writes MAME's; frames counted at the start of each vertical blank, as tb_sys.cpp does)
    integer vw_fd = 0;
    int     vw_frame = 0;
    logic   vw_vbl = 1'b0;
    initial begin
        string fn;
        if ($value$plusargs("vwlog=%s", fn)) vw_fd = $fopen(fn, "w");
    end
    always_ff @(posedge clk) begin
        vw_vbl <= vblank;
        if (vblank && !vw_vbl) vw_frame <= vw_frame + 1;
        if (vw_fd != 0 && u_core.u_video.a_take && u_core.u_video.cpu_we)
            $fwrite(vw_fd, "%0d %05x %04x %04x\n", vw_frame, {u_core.u_video.cpu_addr, 1'b0},
                    u_core.u_video.cpu_din, {{8{u_core.u_video.cpu_be[1]}}, {8{u_core.u_video.cpu_be[0]}}});
    end

    // +romtrace=HEX (a program byte address): the CPU's reads of that word, the cache fills of its line, and every DDR3 write
    // outside the slow RAM (none expected once the machine runs)
    logic [21:1] rt_a = '1;
    logic        rt_on = 1'b0;
    initial begin
        int unsigned v;
        if ($value$plusargs("romtrace=%h", v)) begin rt_a = v[21:1]; rt_on = 1'b1; end
    end
    always_ff @(posedge clk) if (rt_on) begin
        if (u_core.rom_ack && u_core.rom_addr == rt_a)
            $display("ROMTRACE f%0d read %06x = %04x", vw_frame, {rt_a, 1'b0}, u_core.rom_data);
        if (pf_wr && pf_addr == rt_a[21:5])
            $display("ROMTRACE f%0d fill line %06x beat %0d = %016x", vw_frame, {pf_addr, 5'd0}, pf_idx, pf_data);
        if (DDRAM_WE && !DDRAM_BUSY && !mc_rst && DDRAM_ADDR[28:16] != 13'h0660)
            $display("ROMTRACE f%0d DDR3 write beat %07x be %02x data %016x", vw_frame, DDRAM_ADDR, DDRAM_BE, DDRAM_DIN);
    end
endmodule
`default_nettype wire
