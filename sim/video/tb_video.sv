// Frozen-state bench of the video chip: s2_video with the graphics ROM either in the SDRAM (s2_sdram + sdram_bl4_model, the real
// path) or, with -DIDEAL_GFX, answered by the C++ driver (an in-order memory with a fixed latency).  tb_video.cpp loads a MAME state
// through the back door, runs a frame and compares the picture with MAME's.
`default_nettype none

module tb_video (
    input  logic        clk,
    input  logic        rst,
    input  logic        sd_init,

    input  logic [23:0] dot_inc,
    input  logic  [9:0] h_total, h_sync, h_start,
    input  logic  [8:0] h_width,
    input  logic  [8:0] v_total, v_sync, v_start, v_height,
    input  logic  [9:0] rdly,
    input  logic [18:0] tile_mask,
    input  logic [19:0] tile_count,
    input  logic        rd_late,

    input  logic        bd_we,
    input  logic  [1:0] bd_sel,
    input  logic [14:0] bd_addr,
    input  logic [63:0] bd_data,

    // CPU port (register writes from the bench: the copy engine test)
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [18:1] cpu_addr,
    input  logic [15:0] cpu_din,
    input  logic  [1:0] cpu_be,
    output logic [15:0] cpu_dout,
    output logic        cpu_ack,

    output logic        ce_pix, hblank, vblank, hsync, vsync,
    output logic  [7:0] r, g, b,
    output logic        irq_vblank, irq_raster,
    output logic        dbg_overrun, dbg_line_done,
    output logic [15:0] dbg_line_cycles, dbg_line_rows,
    output logic  [8:0] dbg_mvpos,
    output logic        sd_ready,

    // ideal graphics memory (IDEAL_GFX): requests out, rows in
    output logic        gf_req,
    output logic [21:0] gf_addr,
    input  logic        x_ready,
    input  logic        x_valid,
    input  logic [63:0] x_data,
    output logic        gf_ready_o
);
    logic        gf_ready, gf_valid;
    logic [63:0] gf_data;

    s2_video u_video (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_dout(cpu_dout),
        .cpu_ack(cpu_ack),
        .dot_inc(dot_inc), .h_total(h_total), .h_sync(h_sync), .h_start(h_start), .h_width(h_width),
        .v_total(v_total), .v_sync(v_sync), .v_start(v_start), .v_height(v_height), .rdly(rdly),
        .tile_mask(tile_mask), .tile_count(tile_count),
        .irq_vblank(irq_vblank), .irq_raster(irq_raster),
        .gf_req(gf_req), .gf_addr(gf_addr), .gf_ready(gf_ready), .gf_valid(gf_valid), .gf_data(gf_data),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
        .dbg_overrun(dbg_overrun), .dbg_line_cycles(dbg_line_cycles), .dbg_line_rows(dbg_line_rows), .dbg_mvpos(dbg_mvpos),
        .dbg_line_done(dbg_line_done),
        .bd_we(bd_we), .bd_sel(bd_sel), .bd_addr(bd_addr), .bd_data(bd_data)
    );
    assign gf_ready_o = gf_ready;

`ifdef IDEAL_GFX
    assign gf_ready = x_ready;
    assign gf_valid = x_valid;
    assign gf_data  = x_data;
    assign sd_ready = 1'b1;
`else
    wire  [15:0] dq;
    logic [12:0] sa;
    logic  [1:0] sba;
    logic        dqml, dqmh, ncs, nwe, nras, ncas, cke, sclk;
    s2_sdram u_sdram (
        .clk(clk), .clk_pin(clk), .init(sd_init), .rd_late(rd_late), .ready(sd_ready),
        .rq(gf_req), .rq_addr(gf_addr), .rq_ready(gf_ready), .rd_valid(gf_valid), .rd_data(gf_data),
        .wq(1'b0), .w_addr(24'd0), .w_data(16'd0), .w_ack(),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(sba),
        .SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke), .SDRAM_CLK(sclk)
    );
    sdram_bl4_model #(.AW(24)) u_chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(ncs), .ras_n(nras), .cas_n(ncas), .we_n(nwe), .cke(cke)
    );
`endif
endmodule
`default_nettype wire
