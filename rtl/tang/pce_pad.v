//
// PC Engine pad interface.
//
// pce_top drives JOY_OUT = {CLR, SEL} and expects the 4 bit nibble JOY_IN.
// The multiplexing (and the active-low sense of the data) matches the MiST /
// MiSTer top level of this core:
//
//   CLR = 1            -> 0000
//   CLR = 0, SEL = 0   -> {Run, Select, II, I}      (active low)
//   CLR = 0, SEL = 1   -> {Left, Down, Right, Up}   (active low)
//
// A 6-button pad uses alternating scans; the regular 2-button mapping is
// retained when pad_mode is low.
//

module pce_pad (
    input  wire       clk,

    input  wire [1:0] joy_out,     // {CLR, SEL}
    output reg  [3:0] joy_in,
    input  wire       pad_mode,

    // 1 = pressed
    input  wire       up,
    input  wire       down,
    input  wire       left,
    input  wire       right,
    input  wire       btn_i,
    input  wire       btn_ii,
    input  wire       btn_iii,
    input  wire       btn_iv,
    input  wire       btn_v,
    input  wire       btn_vi,
    input  wire       sel,
    input  wire       run
);

wire [3:0] buttons_nib = ~{run, sel, btn_ii, btn_i};
wire [3:0] dpad_nib    = ~{left, down, right, up};
wire [3:0] six_nib     = ~{btn_vi, btn_v, btn_iv, btn_iii};
reg        last_clr = 1'b0;
reg        six_scan = 1'b0;

always @(posedge clk) begin
    if (pad_mode && !last_clr && joy_out[1])
        six_scan <= ~six_scan;

    if (joy_out[1])
        joy_in <= 4'b0000;
    else if (joy_out[0]) begin
        if (pad_mode && six_scan)
            joy_in <= 4'b0000;
        else
            joy_in <= dpad_nib;
    end else begin
        if (pad_mode && six_scan)
            joy_in <= six_nib;
        else
            joy_in <= buttons_nib;
    end

    last_clr <= joy_out[1];
end

endmodule
