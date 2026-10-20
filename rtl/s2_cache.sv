// 68000 program ROM cache over the DDR3: direct mapped, 8 KB, 32-byte lines (4 DDR3 beats).  A miss asks the DDR3 arbiter for the
// line; the CPU's bus cycle waits.  (Structure of the owner's cp_cache.sv / omg_cache.sv, with 64-bit fills.)
//
// The program section of the image is in the 68000's byte order (byte 0 = the high byte of word 0); a DDR3 beat holds image bytes
// 8b..8b+7 in its bytes 0..7, so word k of a beat is {beat byte 2k, beat byte 2k+1}.
//
// word address a = addr[21:1] (21 bits): tag a[20:12] | index a[11:4] | beat a[3:2] | word a[1:0]
`default_nettype none
module s2_cache (
    input  logic        clk,
    input  logic        inval,            // rising edge: sweep all lines invalid (after a ROM load)
    output logic        busy,

    input  logic        req,              // level, until ack
    input  logic [21:1] addr,
    output logic        ack,              // one clock, data valid
    output logic [15:0] data,

    output logic        fill_req,         // level, until fill_done
    output logic [21:5] fill_addr,        // line address (32-byte units)
    input  logic        fill_wr,          // a beat of the line
    input  logic  [1:0] fill_idx,
    input  logic [63:0] fill_data,
    input  logic        fill_done
);
    logic [20:0] a;
    wire  [7:0]  index = a[11:4];
    wire  [8:0]  tag   = a[20:12];

    typedef enum logic [2:0] {S_SWEEP, S_IDLE, S_RD, S_CMP, S_FILL} st_t;
    st_t st = S_SWEEP;
    logic [7:0] sweep = 8'd0;
    logic       inval_d;

    // tag RAM: {valid, tag}
    wire         tag_we    = (st == S_SWEEP) || (st == S_FILL && fill_done);
    wire  [7:0]  tag_waddr = (st == S_SWEEP) ? sweep : index;
    wire  [9:0]  tag_wdata = (st == S_SWEEP) ? 10'd0 : {1'b1, tag};
    logic [9:0]  tag_q;
    (* ramstyle = "no_rw_check" *) logic [9:0] tags [256];
    always_ff @(posedge clk) begin
        if (tag_we) tags[tag_waddr] <= tag_wdata;
        tag_q <= tags[index];
    end

    // data RAM: 1024 beats
    logic [63:0] dat_q;
    (* ramstyle = "no_rw_check" *) logic [63:0] dat [1024];
    always_ff @(posedge clk) begin
        if (fill_wr) dat[{index, fill_idx}] <= fill_data;
        dat_q <= dat[a[11:2]];
    end

    wire hit = tag_q[9] && (tag_q[8:0] == tag);
    assign ack       = (st == S_CMP) && hit;
    wire  [1:0] wi   = a[1:0];
    assign data      = {dat_q[16 * wi +: 8], dat_q[16 * wi + 8 +: 8]};
    assign busy      = (st == S_SWEEP);
    assign fill_addr = {tag, index};

    always_ff @(posedge clk) begin
        inval_d <= inval;
        if (inval && !inval_d) begin
            st <= S_SWEEP; sweep <= 8'd0; fill_req <= 1'b0;
        end else case (st)
            S_SWEEP: begin
                sweep <= sweep + 8'd1;
                if (sweep == 8'hff) st <= S_IDLE;
            end
            S_IDLE: if (req && !ack) begin a <= addr; st <= S_RD; end
            S_RD:   st <= S_CMP;
            S_CMP:  if (hit) st <= S_IDLE;
                    else begin fill_req <= 1'b1; st <= S_FILL; end
            S_FILL: if (fill_done) begin fill_req <= 1'b0; st <= S_RD; end
            default: st <= S_IDLE;
        endcase
    end
endmodule
`default_nettype wire
