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
// A 6-button pad is not a static 2-button pad with extra bits ORed in: the
// console expects alternating scans per the official PC Engine protocol.
// On alternate scans, SEL=HIGH yields 0000 on the d-pad nibble and SEL=LOW
// returns VI/V/IV/III in place of RUN/SELECT/II/I, while the regular 2-button
// mapping remains available on the other scan.

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
reg        last_clr;
reg        six_scan;

always @(posedge clk) begin
    if (pad_mode && !last_clr && joy_out[1])
        six_scan <= ~six_scan;

    if (joy_out[1])
        joy_in <= 4'b0000;
    else if (joy_out[0]) begin
        if (pad_mode && six_scan)
            joy_in <= 4'b0000;      // official 6-button protocol: d-pad reads 0000
        else
            joy_in <= dpad_nib;
    end else begin
        if (pad_mode && six_scan)
            joy_in <= six_nib;       // VI, V, IV, III
        else
            joy_in <= buttons_nib;   // RUN, SELECT, II, I
    end

    last_clr <= joy_out[1];
end

endmodule
