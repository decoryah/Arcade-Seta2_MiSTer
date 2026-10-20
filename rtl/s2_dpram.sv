// One block RAM, two ports on one clock: port A reads and writes, port B reads.  A module of its own so that Quartus 17 infers
// one true dual port RAM: arrays declared inside a generate block with two read ports came out as two simple dual port copies.
// Both reads give the data a clock after the address; a read of the address being written gives either value.
module s2_dpram #(
    parameter int AW = 15,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic          a_we,
    input  logic [DW-1:0] a_d,
    output logic [DW-1:0] a_q,
    input  logic [AW-1:0] b_addr,
    output logic [DW-1:0] b_q
);
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] m [2 ** AW];
    always_ff @(posedge clk) begin
        if (a_we) m[a_addr] <= a_d;
        a_q <= m[a_addr];
    end
    always_ff @(posedge clk) b_q <= m[b_addr];
endmodule
