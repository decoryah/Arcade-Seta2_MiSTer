// 93C46 serial EEPROM, 64 x 16 bits (Gundam EX Revue, on the TMP68301's parallel port), from MAME 0.289's
// src/devices/machine/eepromser.cpp (eeprom_serial_93cxx_device, EEPROM_93C46_16BIT: 6 address bits, no streaming, writes take no
// time).  State machine as handle_event(); the driver writes CLK, then DI, then CS on every parallel-port write
// (gundamex_eeprom_w), handled here as three steps in that order.
//
// The contents are initialised from the MRA's image (MAME's "eeprom" region, big-endian words) through the init port.
`default_nettype none
module s2_eeprom (
    input  logic        clk,
    input  logic        rst,

    // pins (gundamex_eeprom_w: CLK = bit 1, DI = bit 0, CS = bit 2), presented together with `wr`
    input  logic        wr,
    input  logic        cs_in, clk_in, di_in,
    output logic        dout,                   // do_read()

    // contents: initial image (word writes) and a read port for saving
    input  logic        init_we,
    input  logic  [5:0] init_addr,
    input  logic [15:0] init_data,
    input  logic  [5:0] rd_addr,
    output logic [15:0] rd_data,
    output logic        dirty                   // pulse: a word was written by the game
);
    logic [15:0] mem [64];
    always_ff @(posedge clk) rd_data <= mem[rd_addr];

    typedef enum logic [2:0] { E_RESET, E_START, E_CMD, E_READ, E_DATA, E_DONE } est_t;
    est_t        st;
    logic        cs_s, clk_s, di_s, locked;
    logic  [4:0] nbits;
    logic  [7:0] acc;                           // command + address
    logic  [1:0] cmd_op;
    logic  [5:0] addr;
    logic [31:0] sh;
    logic        cs_new;                        // CS rose in this write (a CLK in the same write does not count)
    logic  [1:0] step;
    logic        p_cs, p_clk, p_di;

    assign dout = (st == E_START) ? 1'b1 : (st == E_READ) ? sh[31] : 1'b1;

    // the command once 8 bits (2 opcode + 6 address) are in: 0 + 2 more bits: 00 lock, 01 write all, 10 erase all, 11 unlock;
    // 01 write, 10 read, 11 erase
    always_ff @(posedge clk) begin
        dirty <= 1'b0;
        if (init_we) mem[init_addr] <= init_data;
        if (rst) begin
            st <= E_RESET; cs_s <= 1'b0; clk_s <= 1'b0; di_s <= 1'b0; locked <= 1'b1; step <= 2'd0;
        end else begin
            if (wr && step == 2'd0) begin p_cs <= cs_in; p_clk <= clk_in; p_di <= di_in; step <= 2'd1; cs_new <= 1'b0; end
            case (step)
                2'd1: begin
                    // CLK
                    step <= 2'd2;
                    if (p_clk != clk_s) begin
                        clk_s <= p_clk;
                        if (p_clk) begin                                     // rising
                            case (st)
                                E_START: if (di_s) begin acc <= 8'd0; nbits <= 5'd0; st <= E_CMD; end
                                E_CMD: begin
                                    acc <= {acc[6:0], di_s};
                                    nbits <= nbits + 5'd1;
                                    if (nbits == 5'd7) begin
                                        logic [7:0] c;
                                        c = {acc[6:0], di_s};
                                        nbits <= 5'd0;
                                        addr  <= c[5:0];
                                        case (c[7:6])
                                            2'd0: begin
                                                case (c[5:4])
                                                    2'd0: begin locked <= 1'b1; st <= E_RESET; end
                                                    2'd1: begin cmd_op <= 2'd0; sh <= 32'd0; if (locked) st <= E_RESET; else st <= E_DATA; end   // WRITEALL
                                                    2'd2: begin                                                           // ERASEALL
                                                        if (locked) st <= E_RESET;
                                                        else begin for (int i = 0; i < 64; i++) mem[i] <= 16'hffff; dirty <= 1'b1; st <= E_DONE; end
                                                    end
                                                    default: begin locked <= 1'b0; st <= E_RESET; end
                                                endcase
                                            end
                                            2'd1: begin cmd_op <= 2'd1; sh <= 32'd0; st <= E_DATA; end                   // WRITE
                                            2'd2: begin sh <= 32'd0; st <= E_READ; end                                  // READ
                                            default: begin                                                             // ERASE
                                                if (locked) st <= E_RESET;
                                                else begin mem[c[5:0]] <= 16'hffff; dirty <= 1'b1; st <= E_DONE; end
                                            end
                                        endcase
                                    end
                                end
                                E_READ: begin
                                    if (nbits == 5'd0) sh <= {mem[addr], 16'd0};
                                    else sh <= {sh[30:0], 1'b1};
                                    if (nbits != 5'd31) nbits <= nbits + 5'd1;
                                end
                                E_DATA: begin
                                    sh <= {sh[30:0], di_s};
                                    nbits <= nbits + 5'd1;
                                    if (nbits == 5'd15) begin
                                        if (locked) st <= E_RESET;
                                        else begin
                                            if (cmd_op == 2'd1) mem[addr] <= {sh[14:0], di_s};
                                            else for (int i = 0; i < 64; i++) mem[i] <= mem[i] & {sh[14:0], di_s};
                                            dirty <= 1'b1;
                                            st <= E_DONE;
                                        end
                                    end
                                end
                                default: ;
                            endcase
                        end
                    end
                end
                2'd2: begin di_s <= p_di; step <= 2'd3; end                 // DI
                2'd3: begin                                                  // CS
                    step <= 2'd0;
                    if (p_cs != cs_s) begin
                        cs_s <= p_cs;
                        if (p_cs) begin if (st == E_RESET) st <= E_START; end
                        else st <= E_RESET;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
