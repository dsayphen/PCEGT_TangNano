//
// Simple digital tone control + master volume for the PSG audio path.
//
// Each channel is split into a low band (one-pole leaky integrator) and a
// high band (input minus low band); bass/treble boost or cut those bands
// before they are added back to the dry signal, then the result is scaled
// by the master volume and saturated back to 20 bits.
//
// bass/treble are 0..10 with 5 = flat (see iosys.v audio_bass/audio_treble).
// volume is 0..10, 0 = mute, 10 = unity gain.
//
module audio_tone (
    input  wire        clk,
    input  wire        resetn,
    input  wire [3:0]  volume,
    input  wire [3:0]  bass,
    input  wire [3:0]  treble,
    input  wire signed [19:0] in_l,
    input  wire signed [19:0] in_r,
    output reg  signed [19:0] out_l,
    output reg  signed [19:0] out_r
);

// Master volume gain table, Q8 fixed point (256 = unity).
function [8:0] vol_gain;
    input [3:0] v;
    begin
        case (v)
            4'd0:  vol_gain = 9'd0;
            4'd1:  vol_gain = 9'd26;
            4'd2:  vol_gain = 9'd51;
            4'd3:  vol_gain = 9'd77;
            4'd4:  vol_gain = 9'd102;
            4'd5:  vol_gain = 9'd128;
            4'd6:  vol_gain = 9'd154;
            4'd7:  vol_gain = 9'd179;
            4'd8:  vol_gain = 9'd205;
            4'd9:  vol_gain = 9'd230;
            default: vol_gain = 9'd256;
        endcase
    end
endfunction

localparam BASS_SHIFT   = 3;  // each bass step is ~1/8 of the low band
localparam TREBLE_SHIFT = 3;  // each treble step is ~1/8 of the high band

// Registered first: the CD/ADPCM mixer feeding in_l/in_r fails timing
// when chained straight into the multipliers below.
reg signed [19:0] in_l_q, in_r_q;
always @(posedge clk) begin
    in_l_q <= in_l;
    in_r_q <= in_r;
end

reg signed [19:0] lp_l, lp_r;
wire signed [19:0] hp_l = in_l_q - lp_l;
wire signed [19:0] hp_r = in_r_q - lp_r;

wire signed [4:0] bass_trim   = {1'b0, bass}   - 5'sd5; // -5..+5
wire signed [4:0] treble_trim = {1'b0, treble} - 5'sd5; // -5..+5

wire signed [24:0] shaped_l = {{5{in_l_q[19]}}, in_l_q} +
                              ((bass_trim   * lp_l) >>> BASS_SHIFT) +
                              ((treble_trim * hp_l) >>> TREBLE_SHIFT);
wire signed [24:0] shaped_r = {{5{in_r_q[19]}}, in_r_q} +
                              ((bass_trim   * lp_r) >>> BASS_SHIFT) +
                              ((treble_trim * hp_r) >>> TREBLE_SHIFT);

// The bass/treble multiply-adds above can overflow 20 bits, saturate here.
wire signed [19:0] shaped_l_sat =
    (shaped_l[24] != shaped_l[23]) ? {shaped_l[24], {19{~shaped_l[24]}}} : shaped_l[19:0];
wire signed [19:0] shaped_r_sat =
    (shaped_r[24] != shaped_r[23]) ? {shaped_r[24], {19{~shaped_r[24]}}} : shaped_r[19:0];


wire signed [29:0] gained_l = shaped_l_sat * $signed({1'b0, vol_gain(volume)});
wire signed [29:0] gained_r = shaped_r_sat * $signed({1'b0, vol_gain(volume)});

always @(posedge clk) begin
    if (!resetn) begin
        lp_l  <= 20'sd0;
        lp_r  <= 20'sd0;
        out_l <= 20'sd0;
        out_r <= 20'sd0;
    end else begin
        lp_l <= lp_l + (hp_l >>> 4);
        lp_r <= lp_r + (hp_r >>> 4);

        out_l <= gained_l[27:8];
        out_r <= gained_r[27:8];
    end
end

endmodule
