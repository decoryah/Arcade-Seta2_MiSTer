// seta2.cpp main board: the TMP68301's 68HC000 (fx68k) with its bus, the memory maps of the phase-1 games, the work RAM, the
// inputs, the sample bank registers and Puzzle De Bowling's protection read.  The TMP68301's peripherals are s2_tmp68301, the
// video chip s2_video, the X1-010 and the slow RAMs are outside (request / ack interfaces).
//
// Memory maps (MAME 0.289 seta2.cpp, the *_map functions; cfg_map numbers as tools/seta2_cfg.py):
//   0 grdians   000000-1FFFFF ROM  200000-20FFFF RAM  304000-30FFFF RAM (slow)  600000/2 DSW1/2  700000/2/4 P1/P2/SYSTEM
//               70000C watchdog  800001 lockout  B00000-B03FFF X1-010  C00000-C7FFFF video  E00010-E0001F banks (odd bytes)
//   1 gundamex  as grdians, and 500000-57FFFF ROM (program section + 0x200000), 700008/A IN0/IN1; no 304000 RAM;
//               parallel port: 93C46 EEPROM (s2 top)
//   2 mj4simai  000000-1FFFFF ROM  200000-20FFFF RAM  600000/2 keys (row latch 600005)  600006 watchdog  600100 SYSTEM
//               600300/2 DSW1/2  600300-60030F banks (writes)  B00000 X1-010  C00000 video
//   3 myangel   000000-1FFFFF ROM  200000-20FFFF RAM  700000/2/4 P1/P2/SYSTEM  700006 watchdog  700300/2 DSW1/2
//               700310-70031F banks  B00000 X1-010  C00000 video
//   4 myangel2  as myangel at 600000.. (P1/P2/SYSTEM 600000/2/4, DSW 600300/2, banks 600300-60030F), video D00000
//   5 pzlbowl   000000-0FFFFF ROM  200000-20FFFF RAM  400300/2 DSW1/2  400300-40030F banks  500000/2 P1/P2  500005 coins
//               (SYSTEM | random bit 7)  500006 watchdog  700000 protection  800000 video  900000 X1-010
//   6 penbros   000000-0FFFFF ROM  200000-20FFFF RAM  210000-23FFFF RAM (slow)  300000-30FFFF RAM (slow)  500300/2 DSW1/2
//               500300-50030F banks  600000/2/4 P1/P2/SYSTEM  600006 watchdog  A00000-A03FFF X1-010  B00000-B3FFFF sprite RAM
//               B40000-B4FFFF palette  B60000-B6003F video registers  (no extra palette area)
//   all         FFFC00-FFFFFF TMP68301 registers
// Unmapped reads return 0, unmapped writes are dropped (MAME's defaults); ROM writes are dropped.  The video chip's 0x50000-0x5FFFF
// ("cleared, additional palette area?") is RAM in the slow RAM.  The watchdog is not modelled (the games kick it).
//
// Slow RAM (word address sr_addr[18:1] in a 512 KB space): 0x00000 grdians 304000-30FFFF / penbros 300000-30FFFF (64 KB),
// 0x10000 the video chip's 0x50000-0x5FFFF (64 KB), 0x20000 penbros 210000-23FFFF (192 KB).
`default_nettype none

module s2_main (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_phi1, cen_phi2,           // the CPU clock as alternating enables
    input  logic        cpu_tick,                     // one per CPU clock cycle (the TMP68301 timers)
    input  logic  [2:0] cfg_map,

    // program ROM (through the cache): word address in the program section of the image
    output logic        rom_req,
    output logic [21:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_data,

    // slow RAM (DDR3)
    output logic        sr_req,
    output logic        sr_we,
    output logic [18:1] sr_addr,
    output logic [15:0] sr_din,
    output logic  [1:0] sr_be,
    input  logic        sr_ack,
    input  logic [15:0] sr_dout,

    // video chip
    output logic        v_req,
    output logic        v_we,
    output logic [18:1] v_addr,
    output logic [15:0] v_din,
    output logic  [1:0] v_be,
    input  logic        v_ack,
    input  logic [15:0] v_dout,

    // X1-010 (0x2000 words; the chip's low bytes)
    output logic        x_req,
    output logic        x_we,
    output logic [12:0] x_addr,
    output logic [15:0] x_din,
    output logic        x_uds, x_lds,
    input  logic [15:0] x_dout,
    output logic  [7:0] snd_bank [8],

    // inputs (active low, as the driver's ports): P1, P2, SYSTEM, DSW1, DSW2, IN0, IN1 (gundamex), KEY0 / KEY1 (mj4simai's
    // mahjong_matrix: the rows selected by key_row read ANDed).  The light-gun games (samshoot): P1 = BUTTONS, P2 = TRIGGER,
    // SYSTEM = COIN, IN0 / IN1 = GUN1 / GUN2, EX2 = PUMP
    input  logic [15:0] in_p1, in_p2, in_sys, in_dsw1, in_dsw2, in_ex0, in_ex1, in_ex2, in_key0, in_key1,
    output logic  [7:0] key_row,

    // the light-gun games' battery RAM, its second port (byte address, little-endian words: MAME's nvram file order): the SD card's
    // file (Seta2.sv); nv_written pulses when the game changes it
    input  logic [12:0] nv_b_addr,
    input  logic        nv_b_we,
    input  logic  [7:0] nv_b_din,
    output logic  [7:0] nv_b_q,
    output logic        nv_written,

    // interrupts
    input  logic        irq_vblank,                   // INT0 (level)
    input  logic        irq_raster,                   // INT1 (pulse: HOLD_LINE until acknowledged)

    // TMP68301 parallel port
    input  logic [15:0] par_in,
    output logic [15:0] par_out,
    output logic        par_wr,

    output logic        cpu_halted,
    output logic [23:0] dbg_pc_addr                   // address of the last bus cycle
);

    // ------------------------------------------------------------------ CPU
    logic [23:1] eab;
    logic [15:0] oEdb, iEdb;
    logic        eRWn, ASn, LDSn, UDSn, VMAn, E;
    logic        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic        DTACKn;
    logic  [2:0] ipl;

    wire iack = FC2 & FC1 & FC0 & ~ASn;

    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= rst;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst | pwr_d), .pwrUp(rst),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn), .VPAn(1'b1),
        .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
        .iEdb(iEdb), .oEdb(oEdb),
        .eab(eab)
    );
    assign cpu_halted = ~oHALTEDn;
    assign dbg_pc_addr = {eab, 1'b0};

    // the memory maps (header byte 2, tools/seta2_cfg.py): M_SAM is Sammy's light-gun board (MAME's samshoot)
    localparam [2:0] M_GRD = 3'd0, M_GUN = 3'd1, M_MJ4 = 3'd2, M_MYA = 3'd3, M_MY2 = 3'd4, M_PZL = 3'd5, M_PEN = 3'd6, M_SAM = 3'd7;

    // ------------------------------------------------------------------ TMP68301
    logic        t_we;
    logic [15:0] t_dout;
    logic  [7:0] t_vec;
    logic  [2:0] t_hold;
    logic        t_iack;
    logic        rast_hold;                           // INT1: HOLD_LINE
    always_ff @(posedge clk) begin
        if (rst) rast_hold <= 1'b0;
        else if (irq_raster) rast_hold <= 1'b1;
        else if (t_hold[1]) rast_hold <= 1'b0;
    end

    // INT2, the light-gun games only: MAME's set_periodic_int(irq2_line_hold, 60 Hz), a timer of its own (not the screen's): held
    // until acknowledged, raised every 1/60 s of the CPU's clock (50 MHz / 3: 277,778 cycles, 59.99999 Hz)
    localparam [18:0] P60 = 19'd277_778;
    logic [18:0] p60_cnt;
    logic        p60_hold;
    always_ff @(posedge clk) begin
        if (rst) begin p60_cnt <= '0; p60_hold <= 1'b0; end
        else begin
            if (t_hold[2]) p60_hold <= 1'b0;
            if (cpu_tick && cfg_map == M_SAM) begin
                if (p60_cnt == P60 - 19'd1) begin p60_cnt <= '0; p60_hold <= 1'b1; end
                else p60_cnt <= p60_cnt + 19'd1;
            end
        end
    end
    wire [1:0] be = {~UDSn, ~LDSn};
    s2_tmp68301 u_tmp (
        .clk(clk), .rst(rst), .cpu_tick(cpu_tick),
        .reg_we(t_we), .reg_addr(eab[9:1]), .reg_din(oEdb), .reg_be(be), .reg_dout(t_dout),
        .ext_pin({p60_hold, rast_hold, irq_vblank}), .ipl(ipl), .iack(t_iack), .vector(t_vec), .hold_ack(t_hold),
        .par_in(par_in), .par_out(par_out), .par_wr(par_wr)
    );

    // ------------------------------------------------------------------ decode
    wire [23:0] ba = {eab, 1'b0};

    typedef enum logic [3:0] { D_NONE, D_ROM, D_RAM, D_SLOW, D_VID, D_X1, D_TMP, D_PORT, D_BANK, D_KROW, D_PROT, D_NVR } dev_t;
    dev_t        dev, dev_c;
    logic [21:1] d_rom, d_rom_c;                      // ROM word address in the program section
    logic [18:1] d_slow, d_slow_c;                    // slow RAM word address
    logic [18:1] d_vid, d_vid_c;                      // video window word address
    logic [15:0] d_port, d_port_c;                    // port value
    logic  [2:0] d_bank, d_bank_c;
    logic        d_romw, d_romw_c;                    // ROM write: dropped

    always_comb begin
        dev_c = D_NONE; d_rom_c = '0; d_slow_c = '0; d_vid_c = '0; d_port_c = 16'h0000; d_bank_c = '0; d_romw_c = 1'b0;
        if (ba[23:10] == 14'h3fff) dev_c = D_TMP;                                  // FFFC00-FFFFFF
        else case (cfg_map)
            M_GRD, M_GUN: begin
                if (ba[23:21] == 3'b000) begin dev_c = D_ROM; d_rom_c = {1'b0, ba[20:1]}; end
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;
                else if (cfg_map == M_GRD && ba[23:16] == 8'h30 && ba[15:14] != 2'b00) begin dev_c = D_SLOW; d_slow_c = {2'b00, ba[16:1]}; end
                else if (cfg_map == M_GUN && ba[23:19] == 5'b01010) begin dev_c = D_ROM; d_rom_c = {3'b100, ba[18:1]}; end   // 500000-57FFFF: image program + 0x200000
                else if (ba[23:2] == 22'h180000) begin dev_c = D_PORT; d_port_c = ba[1] ? in_dsw2 : in_dsw1; end              // 600000/2
                else if (ba[23:4] == 20'h70000) begin
                    dev_c = D_PORT;
                    case (ba[3:1])
                        3'd0: d_port_c = in_p1;
                        3'd1: d_port_c = in_p2;
                        3'd2: d_port_c = in_sys;
                        3'd4: d_port_c = (cfg_map == M_GUN) ? in_ex0 : 16'h0000;
                        3'd5: d_port_c = (cfg_map == M_GUN) ? in_ex1 : 16'h0000;
                        default: d_port_c = 16'h0000;                                                    // (70000C watchdog)
                    endcase
                end
                else if (ba[23:14] == 10'h2c0) dev_c = D_X1;                                             // B00000-B03FFF
                else if (ba[23:19] == 5'b11000) dev_c = D_VID;                                           // C00000-C7FFFF
                else if (ba[23:4] == 20'he0001) begin dev_c = D_BANK; d_bank_c = ba[3:1]; end               // E00010-E0001F
            end
            M_MJ4: begin
                if (ba[23:21] == 3'b000) begin dev_c = D_ROM; d_rom_c = {1'b0, ba[20:1]}; end
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;
                else if (ba[23:2] == 22'h180000) begin dev_c = D_PORT; d_port_c = ba[1] ? in_key1 : in_key0; end           // 600000/2
                else if (ba[23:1] == 23'h300002) dev_c = D_KROW;                                         // 600004/5
                else if (ba[23:1] == 23'h300080) begin dev_c = D_PORT; d_port_c = in_sys; end              // 600100
                else if (ba[23:4] == 20'h60030) begin dev_c = D_BANK; d_bank_c = ba[3:1];                 // 600300-60030F (w)
                    d_port_c = (ba[3:1] == 3'd0) ? in_dsw1 : (ba[3:1] == 3'd1) ? in_dsw2 : 16'h0000; end
                else if (ba[23:14] == 10'h2c0) dev_c = D_X1;
                else if (ba[23:19] == 5'b11000) dev_c = D_VID;
            end
            M_MYA, M_MY2: begin
                logic [7:0] io;
                io = (cfg_map == M_MYA) ? 8'h70 : 8'h60;
                if (ba[23:21] == 3'b000) begin dev_c = D_ROM; d_rom_c = {1'b0, ba[20:1]}; end
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;
                else if (ba[23:16] == io && ba[15:4] == 12'h000) begin
                    dev_c = D_PORT;
                    case (ba[3:1])
                        3'd0: d_port_c = in_p1;
                        3'd1: d_port_c = in_p2;
                        3'd2: d_port_c = in_sys;
                        default: d_port_c = 16'h0000;
                    endcase
                end
                else if (ba[23:16] == io && ba[15:4] == 12'h030 && cfg_map == M_MY2) begin dev_c = D_BANK; d_bank_c = ba[3:1];
                    d_port_c = (ba[3:1] == 3'd0) ? in_dsw1 : (ba[3:1] == 3'd1) ? in_dsw2 : 16'h0000; end
                else if (ba[23:16] == io && ba[15:4] == 12'h030) begin dev_c = D_PORT;                   // myangel 700300/2
                    d_port_c = (ba[3:1] == 3'd0) ? in_dsw1 : (ba[3:1] == 3'd1) ? in_dsw2 : 16'h0000; end
                else if (ba[23:16] == io && ba[15:4] == 12'h031 && cfg_map == M_MYA) begin dev_c = D_BANK; d_bank_c = ba[3:1]; end
                else if (ba[23:14] == 10'h2c0) dev_c = D_X1;
                else if (ba[23:19] == ((cfg_map == M_MYA) ? 5'b11000 : 5'b11010)) dev_c = D_VID;
            end
            M_PZL: begin
                if (ba[23:20] == 4'h0) begin dev_c = D_ROM; d_rom_c = {2'b00, ba[19:1]}; end
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;
                else if (ba[23:4] == 20'h40030) begin dev_c = D_BANK; d_bank_c = ba[3:1];
                    d_port_c = (ba[3:1] == 3'd0) ? in_dsw1 : (ba[3:1] == 3'd1) ? in_dsw2 : 16'h0000; end
                else if (ba[23:4] == 20'h50000) begin
                    dev_c = D_PORT;
                    case (ba[3:1])
                        3'd0: d_port_c = in_p1;
                        3'd1: d_port_c = in_p2;
                        3'd2: d_port_c = {8'h00, in_sys[7:0] ^ {lfsr[0], 7'd0}};    // (MAME's port: active-high custom bit 7 | rand)
                        default: d_port_c = 16'h0000;
                    endcase
                end
                else if (ba[23:1] == 23'h380000) dev_c = D_PROT;                                          // 700000
                else if (ba[23:19] == 5'b10000) dev_c = D_VID;                                           // 800000-87FFFF
                else if (ba[23:14] == 10'h240) dev_c = D_X1;                                             // 900000-903FFF
            end
            M_PEN: begin
                if (ba[23:20] == 4'h0) begin dev_c = D_ROM; d_rom_c = {2'b00, ba[19:1]}; end
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;
                else if (ba[23:16] >= 8'h21 && ba[23:16] <= 8'h23) begin dev_c = D_SLOW; d_slow_c = {1'b1, ba[17:1]} - 18'h08000; end
                else if (ba[23:16] == 8'h30) begin dev_c = D_SLOW; d_slow_c = {2'b00, ba[16:1]}; end
                else if (ba[23:4] == 20'h50030) begin dev_c = D_BANK; d_bank_c = ba[3:1];
                    d_port_c = (ba[3:1] == 3'd0) ? in_dsw1 : (ba[3:1] == 3'd1) ? in_dsw2 : 16'h0000; end
                else if (ba[23:4] == 20'h60000) begin
                    dev_c = D_PORT;
                    case (ba[3:1])
                        3'd0: d_port_c = in_p1;
                        3'd1: d_port_c = in_p2;
                        3'd2: d_port_c = in_sys;
                        default: d_port_c = 16'h0000;
                    endcase
                end
                else if (ba[23:14] == 10'h280) dev_c = D_X1;                                             // A00000-A03FFF
                else if (ba[23:18] == 6'b101100) dev_c = D_VID;                                          // B00000-B3FFFF sprite RAM
                else if (ba[23:16] == 8'hb4) dev_c = D_VID;                                              // B40000 palette
                else if (ba[23:6] == 18'h2d800) dev_c = D_VID;                                           // B60000-B6003F registers
            end
            M_SAM: begin                                                                                 // samshoot_map
                if (ba[23:21] == 3'b000) begin dev_c = D_ROM; d_rom_c = {1'b0, ba[20:1]}; end            // 000000-1FFFFF
                else if (ba[23:16] == 8'h20) dev_c = D_RAM;                                              // 200000-20FFFF
                else if (ba[23:13] == 11'h180) dev_c = D_NVR;                                              // 300000-301FFF NVRAM (block RAM)
                else if (ba[23:16] == 8'h30) begin dev_c = D_SLOW; d_slow_c = {2'b00, ba[16:1]}; end     // 302000-30FFFF the rest of it
                else if (ba[23:2] == 22'h100000) begin dev_c = D_PORT; d_port_c = ba[1] ? in_p1 : in_dsw1; end   // 400000 DSW1, 400002 BUTTONS
                else if (ba[23:4] == 20'h40030) begin dev_c = D_BANK; d_bank_c = ba[3:1]; end            // 400300-40030F sample banks
                else if (ba[23:20] == 4'b0101) begin dev_c = D_PORT; d_port_c = ba[19] ? in_ex1 : in_ex0; end    // 500000 GUN1, 580000 GUN2
                else if (ba[23:3] == 21'h0e0000) begin
                    dev_c = D_PORT;                                                                      // 700000-700007 (writes: coin counters)
                    case (ba[2:1])
                        2'd0: d_port_c = in_p2;                                                          // TRIGGER (START1)
                        2'd1: d_port_c = in_ex2;                                                         // PUMP (START2)
                        2'd2: d_port_c = in_sys;                                                         // COIN
                        default: d_port_c = 16'h0000;                                                    // watchdog
                    endcase
                end
                else if (ba[23:19] == 5'b10000) dev_c = D_VID;                                           // 800000-87FFFF
                else if (ba[23:14] == 10'h240) dev_c = D_X1;                                             // 900000-903FFF
            end
            default: ;
        endcase
        // the video window: 0x50000-0x5FFFF is the board's (slow RAM), not the chip's; penbros has none
        d_vid_c = ba[18:1];
        if (dev_c == D_VID && ba[18:16] == 3'b101) begin
            if (cfg_map == M_PEN) dev_c = D_NONE;
            else begin dev_c = D_SLOW; d_slow_c = {2'b01, ba[16:1]}; end
        end
    end
    // registered: the 68000's address is out at least one phase enable (2 clocks) before AS falls, so the decode of this
    // address is in these registers when the bus cycle below sees AS
    always_ff @(posedge clk) begin
        dev <= dev_c; d_rom <= d_rom_c; d_slow <= d_slow_c; d_vid <= d_vid_c; d_port <= d_port_c; d_bank <= d_bank_c; d_romw <= d_romw_c;
    end

    // pzlbowl's bit 7 of the coin port: machine().rand() & 0x80 -> a free-running LFSR bit
    logic [15:0] lfsr = 16'hace1;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    // ------------------------------------------------------------------ work RAM (64 KB)
    logic [15:0] ram_q;
    logic  [1:0] ram_we;
    logic [14:0] ram_a;
    logic [15:0] ram_d;
    (* ramstyle = "no_rw_check" *) logic [7:0] ram_hi [32768];
    (* ramstyle = "no_rw_check" *) logic [7:0] ram_lo [32768];
    always_ff @(posedge clk) begin
        if (ram_we[1]) ram_hi[ram_a] <= ram_d[15:8];
        ram_q[15:8] <= ram_hi[ram_a];
    end
    always_ff @(posedge clk) begin
        if (ram_we[0]) ram_lo[ram_a] <= ram_d[7:0];
        ram_q[7:0] <= ram_lo[ram_a];
    end

    // ------------------------------------------------------------------ the light-gun games' battery RAM (8 KB)
    // MAME gives samshoot 64 KB of NVRAM at 0x300000; after power-on the games write only its first 2 KB (MAME, 100 s of play each:
    // Deer Hunting and Trophy Hunting 0x300000-0x3007FF, Turkey Hunting and Wing Shooting 0x300000-0x3003FF; Trophy Hunting's
    // power-on check goes over all 64 KB and puts back what it finds), so 0x300000-0x301FFF is block RAM that the SD card's file
    // fills and saves (rtl/s2_nvram.sv), the rest the slow RAM.  Starts at zero, as MAME's (nvram_device::DEFAULT_ALL_0);
    // s2_nvram clears it at every ROM load before the saved file comes.
    (* ramstyle = "no_rw_check" *) logic [7:0] nv_hi [4096];
    (* ramstyle = "no_rw_check" *) logic [7:0] nv_lo [4096];
    logic [11:0] nv_a;
    logic [15:0] nv_d, nv_q;
    logic  [1:0] nv_we, nv_wreq, nv_wp;
    logic        nv_chg;
    logic  [7:0] nvb_hi_q, nvb_lo_q;
    logic        nvb_lane, nv_sel;
    always_ff @(posedge clk) begin
        if (nv_we[1]) nv_hi[nv_a] <= nv_d[15:8];
        nv_q[15:8] <= nv_hi[nv_a];
    end
    always_ff @(posedge clk) begin
        if (nv_we[0]) nv_lo[nv_a] <= nv_d[7:0];
        nv_q[7:0] <= nv_lo[nv_a];
    end
    always_ff @(posedge clk) begin
        if (nv_b_we && nv_b_addr[0]) nv_hi[nv_b_addr[12:1]] <= nv_b_din;
        nvb_hi_q <= nv_hi[nv_b_addr[12:1]];
    end
    always_ff @(posedge clk) begin
        if (nv_b_we && !nv_b_addr[0]) nv_lo[nv_b_addr[12:1]] <= nv_b_din;
        nvb_lo_q <= nv_lo[nv_b_addr[12:1]];
        nvb_lane <= nv_b_addr[0];
    end
    assign nv_b_q = nvb_lane ? nvb_hi_q : nvb_lo_q;
    // A write reads the old word first (nv_q, a clock after the address), then writes: nv_written says the contents changed (the
    // games rewrite unchanged values many times a frame; only a change is worth saving).  The bus cycle ends as before (B_DONE);
    // the write lands three clocks after the address, long before the CPU's next access.
    always_ff @(posedge clk) begin
        nv_wp  <= nv_wreq;
        nv_we  <= nv_wp;
        nv_chg <= |(nv_wp & {nv_q[15:8] != nv_d[15:8], nv_q[7:0] != nv_d[7:0]});
    end
    assign nv_written = nv_chg;
    initial for (int i = 0; i < 4096; i++) begin nv_hi[i] = 8'h00; nv_lo[i] = 8'h00; end

    // ------------------------------------------------------------------ bus cycle
    // Every access completes with DTACK from here.  Writes wait for the data strobes (a clock after AS on the 68000).
    typedef enum logic [3:0] { B_IDLE, B_WAIT, B_RAM1, B_RAM2, B_DONE, B_P1, B_P2, B_P3, B_P4, B_P5 } bst_t;
    bst_t        bst;
    logic        rdy;
    logic  [2:0] cnt;
    logic [31:0] p_addr;                              // protection: the address from RAM
    logic        x_busy;
    assign DTACKn = ~rdy;

    always_ff @(posedge clk) begin
        t_we   <= 1'b0;
        t_iack <= 1'b0;
        ram_we <= 2'b00;
        nv_wreq <= 2'b00;
        if (rst) begin
            rdy <= 1'b0; bst <= B_IDLE; rom_req <= 1'b0; sr_req <= 1'b0; v_req <= 1'b0; x_req <= 1'b0; x_busy <= 1'b0;
            key_row <= 8'h00;
            for (int i = 0; i < 8; i++) snd_bank[i] <= 8'h00;
        end else if (ASn) begin
            rdy <= 1'b0; bst <= B_IDLE; rom_req <= 1'b0; sr_req <= 1'b0; v_req <= 1'b0; x_req <= 1'b0; x_busy <= 1'b0;
        end else if (!rdy) begin
            case (bst)
                B_IDLE: begin
                    if (iack) begin
                        // the TMP68301 gives the vector (interrupt_callback)
                        iEdb   <= {8'h00, t_vec};
                        t_iack <= 1'b1;
                        rdy    <= 1'b1;
                    end else if (!eRWn && be == 2'b00) ;                     // a write: wait for the strobes
                    else begin
                        cnt <= 3'd0;
                        case (dev)
                            D_ROM:  if (eRWn) begin rom_addr <= d_rom; rom_req <= 1'b1; bst <= B_WAIT; end
                                    else bst <= B_DONE;
                            D_NVR:  begin
                                nv_a <= eab[12:1]; nv_d <= oEdb; nv_sel <= 1'b1;
                                if (!eRWn) begin nv_wreq <= be; bst <= B_DONE; end
                                else bst <= B_RAM1;
                            end
                            D_RAM:  begin
                                nv_sel <= 1'b0;
                                ram_a <= eab[15:1]; ram_d <= oEdb;
                                if (!eRWn) begin ram_we <= be; bst <= B_DONE; end
                                else bst <= B_RAM1;
                            end
                            D_SLOW: begin sr_req <= 1'b1; sr_we <= !eRWn; sr_addr <= d_slow; sr_din <= oEdb; sr_be <= be; bst <= B_WAIT; end
                            D_VID:  begin v_req <= 1'b1; v_we <= !eRWn; v_addr <= d_vid; v_din <= oEdb; v_be <= be; bst <= B_WAIT; end
                            D_X1:   begin x_req <= 1'b1; x_busy <= 1'b1; x_we <= !eRWn; x_addr <= eab[13:1]; x_din <= oEdb; x_uds <= be[1];
                                          x_lds <= be[0]; bst <= B_WAIT; end
                            D_TMP:  begin if (!eRWn) t_we <= 1'b1; iEdb <= t_dout; bst <= B_DONE; end
                            D_PORT: begin iEdb <= d_port; bst <= B_DONE; end
                            D_BANK: begin
                                // sound_bank_w (umask 0x00ff: the odd byte); a read of the same address is the port (DSW)
                                if (!eRWn) begin if (be[0]) snd_bank[d_bank] <= oEdb[7:0]; end
                                else iEdb <= d_port;
                                bst <= B_DONE;
                            end
                            D_KROW: begin
                                if (!eRWn && be[0]) key_row <= oEdb[7:0];               // 600005: the keyboard row
                                iEdb <= 16'h0000;
                                bst <= B_DONE;
                            end
                            D_PROT: begin ram_a <= 15'h5d0b; bst <= B_P1; end          // 20BA16: the high word of the address
                            default: begin iEdb <= 16'h0000; bst <= B_DONE; end
                        endcase
                    end
                end
                B_RAM1: bst <= B_RAM2;
                B_RAM2: begin iEdb <= nv_sel ? nv_q : ram_q; bst <= B_DONE; end
                B_WAIT: begin
                    if (rom_req && rom_ack) begin iEdb <= rom_data; rom_req <= 1'b0; bst <= B_DONE; end
                    if (sr_req && sr_ack)   begin iEdb <= sr_dout;  sr_req  <= 1'b0; bst <= B_DONE; end
                    if (v_req && v_ack)     begin iEdb <= v_dout;   v_req   <= 1'b0; bst <= B_DONE; end
                    if (x_busy) begin
                        // the X1-010 takes the access on its first clock (x_req is a one-clock strobe); its read data 3 clocks on
                        x_req <= 1'b0;
                        cnt <= cnt + 3'd1;
                        if (cnt == 3'd3) begin iEdb <= x_dout; x_busy <= 1'b0; bst <= B_DONE; end
                    end
                end
                // pzlbowl_protection_r: address = (RAM[0x20BA16] << 16) | RAM[0x20BA18]; the byte m_maincpu_region->base()[address - 2]
                B_P1: begin ram_a <= 15'h5d0c; bst <= B_P2; end
                B_P2: begin p_addr[31:16] <= ram_q; bst <= B_P3; end
                B_P3: begin p_addr[15:0] <= ram_q; bst <= B_P4; end
                B_P4: begin
                    // MAME's region pointer on a little-endian host: the 68000 byte n is at n ^ 1
                    rom_addr <= p_addr[21:1] - 21'd1;
                    rom_req  <= 1'b1;
                    bst <= B_P5;
                end
                B_P5: if (rom_ack) begin
                    rom_req <= 1'b0;
                    iEdb <= {8'h00, p_addr[0] ? rom_data[15:8] : rom_data[7:0]};
                    bst <= B_DONE;
                end
                B_DONE: rdy <= 1'b1;
                default: bst <= B_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
