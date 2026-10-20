// SDR SDRAM controller for the graphics ROM of the seta2 core: 8-byte tile rows, in order, pipelined across banks.
//
// Pin-level conventions are those of the owner's sdram_ctrl.sv (Cross Pang, Metro, ... proven on MiSTer at 96 MHz): the chip clock is
// a PLL output shifted about half a period (rtl/pll), CL2, the read data sampled into an I/O register three clock edges after the edge
// that puts the READ on the pins (`rd_late`: four), DQML / DQMH driven from SDRAM_A[12:11] (the MiSTer 128 MB module shorts them).
// The commands are decided a clock before they reach the pin registers (timing: the decision logic is not next to the I/O cells).
//
// Reads: a burst of 4 words (one tile row) per request, READ with auto precharge.  The ACTIVATE of the next request goes out while
// the previous one's data is still on the bus when it is for another bank (one request per 4 clocks: ~1500 rows per line), except
// when its row address has A12 / A11 set: those pins are the DQMs on the 128 MB module and would mask the words still coming, so
// that ACTIVATE waits until the burst has left the pins (one request per 6 clocks).  Same bank: tRC.
// Writes (the ROM loader): single words (mode register: single-location writes), ACT / WRITE with auto precharge.
// Refresh: one AUTO REFRESH per 7.8 us, between requests.
//
// Mapping of the 8-byte unit address u[21:0] (= tile code * 8 + row of the tile): bank = u[4:3] (the tile code's low bits:
// consecutive tiles of a sprite go to different banks), column = {u[8:5], u[2:0], word}, row = u[21:9].  The loader's byte address
// A maps the same way (u = A[24:3], word = A[2:1]).  A row is {word 3, word 2, word 1, word 0}, word w = bytes 2w+1:2w of the region.
`default_nettype none

module s2_sdram #(
    parameter [13:0] CYCLES_PER_REFRESH = 14'd729      // 7.6 us at 96 MHz (s2_mem sets it from the machine clock)
) (
    input  logic        clk,                // 96 MHz
    input  logic        clk_pin,            // the shifted copy for the chip
    input  logic        init,
    input  logic        rd_late,
    output logic        ready,

    // reads: request held until rq_ready; the rows come back in order
    input  logic        rq,
    input  logic [21:0] rq_addr,
    output logic        rq_ready,
    output logic        rd_valid,
    output logic [63:0] rd_data,

    // writes (loader): request held until w_ack
    input  logic        wq,
    input  logic [24:1] w_addr,
    input  logic [15:0] w_data,
    output logic        w_ack,

    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK
);
    localparam [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
                     CMD_PRECHARGE = 3'b010, CMD_REFRESH = 3'b001, CMD_LOAD_MODE = 3'b000;
    // BL = 4, sequential, CL2, single-location writes
    localparam [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'b010};

    logic  [2:0] command;
    logic [15:0] dq_out;
    logic        dq_oe;
    // the controller decides the next command into c_*; the pin registers (in the I/O cells, sys/sys.tcl) take it a clock later
    logic  [2:0] c_cmd;
    logic [12:0] c_a;
    logic  [1:0] c_ba;
    logic [15:0] c_dq;
    logic        c_oe;
    always_ff @(posedge clk) begin
        command <= c_cmd; SDRAM_A <= c_a; SDRAM_BA <= c_ba; dq_out <= c_dq; dq_oe <= c_oe;
    end
    assign SDRAM_DQ   = dq_oe ? dq_out : 16'bZ;
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = command;
    assign SDRAM_nCS  = 1'b0;
    assign SDRAM_CKE  = 1'b1;
    assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
    assign SDRAM_CLK  = clk_pin;

    // ---------------------------------------------------------------- timers
    logic [14:0] rcount;                    // startup / refresh
    logic        rdue;
    logic  [3:0] bank_busy [4];             // clocks until the bank may be activated again
    logic  [2:0] act_gap;                   // clocks until the next ACTIVATE (data bus spacing)
    logic  [2:0] dqm_gap;                   // clocks until an ACTIVATE with A12 / A11 set may go (the burst has left the pins)
    logic  [3:0] all_gap;                   // after a refresh / write: clocks until anything
    logic  [1:0] rd_due;                    // a READ for the activated request goes out when this reaches 1

    // the request being issued
    logic  [1:0] p_bank;
    logic  [8:0] p_col;

    // capture: a tag per data word, shifted down; tag at [0] = dq_in holds that word
    logic  [3:0] cap_v;                     // [k]: word k of a burst at that position
    logic  [8:0] cap [0:9];                 // {valid, word index 0..3} per position (bit 8 valid, bits 1:0 index)
    logic [15:0] dq_in;
    logic [47:0] asm_lo;                    // words 0..2 of the row being assembled

    typedef enum logic [2:0] { S_STARTUP, S_RUN } st_t;
    st_t state;
    logic  [3:0] init_step;
    logic        wr_seq;                    // a write's ACT has gone; its WRITE follows

    wire  [1:0] q_bank = rq_addr[4:3];
    wire [12:0] q_row  = rq_addr[21:9];
    wire  [8:0] q_col  = {rq_addr[8:5], rq_addr[2:0], 2'b00};
    wire        q_hi   = |q_row[12:11];
    wire  [1:0] w_bank = w_addr[7:6];
    wire [12:0] w_row  = w_addr[24:12];
    wire  [8:0] w_col  = {w_addr[11:8], w_addr[5:3], w_addr[2:1]};
    wire        w_hi   = |w_row[12:11];

    wire can_act = (act_gap == 3'd0) && (all_gap == 4'd0) && (rd_due == 2'd0);

    always_ff @(posedge clk) begin
        c_cmd <= CMD_NOP;
        c_a  <= 13'd0;
        c_ba <= 2'd0;
        c_oe    <= 1'b0;
        rq_ready <= 1'b0;
        w_ack    <= 1'b0;
        rd_valid <= 1'b0;
        for (int b = 0; b < 4; b++) if (bank_busy[b] != 4'd0) bank_busy[b] <= bank_busy[b] - 4'd1;
        if (act_gap != 3'd0) act_gap <= act_gap - 3'd1;
        if (dqm_gap != 3'd0) dqm_gap <= dqm_gap - 3'd1;
        if (all_gap != 4'd0) all_gap <= all_gap - 4'd1;
        rcount <= rcount + 15'd1;
        if (rcount >= {1'b0, CYCLES_PER_REFRESH}) rdue <= 1'b1;

        // capture
        dq_in <= SDRAM_DQ;
        for (int i = 0; i < 9; i++) cap[i] <= cap[i + 1];
        cap[9] <= '0;
        if (cap[0][8]) begin
            case (cap[0][1:0])
                2'd0: asm_lo[15:0]  <= dq_in;
                2'd1: asm_lo[31:16] <= dq_in;
                2'd2: asm_lo[47:32] <= dq_in;
                default: begin rd_valid <= 1'b1; rd_data <= {dq_in, asm_lo}; end
            endcase
        end

        case (state)
            S_STARTUP: begin
                ready <= 1'b0;
                // > 100 us idle, PRECHARGE ALL, 8 AUTO REFRESH, LOAD MODE (each step 16 clocks apart)
                if (rcount[14] && rcount[3:0] == 4'd0) begin
                    init_step <= init_step + 4'd1;
                    case (init_step)
                        4'd0: begin c_cmd <= CMD_PRECHARGE; c_a[10] <= 1'b1; end
                        4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8: c_cmd <= CMD_REFRESH;
                        4'd9: begin c_cmd <= CMD_LOAD_MODE; c_a <= MODE; end
                        default: begin
                            state <= S_RUN; ready <= 1'b1; rcount <= 15'd0; rdue <= 1'b0;
                        end
                    endcase
                end
            end

            S_RUN: begin
                if (rd_due == 2'd1) begin
                    // READ with auto precharge, 2 clocks after its ACTIVATE
                    rd_due   <= 2'd0;
                    c_cmd <= CMD_READ;
                    c_ba <= p_bank;
                    c_a  <= {2'b00, 1'b1, 1'b0, p_col};
                    for (int k = 0; k < 4; k++) cap[(rd_late ? 5 : 4) + k] <= {1'b1, 6'd0, 2'(k)};   // (+1: the pin stage)
                    dqm_gap  <= 3'd3;              // an ACT with A12/A11 set may go 4 clocks after the READ
                end else if (rd_due != 2'd0) begin
                    rd_due <= rd_due - 2'd1;
                end else if (rdue && can_act && bank_busy[0] == 4'd0 && bank_busy[1] == 4'd0 &&
                             bank_busy[2] == 4'd0 && bank_busy[3] == 4'd0 && cap_v == 4'd0) begin
                    // AUTO REFRESH (all banks idle: the auto precharges have finished)
                    c_cmd <= CMD_REFRESH;
                    rdue    <= 1'b0;
                    rcount  <= 15'd0;
                    all_gap <= 4'd8;
                end else if (wq && !w_ack && can_act && bank_busy[w_bank] == 4'd0 && !rdue && (!w_hi || dqm_gap == 3'd0)) begin
                    // write: ACT now, WRITE with auto precharge two clocks later (handled as a fixed sequence)
                    c_cmd <= CMD_ACTIVE;
                    c_ba <= w_bank;
                    c_a  <= w_row;
                    p_bank   <= w_bank;
                    p_col    <= w_col;
                    all_gap  <= 4'd2;               // the WRITE goes at all_gap == 1 (below)
                    bank_busy[w_bank] <= 4'd9;
                    act_gap  <= 3'd7;
                    wr_seq   <= 1'b1;
                end else if (rq && !rq_ready && !rdue && can_act && bank_busy[q_bank] == 4'd0 && (!q_hi || dqm_gap == 3'd0)) begin
                    c_cmd <= CMD_ACTIVE;
                    c_ba <= q_bank;
                    c_a  <= q_row;
                    p_bank   <= q_bank;
                    p_col    <= q_col;
                    rd_due   <= 2'd2;
                    rq_ready <= 1'b1;
                    bank_busy[q_bank] <= 4'd9;      // READ at +2, auto precharge after the burst (+4), tRP (+2), margin
                    act_gap  <= 3'd3;               // the next ACT 4 clocks after this one: its burst follows this one's
                end
                // the write sequence: WRITE two clocks after its ACT
                if (wr_seq && all_gap == 4'd1) begin
                    wr_seq   <= 1'b0;
                    c_cmd <= CMD_WRITE;
                    c_ba <= p_bank;
                    c_a  <= {2'b00, 1'b1, 1'b0, p_col};   // A12/A11 = 0: both bytes (DQM low)
                    c_dq   <= w_data;
                    c_oe    <= 1'b1;
                    w_ack    <= 1'b1;
                    all_gap  <= 4'd4;               // tWR + tRP before the next command of any kind
                end
            end
            default: state <= S_STARTUP;
        endcase

        if (init) begin
            state <= S_STARTUP; init_step <= 4'd0; rcount <= 15'd0; ready <= 1'b0; rdue <= 1'b0;
            rd_due <= 2'd0; act_gap <= 3'd0; dqm_gap <= 3'd0; all_gap <= 4'd0; wr_seq <= 1'b0;
            for (int b = 0; b < 4; b++) bank_busy[b] <= 4'd0;
            for (int i = 0; i < 10; i++) cap[i] <= '0;
        end
    end

    always_comb begin
        cap_v = 4'd0;
        for (int i = 0; i < 10; i++) if (cap[i][8]) cap_v = 4'd1;
    end

endmodule
`default_nettype wire
