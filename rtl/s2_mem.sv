// Memory of the seta2 core on MiSTer: the SDRAM (graphics ROM, s2_sdram), the DDR3 (program ROM, X1-010 samples, slow RAM), the
// ROM loader and the fast load.
//
// The MRA's image (tools/make_mra.py; byte offsets):
//   0x0000000-0x0000FFF  header: configuration bytes (0x00..0x3F, cfg below), 93C46 EEPROM image (0x100..0x17F)
//   0x0100000-0x04FFFFF  program: MAME's "maincpu" region in the 68000's byte order (4 MB: gundamex's 500000-57FFFF at +0x200000)
//   0x0500000-0x08FFFFF  X1-010 samples, MAME's "x1snd" (up to 4 MB)
//   0x0900000-...        graphics, MAME's "video" region exactly (up to 32 MB; zeros where MAME's region is erased)
// The DDR3 holds the image at byte 0x30000000 (BASE): with fast load (MRA address="0x30000000") Main_MiSTer puts it there itself and
// only the graphics are copied into the SDRAM; with an ordinary download the program and samples are written into the DDR3 here
// and the graphics go to the SDRAM.  The slow RAM is at DDR3 byte 0x33000000 (image + 0x3000000), 512 KB.
//
// DDR3 (the framework's DDRAM_*: Avalon, 64-bit beats, DDRAM_ADDR = byte address / 8): one transaction at a time, clients by
// priority: program cache line fill (4 beats), slow RAM (1 beat), X1-010 sample (1 beat), loader write (1 beat), fast-load read
// (32 beats).  A beat holds image bytes 8b..8b+7 in its bytes 0..7.
`default_nettype none
module s2_mem #(
    parameter [28:0] BASE = 29'h6000000,                 // byte 0x30000000 / 8
    parameter [31:0] CLK_HZ = 32'd96_000_000             // the machine clock: the SDRAM's refresh interval (~7.6 us)
) (
    input  logic        clk,
    input  logic        clk_sdram,
    input  logic        init,
    input  logic        rd_late,
    output logic        ready,                           // SDRAM up

    // loader: ioctl bytes (sequential), or the fast load
    input  logic        dl_we,
    input  logic [26:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait,
    output logic        dl_busy,                         // writes still pending
    input  logic        fl_go,                           // pulse: the image (fl_len bytes) is in the DDR3: read the header, copy the graphics
    input  logic [26:0] fl_len,
    output logic        fl_busy,
    output logic [7:0]  cfg [64],                        // header bytes 0x00..0x3F
    // the EEPROM image (header 0x100..0x17F): read port
    input  logic  [6:0] ee_addr,
    output logic  [7:0] ee_q,

    // graphics: the renderer's tile rows
    input  logic        gf_req,
    input  logic [21:0] gf_addr,
    output logic        gf_ready,
    output logic        gf_valid,
    output logic [63:0] gf_data,

    // program cache fills
    input  logic        pf_req,
    input  logic [21:5] pf_addr,
    output logic        pf_wr,
    output logic  [1:0] pf_idx,
    output logic [63:0] pf_data,
    output logic        pf_done,

    // slow RAM (word address in 512 KB)
    input  logic        sr_req,
    input  logic        sr_we,
    input  logic [18:1] sr_addr,
    input  logic [15:0] sr_din,
    input  logic  [1:0] sr_be,
    output logic        sr_ack,
    output logic [15:0] sr_dout,

    // X1-010 sample bytes (offset in the "x1snd" region)
    input  logic        sn_req,
    input  logic [21:0] sn_addr,
    output logic        sn_ack,
    output logic [63:0] sn_data,                         // the beat holding the byte

    // SDRAM
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // DDR3
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE
);
    localparam [26:0] IMG_PROG = 27'h0100000, IMG_SND = 27'h0500000, IMG_VID = 27'h0900000;
    localparam [28:0] SLOW_BEAT = BASE + 29'h0600000;    // image + 0x3000000

    // ================================================================== header
    logic [7:0] cfg_r [64];
    logic [7:0] ee_r  [128];
    initial for (int i = 0; i < 64; i++) cfg_r[i] = 8'd0;
    always_comb for (int i = 0; i < 64; i++) cfg[i] = cfg_r[i];
    always_ff @(posedge clk) ee_q <= ee_r[ee_addr];

    // ================================================================== SDRAM write FIFO (graphics words: the loader, the fast load)
    logic        wf_push;
    logic [39:0] wf_in;                                   // {word address (24), data (16)}
    (* ramstyle = "no_rw_check" *) logic [39:0] wfifo [64];
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire  [6:0]  wf_used  = wf_wp - wf_rp;
    logic [39:0] wf_head;
    logic        sd_wq, sd_wack;
    logic [24:1] sd_waddr;
    logic [15:0] sd_wdata;
    typedef enum logic [1:0] { W_IDLE, W_LD, W_SD } wst_t;
    wst_t wst;
    always_ff @(posedge clk) begin
        if (init) begin wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; sd_wq <= 1'b0; end
        else begin
            if (wf_push) begin wfifo[wf_wp[5:0]] <= wf_in; wf_wp <= wf_wp + 7'd1; end
            case (wst)
                W_IDLE: if (!wf_empty) begin wf_head <= wfifo[wf_rp[5:0]]; wst <= W_LD; end
                W_LD:   begin sd_waddr <= wf_head[39:16]; sd_wdata <= wf_head[15:0]; sd_wq <= 1'b1; wst <= W_SD; end
                W_SD:   if (sd_wack) begin sd_wq <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    s2_sdram #(.CYCLES_PER_REFRESH(14'(CLK_HZ / 32'd1_000_000 * 32'd76 / 32'd10))) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .ready(ready),
        .rq(gf_req), .rq_addr(gf_addr), .rq_ready(gf_ready), .rd_valid(gf_valid), .rd_data(gf_data),
        .wq(sd_wq), .w_addr(sd_waddr), .w_data(sd_wdata), .w_ack(sd_wack),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
    );

    // ================================================================== loader (ioctl bytes)
    // header -> registers; program / samples -> DDR3 beats; graphics -> SDRAM words
    logic [63:0] lb_data;                                 // the beat being assembled
    logic        lw_pend;                                 // a full beat waits for the DDR3
    logic [63:0] lw_data;
    logic [23:0] lw_beat;                                 // beat index in the image
    logic        lw_ack;
    logic  [7:0] lo_byte;                                 // graphics: the even byte of a word
    always_ff @(posedge clk) begin
        wf_push <= 1'b0;
        if (init) lw_pend <= 1'b0;
        if (lw_ack) lw_pend <= 1'b0;
        if (dl_we) begin
            if (dl_addr < 27'h0001000) begin
                if (dl_addr[11:6] == 6'd0) cfg_r[dl_addr[5:0]] <= dl_data;
                if (dl_addr[11:7] == 5'd2) ee_r[dl_addr[6:0]] <= dl_data;
            end else if (dl_addr >= IMG_PROG && dl_addr < IMG_VID) begin
                lb_data[8 * dl_addr[2:0] +: 8] <= dl_data;
                if (dl_addr[2:0] == 3'd7) begin
                    lw_pend <= 1'b1;
                    lw_data <= {dl_data, lb_data[55:0]};
                    lw_beat <= dl_addr[26:3];
                end
            end else if (dl_addr >= IMG_VID) begin
                if (!dl_addr[0]) lo_byte <= dl_data;
                else begin wf_push <= 1'b1; wf_in <= {dl_addr[24:1] - IMG_VID[24:1], dl_data, lo_byte}; end
            end
        end
        // fast load: the header and the graphics come from the DDR3 (below)
        if (fh_wr) begin
            for (int k = 0; k < 8; k++) begin
                if (fh_beat[8:3] == 6'd0) cfg_r[{fh_beat[2:0], 3'(k)}] <= fh_data[8 * k +: 8];
                if (fh_beat[8:4] == 5'd2) ee_r[{fh_beat[3:0], 3'(k)}] <= fh_data[8 * k +: 8];
            end
        end
        if (fg_push) begin wf_push <= 1'b1; wf_in <= fg_word; end
    end
    assign dl_wait = (wf_used >= 7'd48) || lw_pend || fl_busy;
    assign dl_busy = !wf_empty || (wst != W_IDLE) || lw_pend;

    // ================================================================== fast load: header beats 0..47, then the graphics
    typedef enum logic [2:0] { F_IDLE, F_HDR, F_HWAIT, F_VID, F_VWAIT, F_OUT } fst_t;
    fst_t        fst;
    logic        fr_req;                                  // a 32-beat read for the fast load
    logic [23:0] fr_beat;
    logic        fr_wr, fr_done;
    logic [63:0] fr_data;
    logic [63:0] fbuf [32];
    logic  [4:0] fb_wi, fb_ri;
    logic  [1:0] fb_w;                                    // word of the beat going out
    logic [63:0] fb_cur;
    logic [26:0] f_len;
    logic [26:0] f_off;                                   // image offset of the next graphics byte
    logic        fh_wr, fg_push;
    logic  [8:0] fh_beat;
    logic [63:0] fh_data;
    logic [39:0] fg_word;
    always_ff @(posedge clk) begin
        fh_wr <= 1'b0;
        fg_push <= 1'b0;
        if (fr_wr) begin fbuf[fb_wi] <= fr_data; fb_wi <= fb_wi + 5'd1; end
        if (init) begin fst <= F_IDLE; fl_busy <= 1'b0; fr_req <= 1'b0; end
        else case (fst)
            F_IDLE: if (fl_go) begin f_len <= fl_len; fl_busy <= 1'b1; fr_beat <= 24'd0; fb_wi <= '0; fr_req <= 1'b1; fst <= F_HDR; end
            F_HDR: if (fr_done) begin fr_req <= 1'b0; fb_ri <= '0; fh_beat <= 9'd0; fst <= F_HWAIT; end
            F_HWAIT: begin
                // the 32 header beats (0x000-0x0FF) -> cfg; then beats 0x20.. (0x100-0x1FF) for the EEPROM image
                fh_wr <= 1'b1; fh_beat <= {fr_beat[8:5], fb_ri}; fh_data <= fbuf[fb_ri];   // beat fr_beat + fb_ri (fr_beat: 0, 32)
                fb_ri <= fb_ri + 5'd1;
                if (fb_ri == 5'd31) begin
                    if (fr_beat == 24'd0) begin fr_beat <= 24'd32; fb_wi <= '0; fr_req <= 1'b1; fst <= F_HDR; end
                    else begin f_off <= IMG_VID; fr_beat <= IMG_VID[26:3]; fb_wi <= '0; fr_req <= (f_len > IMG_VID); fst <= (f_len > IMG_VID) ? F_VID : F_IDLE;
                               if (!(f_len > IMG_VID)) fl_busy <= 1'b0; end
                end
            end
            F_VID: if (fr_done) begin fr_req <= 1'b0; fb_ri <= '0; fst <= F_VWAIT; end
            F_VWAIT: begin fb_cur <= fbuf[fb_ri]; fb_w <= 2'd0; fst <= F_OUT; end
            F_OUT: if (wf_used < 7'd56) begin
                fg_push <= 1'b1;
                fg_word <= {f_off[24:1] - IMG_VID[24:1], fb_cur[16 * fb_w +: 16]};
                f_off <= f_off + 27'd2;
                fb_w <= fb_w + 2'd1;
                if (f_off + 27'd2 >= f_len) begin fl_busy <= 1'b0; fst <= F_IDLE; end
                else if (fb_w == 2'd3) begin
                    if (fb_ri == 5'd31) begin fr_beat <= fr_beat + 24'd32; fb_wi <= '0; fr_req <= 1'b1; fst <= F_VID; end
                    else begin fb_ri <= fb_ri + 5'd1; fst <= F_VWAIT; end
                end
            end
            default: fst <= F_IDLE;
        endcase
    end
    // (the graphics FIFO entries carry the SDRAM word address: the graphics' byte offset / 2)

    // ================================================================== DDR3
    typedef enum logic [2:0] { R_IDLE, R_CMD, R_DATA } rst_t;
    rst_t        rs;
    typedef enum logic [2:0] { C_PF, C_SR, C_SN, C_LW, C_FR } cli_t;
    cli_t        cl;
    logic  [5:0] r_cnt, r_len;
    always_ff @(posedge clk) begin
        pf_wr <= 1'b0; pf_done <= 1'b0; sr_ack <= 1'b0; sn_ack <= 1'b0; lw_ack <= 1'b0; fr_wr <= 1'b0; fr_done <= 1'b0;
        if (init) begin rs <= R_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; end
        else case (rs)
            R_IDLE: begin
                DDRAM_BURSTCNT <= 8'd1;
                if (pf_req && !pf_done) begin
                    cl <= C_PF; DDRAM_ADDR <= BASE + 29'(IMG_PROG[26:3]) + {10'd0, pf_addr, 2'b00}; DDRAM_BURSTCNT <= 8'd4;
                    r_len <= 6'd4; DDRAM_RD <= 1'b1; rs <= R_CMD;
                end else if (sr_req && !sr_ack) begin
                    cl <= C_SR; DDRAM_ADDR <= SLOW_BEAT + {13'd0, sr_addr[18:3]};
                    if (sr_we) begin
                        DDRAM_WE  <= 1'b1;
                        DDRAM_DIN <= {4{sr_din[7:0], sr_din[15:8]}};
                        DDRAM_BE  <= {6'd0, sr_be[0], sr_be[1]} << {sr_addr[2:1], 1'b0};
                    end else begin DDRAM_RD <= 1'b1; r_len <= 6'd1; end
                    rs <= R_CMD;
                end else if (sn_req && !sn_ack) begin
                    cl <= C_SN; DDRAM_ADDR <= BASE + 29'(IMG_SND[26:3]) + {10'd0, sn_addr[21:3]}; r_len <= 6'd1; DDRAM_RD <= 1'b1;
                    rs <= R_CMD;
                end else if (lw_pend && !lw_ack) begin
                    cl <= C_LW; DDRAM_ADDR <= BASE + {5'd0, lw_beat}; DDRAM_DIN <= lw_data; DDRAM_BE <= 8'hff; DDRAM_WE <= 1'b1;
                    rs <= R_CMD;
                end else if (fr_req && !fr_done) begin
                    cl <= C_FR; DDRAM_ADDR <= BASE + {5'd0, fr_beat}; DDRAM_BURSTCNT <= 8'd32; r_len <= 6'd32; DDRAM_RD <= 1'b1;
                    rs <= R_CMD;
                end
                r_cnt <= 6'd0;
            end
            R_CMD: if (!DDRAM_BUSY) begin
                DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0;
                if (DDRAM_WE) begin
                    if (cl == C_SR) sr_ack <= 1'b1;
                    if (cl == C_LW) lw_ack <= 1'b1;
                    rs <= R_IDLE;
                end else rs <= R_DATA;
            end
            R_DATA: if (DDRAM_DOUT_READY) begin
                r_cnt <= r_cnt + 6'd1;
                case (cl)
                    C_PF: begin pf_wr <= 1'b1; pf_idx <= r_cnt[1:0]; pf_data <= DDRAM_DOUT; end
                    C_SR: begin sr_dout <= {DDRAM_DOUT[16 * sr_addr[2:1] +: 8], DDRAM_DOUT[16 * sr_addr[2:1] + 8 +: 8]}; end
                    C_SN: begin sn_data <= DDRAM_DOUT; end
                    C_FR: begin fr_wr <= 1'b1; fr_data <= DDRAM_DOUT; end
                    default: ;
                endcase
                if (r_cnt + 6'd1 == r_len) begin
                    case (cl)
                        C_PF: pf_done <= 1'b1;
                        C_SR: sr_ack <= 1'b1;
                        C_SN: sn_ack <= 1'b1;
                        C_FR: fr_done <= 1'b1;
                        default: ;
                    endcase
                    rs <= R_IDLE;
                end
            end
            default: rs <= R_IDLE;
        endcase
    end
endmodule
`default_nettype wire
