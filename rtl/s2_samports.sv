// The input ports of Sammy's light-gun board (MAME 0.289 seta2.cpp: samshoot_map, INPUT_PORTS deerhunt / wschamp / trophyht), active
// low, from the players' controls: shared by the top level (Seta2.sv) and the machine bench (sim/sys/tb_sys.sv).
//
//   BUTTONS  $400002  bit 0 trigger P1, bit 1 pump P1; two guns: bit 4 trigger P2, bit 5 pump P2; the location test: bit 1 trigger P2
//   TRIGGER  $700000  bit 7 START1 (bits 5 / 6: MAME's "custom" trigger bits, never driven: 1)
//   PUMP     $700002  bit 7 START2 (two-gun games; Deer / Turkey Hunting: unknown, 1)
//   COIN     $700004  bit 0 coin 1, bit 1 coin 2, bit 2 service 1, bit 3 service 2
//   GUN1 / GUN2 $500000 / $580000: { Y, X } in MAME's units (X 0x25..0xC5, Y 0x08..0xF8); Deer / Turkey Hunting's GUN2: unknown, 1s
`default_nettype none
module s2_samports (
    input  wire  [1:0] layout,              // header byte 33: 0 one gun, 1 two guns with pumps, 2 two guns, triggers only
    input  wire        start1, start2, coin1, coin2, svc,
    input  wire  [1:0] trig, pump,          // { P2, P1 }
    input  wire [15:0] gun1, gun2,
    output reg  [15:0] p_buttons, p_trigger, p_pump, p_coin, p_gun1, p_gun2
);
    always @* begin
        case (layout)
            2'd1:    p_buttons = {8'hff, 2'b11, ~pump[1], ~trig[1], 2'b11, ~pump[0], ~trig[0]};
            2'd2:    p_buttons = {8'hff, 6'b111111, ~trig[1], ~trig[0]};
            default: p_buttons = {8'hff, 6'b111111, ~pump[0], ~trig[0]};
        endcase
        p_trigger = {8'hff, ~start1, 7'h7f};
        p_pump    = {8'hff, (layout != 2'd0) ? ~start2 : 1'b1, 7'h7f};
        p_coin    = {8'hff, 4'hf, 1'b1, ~svc, ~coin2, ~coin1};
        p_gun1    = gun1;
        p_gun2    = (layout != 2'd0) ? gun2 : 16'hffff;
    end
endmodule
`default_nettype wire
