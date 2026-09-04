//
// I2S transmitter for the Tang Nano 20K on-board audio amplifier.
//
// The board carries a class-D I2S amplifier (HP_BCK / HP_WS / HP_DIN, enabled
// through PA_EN) which auto-detects the sample rate.  Standard Philips I2S
// framing is generated: MSB first, one BCK of delay after the WS edge, data
// changes on the falling edge of BCK so that the receiver can sample it on the
// rising edge.  WS low selects the left channel.
//
// 16 bits per channel, 32 BCK per frame.  With the default divider the frame
// rate is 43.2 MHz / (14 * 2 * 32) = 48.2 kHz.
//

module i2s_tx #(
    // BCK = clk / (2 * BCK_DIV)
    parameter BCK_DIV = 14
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire signed [15:0] left,
    input  wire signed [15:0] right,

    output reg         sck,      // HP_BCK
    output reg         ws,       // HP_WS
    output reg         sd        // HP_DIN
);

reg [7:0]  div;
reg [4:0]  bitcnt;   // 0..31
reg [15:0] shifter;

initial begin
    sck     = 1'b0;
    ws      = 1'b0;
    sd      = 1'b0;
    div     = 8'd0;
    bitcnt  = 5'd0;
    shifter = 16'd0;
end

always @(posedge clk) begin
    if (div == BCK_DIV[7:0] - 8'd1) begin
        div <= 8'd0;
        sck <= ~sck;

        if (sck) begin
            // falling edge of BCK: shift out the next bit
            sd     <= shifter[15];
            shifter <= {shifter[14:0], 1'b0};

            // WS changes one BCK before the MSB of the next word
            if (bitcnt == 5'd15)
                ws <= 1'b1;
            else if (bitcnt == 5'd31)
                ws <= 1'b0;

            // reload one bit before the word starts
            if (bitcnt == 5'd15)
                shifter <= right;
            else if (bitcnt == 5'd31)
                shifter <= left;

            bitcnt <= bitcnt + 5'd1;
        end
    end else begin
        div <= div + 8'd1;
    end

    if (!resetn) begin
        div     <= 8'd0;
        sck     <= 1'b0;
        ws      <= 1'b0;
        sd      <= 1'b0;
        bitcnt  <= 5'd0;
        shifter <= 16'd0;
    end
end

endmodule
