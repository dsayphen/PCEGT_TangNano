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
// Only a single 2-button pad is emulated; the multitap is not implemented.
//

module pce_pad (
    input  wire       clk,

    input  wire [1:0] joy_out,     // {CLR, SEL}
    output reg  [3:0] joy_in,

    // 1 = pressed
    input  wire       up,
    input  wire       down,
    input  wire       left,
    input  wire       right,
    input  wire       btn_i,
    input  wire       btn_ii,
    input  wire       sel,
    input  wire       run
);

wire [3:0] buttons_nib = ~{run, sel, btn_ii, btn_i};
wire [3:0] dpad_nib    = ~{left, down, right, up};

always @(posedge clk) begin
    if (joy_out[1])
        joy_in <= 4'b0000;
    else if (joy_out[0])
        joy_in <= dpad_nib;
    else
        joy_in <= buttons_nib;
end

endmodule
