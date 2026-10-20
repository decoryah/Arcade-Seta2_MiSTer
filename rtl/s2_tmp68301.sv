// Toshiba TMP68301 on-chip peripherals (the 68HC000 is fx68k, in s2_main): interrupt controller, the three 16-bit timers, the
// parallel port as GPIO, and the address decoder / serial registers as storage.  From MAME 0.289's
// src/devices/cpu/m68000/tmp68301.cpp; the behaviour below is that file's, item by item:
//
//   interrupts  11 slots: ext0..2 (pins), serial 0..2, parallel, timer 0..2 (slot 3 unused); ICR level per slot, IMR mask, IPR
//               pending, IISR in service.  The CPU's level is the highest pending unmasked level; among equal levels the slot
//               priority 9,5,0,-,7,3,2,6,8,4,1 (ext0 first).  IACK returns IVNR | vector (ext n: n, timer n: 4 + n), sets IISR,
//               clears the pending bit (not for a level-mode pin), and releases a HOLD_LINE input (`hold_ack`).  External pins:
//               level mode -> pending follows the pin; edge mode -> set when the pin rises.  IPR / IISR writes can only clear.
//   timers      count when TS = 1 and CS = 0, at the CPU clock / 2^P (P = 8..15: 256), on the ticks of a free-running divider of
//               the CPU clock (MAME counts (total_cycles >> div)); max = MAX1 or MAX2 (MR = 1 / 2; 0 = 65536): on reaching it the
//               counter restarts at 0 and, with INT set, the timer's interrupt is raised.  A counter above max runs to 65535 first.
//               TS = 0 holds the counter at 0; writing the counter of timer 1 / 2 clears it (timer 0: no effect, as MAME).
//   parallel    GPIO (the reset mode): read = (PDR & PDIR) | (pins & ~PDIR) (all PDR when PDIR = FFFF); a write of PDR or PDIR
//               with PDIR != 0 presents PDR & PDIR on the outputs (`par_wr` pulse).
//   serial      not used by the seta2.cpp games (MAME's TX / RX state machines are not modelled): the registers are stored,
//               SSR reads TXE, plus TXRDY once TXEN is set.
//
// Registers at 0xFFFC00-0xFFFFFF (the word address within that range = reg_addr[9:1]); MAME's map quirks kept: 0xFFFC9D reads
// IVNR, 0xFFFE40 (TCR2) reads TCR1.
`default_nettype none

module s2_tmp68301 (
    input  logic        clk,
    input  logic        rst,
    input  logic        cpu_tick,               // one pulse per CPU clock cycle (the timers' clock)

    // register access (a CPU bus cycle in 0xFFFC00-0xFFFFFF): one clock, read data combinational from the registers
    input  logic        reg_we,                 // write strobe (one clock)
    input  logic [9:1]  reg_addr,
    input  logic [15:0] reg_din,
    input  logic  [1:0] reg_be,                 // {UDS, LDS}
    output logic [15:0] reg_dout,

    // interrupts
    input  logic  [2:0] ext_pin,                // INT0..2 levels
    output logic  [2:0] ipl,                    // the level for the CPU (0 = none)
    input  logic        iack,                   // one clock: the CPU's IACK cycle takes the vector
    output logic  [7:0] vector,                 // IVNR | vector of the interrupt IACK would take now
    output logic  [2:0] hold_ack,               // one clock with iack: ext slot n acknowledged (releases a HOLD_LINE pin)

    // parallel port
    input  logic [15:0] par_in,
    output logic [15:0] par_out,                // PDR & PDIR as last presented
    output logic        par_wr                  // pulse: MAME's parallel_w_cb(PDR & PDIR)
);

    // ------------------------------------------------------------------ registers
    logic  [7:0] amar0, aamr0, aacr0, amar1, aamr1, aacr1, aacr2, ator;
    logic [15:0] arelr;
    logic  [7:0] icr [10];
    logic [10:0] imr, ipr, iisr;
    logic  [7:0] ivnr, ieir;
    logic [15:0] pdir, pdr;
    logic  [7:0] pcr, pcmr, pmr, ppr1, ppr2;
    logic  [7:0] smr [3], scmr [3], sbrr [3], sdrt [3];
    logic  [7:0] spr, scr;
    logic [15:0] tcr [3], tmcr1 [3], tmcr2 [3], tctr [3];
    logic  [2:0] ext_d;

    function automatic [15:0] combine(input [15:0] old, input [15:0] d, input [1:0] be);
        combine = {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
    endfunction

    // the GPIO read
    wire        gpio = (pcr[3:0] == 4'd0) || (pcr[3:0] == 4'd4) || (pcr[3:0] == 4'd8) || (pcr[3:0] == 4'd12);   // modes 0.0 / 0.1
    wire [15:0] pdr_rd = (!gpio || pdir == 16'hffff) ? pdr : ((pdr & pdir) | (par_in & ~pdir));

    // ------------------------------------------------------------------ interrupt selection (interrupt_get_current)
    // slot -> its ICR, level, priority; vector number per slot (ext n -> n, timer n -> 4 + n; serial / parallel never raised here)
    function automatic [3:0] slot_prio(input int s);
        case (s)
            0: slot_prio = 9;  1: slot_prio = 5;  2: slot_prio = 0;
            4: slot_prio = 7;  5: slot_prio = 3;  6: slot_prio = 2;  7: slot_prio = 6;
            8: slot_prio = 8;  9: slot_prio = 4;  10: slot_prio = 1;
            default: slot_prio = 0;
        endcase
    endfunction
    // the winner, worked out from the request / mask / level registers and registered (IPL, the vector and the IACK side effects
    // all use the registered copy: one clock behind the requests)
    logic  [2:0] cur_level, c_level;
    logic  [3:0] cur_slot, c_slot;
    logic  [4:0] cur_vec, c_vec;
    logic        cur_any, c_any;
    always_ff @(posedge clk) begin cur_level <= c_level; cur_slot <= c_slot; cur_vec <= c_vec; cur_any <= c_any; end
    always_comb begin
        logic [10:0] active;
        logic  [2:0] lv;
        active = ipr & ~imr;
        c_level = 3'd0; c_slot = 4'd0; c_vec = 5'h1f; c_any = 1'b0;
        lv = 3'd0;
        // MAME scans the vectors in order 0..31; the ones raised here: ext0..2 (vectors 0, 1, 2 = slots 0, 1, 2) and the timers
        // (vectors 4, 5, 6 = slots 8, 9, 10).  A candidate replaces the current one when its level is higher, or equal with a
        // higher slot priority.
        for (int k = 0; k < 6; k++) begin
            int s, v;
            v = (k < 3) ? k : k + 1;
            s = (k < 3) ? k : k + 5;
            lv = icr[(k < 3) ? k : k + 4][2:0];
            if (active[s] && lv != 3'd0 && !(lv < c_level) &&
                !(lv == c_level && c_any && slot_prio(s) < slot_prio(int'(c_slot)))) begin
                c_level = lv; c_slot = 4'(s); c_vec = 5'(v); c_any = 1'b1;
            end
        end
    end
    assign ipl    = cur_level;
    assign vector = ivnr | {3'd0, cur_vec};

    // ------------------------------------------------------------------ timers
    logic  [7:0] presc;                         // free-running divider of the CPU clock
    logic  [2:0] t_tick;
    always_comb begin
        for (int c = 0; c < 3; c++) begin
            logic [3:0] p;
            p = tcr[c][13:10];
            // tick when the divider's low `div` bits roll over: div = P (0..7), 8 for P >= 8
            case (p)
                4'd0: t_tick[c] = cpu_tick;
                4'd1: t_tick[c] = cpu_tick && presc[0];
                4'd2: t_tick[c] = cpu_tick && &presc[1:0];
                4'd3: t_tick[c] = cpu_tick && &presc[2:0];
                4'd4: t_tick[c] = cpu_tick && &presc[3:0];
                4'd5: t_tick[c] = cpu_tick && &presc[4:0];
                4'd6: t_tick[c] = cpu_tick && &presc[5:0];
                4'd7: t_tick[c] = cpu_tick && &presc[6:0];
                default: t_tick[c] = cpu_tick && &presc[7:0];
            endcase
        end
    end

    // ------------------------------------------------------------------ register read
    always_comb begin
        reg_dout = 16'h0000;
        case ({reg_addr, 1'b0})
            10'h000: reg_dout = {amar0, aamr0};
            10'h002: reg_dout = {8'h00, aacr0};
            10'h004: reg_dout = {amar1, aamr1};
            10'h006: reg_dout = {8'h00, aacr1};
            10'h008: reg_dout = {8'h00, aacr2};
            10'h00a: reg_dout = {8'h00, ator};
            10'h00c: reg_dout = arelr;
            10'h080, 10'h082, 10'h084, 10'h086, 10'h088, 10'h08a, 10'h08c, 10'h08e, 10'h090, 10'h092:
                     reg_dout = {8'h00, icr[reg_addr[4:1]]};
            10'h094: reg_dout = {5'd0, imr};
            10'h096: reg_dout = {5'd0, ipr};
            10'h098: reg_dout = {5'd0, iisr};
            10'h09a: reg_dout = {8'h00, ivnr};
            10'h09c: reg_dout = {8'h00, ivnr};                  // MAME: 0xFFFC9D reads IVNR
            10'h100: reg_dout = pdir;
            10'h102: reg_dout = {8'h00, pcr};
            10'h104: reg_dout = {8'h00, 8'h40};                 // PSR
            10'h106: reg_dout = {8'h00, pcmr};
            10'h108: reg_dout = {pmr, pmr};
            10'h10a: reg_dout = pdr_rd;
            10'h10c: reg_dout = {8'h00, ppr1};
            10'h10e: reg_dout = {8'h00, ppr2};
            10'h180: reg_dout = {8'h00, smr[0]};
            10'h182: reg_dout = {8'h00, scmr[0]};
            10'h184: reg_dout = {8'h00, sbrr[0]};
            10'h186: reg_dout = {8'h00, 5'd0, 1'b1, 1'b0, scmr[0][0]};
            10'h18c: reg_dout = {8'h00, spr};
            10'h18e: reg_dout = {8'h00, scr};
            10'h190: reg_dout = {8'h00, smr[1]};
            10'h192: reg_dout = {8'h00, scmr[1]};
            10'h194: reg_dout = {8'h00, sbrr[1]};
            10'h196: reg_dout = {8'h00, 5'd0, 1'b1, 1'b0, scmr[1][0]};
            10'h1a0: reg_dout = {8'h00, smr[2]};
            10'h1a2: reg_dout = {8'h00, scmr[2]};
            10'h1a4: reg_dout = {8'h00, sbrr[2]};
            10'h1a6: reg_dout = {8'h00, 5'd0, 1'b1, 1'b0, scmr[2][0]};
            10'h200: reg_dout = tcr[0];
            10'h204: reg_dout = tmcr1[0];
            10'h20c: reg_dout = tctr[0];
            10'h220: reg_dout = tcr[1];
            10'h224: reg_dout = tmcr1[1];
            10'h228: reg_dout = tmcr2[1];
            10'h22c: reg_dout = tctr[1];
            10'h240: reg_dout = tcr[1];                         // MAME: 0xFFFE40 reads TCR1
            10'h244: reg_dout = tmcr1[2];
            10'h248: reg_dout = tmcr2[2];
            10'h24c: reg_dout = tctr[2];
            default: reg_dout = 16'h0000;
        endcase
    end

    // ------------------------------------------------------------------ state
    wire [9:0] wa = {reg_addr, 1'b0};
    always_ff @(posedge clk) begin
        par_wr   <= 1'b0;
        hold_ack <= 3'd0;
        ext_d    <= ext_pin;
        if (cpu_tick) presc <= presc + 8'd1;

        if (rst) begin
            amar0 <= 8'h00; amar1 <= 8'h00; aamr0 <= 8'hff; aamr1 <= 8'hff;
            aacr0 <= 8'h3d; aacr1 <= 8'h18; aacr2 <= 8'h18; ator <= 8'h08; arelr <= 16'hfffc;
            for (int i = 0; i < 10; i++) icr[i] <= 8'h07;
            imr <= 11'h7f7; ipr <= 11'h000; iisr <= 11'h000; ivnr <= 8'h00; ieir <= 8'h00;
            pdir <= 16'h0000; pdr <= 16'h0000; pcr <= 8'h00; pcmr <= 8'h00; pmr <= 8'h00; ppr1 <= 8'h00; ppr2 <= 8'h00;
            for (int i = 0; i < 3; i++) begin
                smr[i] <= 8'hc2; scmr[i] <= 8'h10; sbrr[i] <= 8'h01; sdrt[i] <= 8'h00;
                tcr[i] <= (i == 0) ? 16'h0052 : 16'h0012; tmcr1[i] <= 16'h0000; tmcr2[i] <= 16'h0000; tctr[i] <= 16'h0000;
            end
            spr <= 8'h00; scr <= 8'ha1;
            presc <= 8'd0;
            ext_d <= 3'd0;
            par_out <= 16'h0000;
        end else begin
            // ---------------- external pins (execute_set_input, on a change)
            for (int n = 0; n < 3; n++) begin
                if (ext_pin[n] != ext_d[n]) begin
                    if (icr[n][3]) ipr[n] <= ext_pin[n];                 // level
                    else if (ext_pin[n]) ipr[n] <= 1'b1;                 // edge
                end
            end

            // ---------------- timers (timer_sync per tick)
            for (int c = 0; c < 3; c++) begin
                logic [16:0] maxv;
                logic [1:0]  mr;
                mr   = tcr[c][5:4];
                maxv = (mr == 2'd1) ? {1'b0, tmcr1[c]} : {1'b0, tmcr2[c]};
                if (maxv == 17'd0) maxv = 17'h10000;
                if (!tcr[c][0]) tctr[c] <= 16'h0000;
                else if (!tcr[c][1] && t_tick[c]) begin
                    if (mr == 2'd1 || mr == 2'd2) begin
                        if ({1'b0, tctr[c]} >= maxv) begin
                            tctr[c] <= tctr[c] + 16'd1;                  // above max: on to 65535 and round
                        end else if ({1'b0, tctr[c]} + 17'd1 >= maxv) begin
                            tctr[c] <= 16'h0000;
                            if (tcr[c][2]) ipr[8 + c] <= 1'b1;            // interrupt_internal_trigger(4 + ch)
                        end else tctr[c] <= tctr[c] + 16'd1;
                    end else tctr[c] <= tctr[c] + 16'd1;
                end
            end

            // ---------------- IACK (interrupt_callback)
            if (iack && cur_any) begin
                if (cur_slot < 4'd3) hold_ack[cur_slot[1:0]] <= 1'b1;
                iisr[cur_slot] <= 1'b1;
                if (cur_slot >= 4'd3 || !icr[cur_slot][3]) ipr[cur_slot] <= 1'b0;
            end

            // ---------------- register writes
            if (reg_we) begin
                case (wa)
                    10'h000: begin if (reg_be[1]) amar0 <= reg_din[15:8]; if (reg_be[0]) aamr0 <= reg_din[7:0]; end
                    10'h002: if (reg_be[0]) aacr0 <= reg_din[7:0] & 8'h3f;
                    10'h004: begin if (reg_be[1]) amar1 <= reg_din[15:8]; if (reg_be[0]) aamr1 <= reg_din[7:0]; end
                    10'h006: if (reg_be[0]) aacr1 <= reg_din[7:0] & 8'h3f;
                    10'h008: if (reg_be[0]) aacr2 <= reg_din[7:0] & 8'h1f;
                    10'h00a: if (reg_be[0]) ator  <= reg_din[7:0] & 8'h0f;
                    10'h00c: arelr <= combine(arelr, reg_din, reg_be) & 16'hfffc;
                    10'h080, 10'h082, 10'h084: if (reg_be[0]) begin
                        icr[reg_addr[4:1]] <= reg_din[7:0] & 8'h1f;
                        // switching to level with the pin on raises the interrupt
                        if (reg_din[3] && ext_pin[reg_addr[2:1]]) ipr[reg_addr[2:1]] <= 1'b1;
                    end
                    10'h086, 10'h088, 10'h08a, 10'h08c, 10'h08e, 10'h090, 10'h092:
                        if (reg_be[0]) icr[reg_addr[4:1]] <= reg_din[7:0] & 8'h07;
                    10'h094: begin
                        logic [15:0] nm;
                        nm = combine({5'd0, imr}, reg_din, reg_be);
                        imr <= nm[10:0] & 11'h7f7;
                    end
                    10'h096: begin
                        // ipr &= COMBINE(ipr, data): level-mode pins cannot be cleared this way
                        logic [15:0] n;
                        n = combine({5'd0, ipr}, reg_din, reg_be);
                        for (int k = 0; k < 3; k++) if (icr[k][3]) n[k] = 1'b1;
                        ipr <= ipr & n[10:0];
                    end
                    10'h098: begin
                        logic [15:0] ni;
                        ni = combine({5'd0, iisr}, reg_din, reg_be);
                        iisr <= iisr & ni[10:0];
                    end
                    10'h09a: if (reg_be[0]) ivnr <= reg_din[7:0] & 8'he0;
                    10'h09c: if (reg_be[0]) ieir <= reg_din[7:0] & 8'h7f;
                    10'h100: begin
                        logic [15:0] nd;
                        nd = combine(pdir, reg_din, reg_be);
                        pdir <= nd;
                        if (nd != pdir && nd != 16'h0000) begin par_out <= pdr & nd; par_wr <= 1'b1; end
                    end
                    10'h102: if (reg_be[0]) pcr  <= reg_din[7:0] & 8'h0f;
                    10'h106: if (reg_be[0]) pcmr <= reg_din[7:0] & 8'h1f;
                    10'h108: pmr <= (reg_be[0] ? reg_din[7:0] : reg_din[15:8]) & 8'h0f;
                    10'h10a: begin
                        logic [15:0] nd;
                        nd = combine(pdr, reg_din, reg_be);
                        pdr <= nd;
                        if (nd != pdr && gpio && pdir != 16'h0000) begin par_out <= nd & pdir; par_wr <= 1'b1; end
                    end
                    10'h10c: if (reg_be[0]) ppr1 <= reg_din[7:0] & 8'h7f;
                    10'h10e: if (reg_be[0]) ppr2 <= reg_din[7:0] & 8'h7f;
                    10'h180: if (reg_be[0]) smr[0]  <= reg_din[7:0];
                    10'h182: if (reg_be[0]) scmr[0] <= reg_din[7:0] & 8'h3f;
                    10'h184: if (reg_be[0]) sbrr[0] <= reg_din[7:0];
                    10'h188: if (reg_be[0]) sdrt[0] <= reg_din[7:0];
                    10'h18c: if (reg_be[0]) spr <= reg_din[7:0];
                    10'h18e: if (reg_be[0]) scr <= reg_din[7:0] & 8'ha1;
                    10'h190: if (reg_be[0]) smr[1]  <= reg_din[7:0];
                    10'h192: if (reg_be[0]) scmr[1] <= reg_din[7:0] & 8'h1d;
                    10'h194: if (reg_be[0]) sbrr[1] <= reg_din[7:0];
                    10'h198: if (reg_be[0]) sdrt[1] <= reg_din[7:0];
                    10'h1a0: if (reg_be[0]) smr[2]  <= reg_din[7:0];
                    10'h1a2: if (reg_be[0]) scmr[2] <= reg_din[7:0] & 8'h1d;
                    10'h1a4: if (reg_be[0]) sbrr[2] <= reg_din[7:0];
                    10'h1a8: if (reg_be[0]) sdrt[2] <= reg_din[7:0];
                    10'h200: tcr[0] <= (combine(tcr[0], reg_din, reg_be) & 16'hff87) | 16'h0050;
                    10'h204: tmcr1[0] <= combine(tmcr1[0], reg_din, reg_be);
                    10'h220: tcr[1] <= combine(tcr[1], reg_din, reg_be) & 16'hfff7;
                    10'h224: tmcr1[1] <= combine(tmcr1[1], reg_din, reg_be);
                    10'h228: tmcr2[1] <= combine(tmcr2[1], reg_din, reg_be);
                    10'h22c: tctr[1] <= 16'h0000;
                    10'h240: tcr[2] <= combine(tcr[2], reg_din, reg_be) & 16'hfff7;
                    10'h244: tmcr1[2] <= combine(tmcr1[2], reg_din, reg_be);
                    10'h248: tmcr2[2] <= combine(tmcr2[2], reg_din, reg_be);
                    10'h24c: tctr[2] <= 16'h0000;
                    default: ;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
