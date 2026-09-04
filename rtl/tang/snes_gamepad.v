//
// SNES / NES style shift register game pad reader.
//
// Three wires (LATCH, CLK, DATA) with the usual 12 us timing.  A SNES pad
// returns 16 bits, active low, in the order
//
//   0:B  1:Y  2:Select  3:Start  4:Up  5:Down  6:Left  7:Right
//   8:A  9:X 10:L      11:R     12..15: 1
//
// With DATA pulled up, an unconnected port simply reports "no button pressed".
//

module snes_gamepad #(
    // half a pad clock period, 6 us at 43.2 MHz
    parameter TICK_DIV = 256
) (
    input  wire        clk,
    input  wire        resetn,

    output reg         pad_latch,
    output reg         pad_clk,
    input  wire        pad_data,

    output reg  [11:0] buttons     // 1 = pressed
);

reg [15:0] div;
reg [5:0]  step;
reg [15:0] shifter;

initial begin
    pad_latch = 1'b0;
    pad_clk   = 1'b1;
    buttons   = 12'd0;
    div       = 16'd0;
    step      = 6'd0;
    shifter   = 16'hFFFF;
end

wire tick = (div == TICK_DIV[15:0] - 16'd1);

always @(posedge clk) begin
    if (tick)
        div <= 16'd0;
    else
        div <= div + 16'd1;

    if (tick) begin
        if (step == 6'd0 || step == 6'd1) begin
            // latch high for two ticks (12 us)
            pad_latch <= 1'b1;
            pad_clk   <= 1'b1;
            step      <= step + 6'd1;
        end else if (step < 6'd34) begin
            pad_latch <= 1'b0;
            if (step[0] == 1'b0) begin
                // even step: clock low, the pad presents the current bit
                pad_clk <= 1'b0;
                shifter <= {pad_data, shifter[15:1]};
            end else begin
                // odd step: clock high, the pad advances
                pad_clk <= 1'b1;
            end
            step <= step + 6'd1;
        end else begin
            // frame finished
            buttons <= ~shifter[11:0];
            step    <= 6'd0;
            pad_clk <= 1'b1;
        end
    end

    if (!resetn) begin
        div       <= 16'd0;
        step      <= 6'd0;
        pad_latch <= 1'b0;
        pad_clk   <= 1'b1;
        shifter   <= 16'hFFFF;
        buttons   <= 12'd0;
    end
end

endmodule
