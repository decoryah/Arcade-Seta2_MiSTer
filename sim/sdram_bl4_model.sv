// Behavioural SDR SDRAM for simulation: 4 banks, CL2, burst length from the mode register (1 or 4 reads), single-location
// writes, auto precharge.  Timing as the owner's sdram_model.sv with PHASE_LAG 0 (MiSTer: the chip clocked from the shifted PLL
// output): a command the controller registers at edge N is seen here at N+1, and read word k of a burst is on the bus during
// (N+2+k, N+3+k], so the controller's I/O register samples it at edge N+3+k.
//
// Checks (counted in `errors`, printed): ACTIVATE of an open / precharging bank, READ / WRITE without an open row or sooner than
// tRCD (2) after its ACTIVATE, REFRESH with a bank not idle, an ACTIVATE sooner than tRC after the last one of the bank, two bursts'
// data on the bus at once, and a read word masked by DQM (DQM high two clocks before the word: the 128 MB module drives DQM from
// A12 / A11, so an ACTIVATE of a high row during a burst would do that).
`default_nettype none

module sdram_bl4_model #(parameter AW = 24) (
    input  logic        clk,
    inout  wire  [15:0] dq,
    input  logic [12:0] a,
    input  logic [1:0]  ba,
    input  logic        dqml, dqmh,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic        cke
);
    logic [15:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
    integer      errors /*verilator public_flat_rw*/;
    integer      reads  /*verilator public_flat_rw*/;

    logic [12:0] row_open [4];
    logic        row_active [4];
    longint      busy_until [4];            // the bank cannot be activated before this cycle (auto precharge, tRC)
    longint      act_at [4];
    longint      cyc;                       // (64 bits: runs of more than 2^31 clocks)
    logic  [2:0] bl;                        // burst length (mode register)

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRIT = 4'b0100, CMD_PRE = 4'b0010, CMD_REF = 4'b0001,
               CMD_MRS = 4'b0000;

    logic [15:0] dq_out;
    logic        dq_oe;
    assign dq = dq_oe ? dq_out : 16'hzzzz;

    // read words queued: the word to put on the bus at the next edges
    logic [15:0] q_d [8];
    logic        q_v [8];
    logic [1:0]  dqm_d1, dqm_d2;           // DQM two edges ago

    initial begin
        errors = 0; reads = 0; cyc = 0; bl = 3'd0;
        for (int i = 0; i < 4; i++) begin row_active[i] = 1'b0; row_open[i] = '0; busy_until[i] = 0; act_at[i] = -100; end
        for (int i = 0; i < 8; i++) q_v[i] = 1'b0;
        dq_oe = 1'b0;
    end

    function automatic [AW-1:0] widx(input [1:0] b, input [12:0] r, input [8:0] c);
        logic [23:0] w;
        w = {b, r, c};
        widx = w[AW-1:0];
    endfunction

    always_ff @(posedge clk) begin
        cyc <= cyc + 1;
        // the bus: one queued word per edge
        dq_oe  <= q_v[0] && !(dqm_d2 != 2'b00);
        dq_out <= q_d[0];
        if (q_v[0] && dqm_d2 != 2'b00) begin
            $display("SDRAM-DQM-MASK: read word masked at cycle %0d", cyc); errors <= errors + 1;
        end
        for (int i = 0; i < 7; i++) begin q_d[i] <= q_d[i + 1]; q_v[i] <= q_v[i + 1]; end
        q_v[7] <= 1'b0;
        dqm_d1 <= {dqmh, dqml};
        dqm_d2 <= dqm_d1;

        case (cmd)
            CMD_ACT: begin
                if (row_active[ba] || cyc < busy_until[ba]) begin
                    $display("SDRAM-PROTOCOL-ERROR: ACTIVATE bank %0d at %0d (open %0d, busy until %0d)", ba, cyc, row_active[ba],
                             busy_until[ba]);
                    errors <= errors + 1;
                end
                if (cyc - act_at[ba] < 7) begin
                    $display("SDRAM-TIMING-ERROR: tRC bank %0d (%0d clocks)", ba, cyc - act_at[ba]); errors <= errors + 1;
                end
                row_open[ba] <= a; row_active[ba] <= 1'b1; act_at[ba] <= cyc;
            end
            CMD_READ: begin
                if (!row_active[ba] || cyc - act_at[ba] < 2) begin
                    $display("SDRAM-PROTOCOL-ERROR: READ bank %0d at %0d (open %0d, %0d after ACT)", ba, cyc, row_active[ba],
                             cyc - act_at[ba]);
                    errors <= errors + 1;
                end
                if (q_v[1]) begin $display("SDRAM-BUS-ERROR: burst overlap at %0d", cyc); errors <= errors + 1; end
                reads <= reads + 1;
                for (int k = 0; k < 4; k++) begin
                    if (k == 0 || bl == 3'd2) begin
                        // word k out at the k-th edge from here (the read itself is at the next one): q[k]
                        q_d[k] <= mem[widx(ba, row_open[ba], {a[8:2], 2'(a[1:0] + 2'(k))})];
                        q_v[k] <= 1'b1;
                    end
                end
                if (a[10]) begin
                    row_active[ba] <= 1'b0;
                    busy_until[ba] <= cyc + ((bl == 3'd2) ? 4 : 1) + 2;
                end
            end
            CMD_WRIT: begin
                if (!row_active[ba] || cyc - act_at[ba] < 2) begin
                    $display("SDRAM-PROTOCOL-ERROR: WRITE bank %0d at %0d", ba, cyc); errors <= errors + 1;
                end
                if (!dqml) mem[widx(ba, row_open[ba], a[8:0])][7:0]  <= dq[7:0];
                if (!dqmh) mem[widx(ba, row_open[ba], a[8:0])][15:8] <= dq[15:8];
                if (a[10]) begin row_active[ba] <= 1'b0; busy_until[ba] <= cyc + 4; end
            end
            CMD_PRE: begin
                if (a[10]) for (int i = 0; i < 4; i++) row_active[i] <= 1'b0;
                else row_active[ba] <= 1'b0;
            end
            CMD_REF: begin
                for (int i = 0; i < 4; i++) if (row_active[i] || cyc < busy_until[i]) begin
                    $display("SDRAM-PROTOCOL-ERROR: REFRESH with bank %0d busy at %0d", i, cyc); errors <= errors + 1;
                end
                for (int i = 0; i < 4; i++) busy_until[i] <= cyc + 7;
            end
            CMD_MRS: bl <= a[2:0];
            default: ;
        endcase
    end
endmodule
`default_nettype wire
