//
// HDMI/DVI transmitter for the Tang Nano 20K.
//
// Three TMDS channels plus the TMDS clock, serialised with the Gowin OSER10
// primitives and driven off-chip through ELVDS_OBUF differential buffers.
// This is the same output structure the Sipeed Tang Nano 20K HDMI examples and
// NESTang use (GPLv3). Audio packets are inserted into horizontal blanking
// only when the user selects HDMI audio; otherwise this remains DVI-compatible.
//
// hsync / vsync are supplied as active-high pulses and are transmitted with
// negative polarity, which is what a 640x480 style mode expects.
//

module dvi_tx (
    input  wire       clk_pix,      // 25.92 MHz
    input  wire       clk_pix5,     // 129.6 MHz
    input  wire       resetn,

    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    input  wire       de,
    input  wire       hsync,        // active high
    input  wire       vsync,        // active high
    input  wire [10:0] pix_x,
    input  wire [9:0]  pix_y,
    input  wire        audio_enable,
    input  wire        clk_audio,
    input  wire signed [15:0] audio_left,
    input  wire signed [15:0] audio_right,

    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

wire [9:0] tmds_ch0;   // blue  + hsync/vsync
wire [9:0] tmds_ch1;   // green
wire [9:0] tmds_ch2;   // red

reg [1:0] audio_enable_sync;
always @(posedge clk_pix) begin
    if (!resetn)
        audio_enable_sync <= 2'b00;
    else
        audio_enable_sync <= {audio_enable_sync[0], audio_enable};
end
wire hdmi_audio_on = audio_enable_sync[1];

// Rebase the scaler's 819x524/526 timing so the 640x480 active window starts
// at (0,0), leaving its full horizontal blanking interval available for HDMI.
wire [10:0] cx = pix_x >= 11'd152 ? pix_x - 11'd152 : pix_x + 11'd667;
wire [9:0] cy = pix_y >= 10'd42 ? pix_y - 10'd42 : pix_y + 10'd982;

wire island_period = hdmi_audio_on && cx >= 11'd654 && cx < 11'd782;
wire island_preamble = hdmi_audio_on && cx >= 11'd644 && cx < 11'd652;
wire island_guard = hdmi_audio_on &&
                    ((cx >= 11'd652 && cx < 11'd654) ||
                     (cx >= 11'd782 && cx < 11'd784));
wire video_preamble = hdmi_audio_on && cy < 10'd479 &&
                      cx >= 11'd809 && cx < 11'd817;
wire video_guard = hdmi_audio_on && cy < 10'd479 &&
                   cx >= 11'd817 && cx < 11'd819;
wire packet_start = hdmi_audio_on && cx >= 11'd653 && cx < 11'd781 &&
                    cx[4:0] == 5'd13;
wire video_field_end = cx == 11'd639 && cy == 10'd479;

wire [2:0] mode = island_guard ? 3'd4 : island_period ? 3'd3 :
                  video_guard ? 3'd2 : de ? 3'd1 : 3'd0;
wire [1:0] c0 = {~vsync, ~hsync};
wire [1:0] c1 = {1'b0, video_preamble || island_preamble};
wire [1:0] c2 = {1'b0, island_preamble};
wire [8:0] packet_data;
wire [23:0] packet_header;
wire [55:0] packet_sub [3:0];
wire [11:0] island_data = {
    packet_data[8:5], packet_data[4:1],
    (cx != 0), packet_data[0], ~vsync, ~hsync
};

hdmi_audio_packetizer u_audio_packets (
    .clk_pixel       (clk_pix),
    .resetn          (resetn),
    .audio_enable    (hdmi_audio_on),
    .clk_audio       (clk_audio),
    .sample_left     (audio_left),
    .sample_right    (audio_right),
    .packet_start    (packet_start),
    .packet_period   (island_period),
    .video_field_end (video_field_end),
    .header          (packet_header),
    .sub             (packet_sub),
    .packet_data     (packet_data)
);

tmds_encoder enc0 (
    .clk(clk_pix), .resetn(resetn),
    .din(b), .ctrl(c0), .de(mode == 3'd1), .mode(mode),
    .data_island(island_data[3:0]), .dout(tmds_ch0)
);

tmds_encoder #(.CHANNEL(1)) enc1 (
    .clk(clk_pix), .resetn(resetn),
    .din(g), .ctrl(c1), .de(mode == 3'd1), .mode(mode),
    .data_island(island_data[7:4]), .dout(tmds_ch1)
);

tmds_encoder #(.CHANNEL(2)) enc2 (
    .clk(clk_pix), .resetn(resetn),
    .din(r), .ctrl(c2), .de(mode == 3'd1), .mode(mode),
    .data_island(island_data[11:8]), .dout(tmds_ch2)
);

wire ser_reset = ~resetn;
wire [2:0] tmds_serial;

OSER10 ser0 (
    .Q  (tmds_serial[0]),
    .D0 (tmds_ch0[0]), .D1 (tmds_ch0[1]), .D2 (tmds_ch0[2]), .D3 (tmds_ch0[3]),
    .D4 (tmds_ch0[4]), .D5 (tmds_ch0[5]), .D6 (tmds_ch0[6]), .D7 (tmds_ch0[7]),
    .D8 (tmds_ch0[8]), .D9 (tmds_ch0[9]),
    .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(ser_reset)
);

OSER10 ser1 (
    .Q  (tmds_serial[1]),
    .D0 (tmds_ch1[0]), .D1 (tmds_ch1[1]), .D2 (tmds_ch1[2]), .D3 (tmds_ch1[3]),
    .D4 (tmds_ch1[4]), .D5 (tmds_ch1[5]), .D6 (tmds_ch1[6]), .D7 (tmds_ch1[7]),
    .D8 (tmds_ch1[8]), .D9 (tmds_ch1[9]),
    .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(ser_reset)
);

OSER10 ser2 (
    .Q  (tmds_serial[2]),
    .D0 (tmds_ch2[0]), .D1 (tmds_ch2[1]), .D2 (tmds_ch2[2]), .D3 (tmds_ch2[3]),
    .D4 (tmds_ch2[4]), .D5 (tmds_ch2[5]), .D6 (tmds_ch2[6]), .D7 (tmds_ch2[7]),
    .D8 (tmds_ch2[8]), .D9 (tmds_ch2[9]),
    .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(ser_reset)
);

// Gowin LVDS output buffers (ELVDS on a 3.3 V bank)
ELVDS_OBUF tmds_bufds [3:0] (
    .I  ({clk_pix,    tmds_serial}),
    .O  ({tmds_clk_p, tmds_d_p}),
    .OB ({tmds_clk_n, tmds_d_n})
);

endmodule
