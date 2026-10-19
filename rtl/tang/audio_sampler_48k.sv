// 48 kHz stereo sample clock for HDMI audio.
// The on-board I2S output keeps its independent 48.2 kHz clock.
module audio_sampler_48k #(
    parameter CLOCK_HZ = 43_200_000
) (
    input  wire               clk_sys,
    input  wire               resetn,
    input  wire signed [19:0] audio_left,
    input  wire signed [19:0] audio_right,
    output reg                clk_audio,
    output reg  signed [15:0] sample_left,
    output reg  signed [15:0] sample_right
);

function integer gcd(input integer a, input integer b);
    integer remainder;
    begin
        while (b != 0) begin
            remainder = a % b;
            a = b;
            b = remainder;
        end
        gcd = a;
    end
endfunction
localparam DIVISOR = gcd(CLOCK_HZ, 96_000);
localparam FRACTION_DEN = 96_000 / DIVISOR;
localparam FRACTION_NUM = (CLOCK_HZ % 96_000) / DIVISOR;
localparam HALF_PERIOD = CLOCK_HZ / 96_000;
localparam COUNT_BITS = $clog2(HALF_PERIOD + 1);
localparam FRACTION_BITS = FRACTION_DEN > 1 ? $clog2(FRACTION_DEN) : 1;
reg [COUNT_BITS-1:0] half_period_count;
reg [FRACTION_BITS-1:0] fraction;
wire long_period = fraction >= FRACTION_DEN - FRACTION_NUM;

always @(posedge clk_sys) begin
    if (!resetn) begin
        half_period_count <= 0;
        fraction          <= 0;
        clk_audio         <= 1'b0;
        sample_left       <= 16'sd0;
        sample_right      <= 16'sd0;
    end else if (half_period_count == HALF_PERIOD - 1 + long_period) begin
        half_period_count <= 0;
        fraction <= long_period ? fraction - (FRACTION_DEN - FRACTION_NUM) :
                                  fraction + FRACTION_NUM;
        clk_audio         <= ~clk_audio;
        if (!clk_audio) begin
            sample_left  <= audio_left[19:4];
            sample_right <= audio_right[19:4];
        end
    end else begin
        half_period_count <= half_period_count + 1'b1;
    end
end

endmodule
