// 48 kHz stereo sample clock for HDMI audio.
// The on-board I2S output keeps its independent 48.2 kHz clock.
module audio_sampler_48k (
    input  wire               clk_sys,
    input  wire               resetn,
    input  wire signed [19:0] audio_left,
    input  wire signed [19:0] audio_right,
    output reg                clk_audio,
    output reg  signed [15:0] sample_left,
    output reg  signed [15:0] sample_right
);

reg [8:0] half_period_count;

always @(posedge clk_sys) begin
    if (!resetn) begin
        half_period_count <= 9'd0;
        clk_audio         <= 1'b0;
        sample_left       <= 16'sd0;
        sample_right      <= 16'sd0;
    end else if (half_period_count == 9'd449) begin
        half_period_count <= 9'd0;
        clk_audio         <= ~clk_audio;
        if (!clk_audio) begin
            sample_left  <= audio_left[19:4];
            sample_right <= audio_right[19:4];
        end
    end else begin
        half_period_count <= half_period_count + 9'd1;
    end
end

endmodule
