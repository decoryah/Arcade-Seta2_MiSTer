// The light-gun games' battery RAM (its first 8 KB, in rtl/s2_main.sv) to the SD card: the MRA's <nvram index="4" size="8192"/>.
// Main_MiSTer sends the saved file after the ROMs (a download with index INDEX; the machine is held in reset meanwhile: nv_dl) and
// reads the RAM back (an upload with index INDEX) when the core asks for it (ioctl_upload_req = nv_req): when the OSD opens after the
// game has changed the RAM (OSD Autosave NVRAM On, the default) and on Save NVRAM.  The bytes are little-endian words, as MAME's
// nvram file (its first 8 KB).  Without a saved file the RAM is all zeros, as MAME's: it is cleared at every ROM load (8192 clocks,
// done long before the file comes; a file that comes cuts it short).  Shared by the top level (Seta2.sv) and the machine bench
// (sim/sys/tb_sys.sv).
`default_nettype none
module s2_nvram #(
    parameter [7:0] INDEX = 8'd4
) (
    input  wire        clk,
    input  wire        gun_game,            // the loaded set has the battery RAM
    input  wire        rom_dl,              // the ROM download (index 0) is on

    // hps_io's file port
    input  wire        ioctl_download, ioctl_upload, ioctl_wr,
    input  wire  [7:0] ioctl_index,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire  [7:0] ioctl_din,
    output reg         nv_req = 1'b0,       // ioctl_upload_req
    output wire        nv_dl,               // the saved file is coming: hold the machine in reset

    // the OSD
    input  wire        osd,                 // OSD_STATUS: open
    input  wire        autosave_off,
    input  wire        save,                // Save NVRAM (a trigger)

    // the RAM's second port (s2_core)
    output wire [12:0] nv_b_addr,
    output wire        nv_b_we,
    output wire  [7:0] nv_b_din,
    input  wire  [7:0] nv_b_q,
    input  wire        nv_written           // the game changed it
);
    assign nv_dl = ioctl_download && (ioctl_index == INDEX);
    wire   nv_ul = ioctl_upload && (ioctl_index == INDEX);

    reg        rom_dl_d = 1'b0;
    reg [13:0] clr = 14'h2000;
    always @(posedge clk) begin
        rom_dl_d <= rom_dl;
        if (rom_dl && !rom_dl_d) clr <= 14'd0;
        else if (nv_dl) clr <= 14'h2000;
        else if (!clr[13]) clr <= clr + 14'd1;
    end
    wire clearing = !clr[13];
    assign nv_b_addr = clearing ? clr[12:0] : ioctl_addr[12:0];
    assign nv_b_we   = clearing || (nv_dl && ioctl_wr && (ioctl_addr[26:13] == 14'd0));
    assign nv_b_din  = clearing ? 8'd0 : ioctl_dout;
    assign ioctl_din = nv_b_q;

    reg dirty = 1'b0, nv_ul_d = 1'b0, osd_d = 1'b0, save_d = 1'b0;
    always @(posedge clk) begin
        nv_ul_d <= nv_ul;
        osd_d   <= osd;
        save_d  <= save;
        nv_req  <= gun_game && ((dirty && !autosave_off && osd && !osd_d) || (save && !save_d));
        // the cleared RAM, the restored file and the saved one are not news (a write while it is being saved is)
        if (nv_written) dirty <= 1'b1;
        else if (rom_dl || nv_dl || (nv_ul && !nv_ul_d)) dirty <= 1'b0;
    end
endmodule
`default_nettype wire
