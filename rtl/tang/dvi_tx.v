//
// DVI transmitter for the Tang Nano 20K.
//
// Three TMDS channels plus the TMDS clock, serialised with the Gowin OSER10
// primitives and driven off-chip through ELVDS_OBUF differential buffers.
// This is the same output structure the Sipeed Tang Nano 20K HDMI examples and
// NESTang use (GPLv3), the only difference being that the TMDS encoders here
// are the plain DVI ones from tmds_encoder.v (no HDMI data islands, therefore
// no HDMI audio - audio is routed to the on-board I2S amplifier instead).
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

    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

wire [9:0] tmds_ch0;   // blue  + hsync/vsync
wire [9:0] tmds_ch1;   // green
wire [9:0] tmds_ch2;   // red

// negative sync polarity: the line is high when idle, low during the pulse
wire c0 = ~hsync;
wire c1 = ~vsync;

tmds_encoder enc0 (
    .clk(clk_pix), .resetn(resetn),
    .din(b), .ctrl({c1, c0}), .de(de), .dout(tmds_ch0)
);

tmds_encoder enc1 (
    .clk(clk_pix), .resetn(resetn),
    .din(g), .ctrl(2'b00), .de(de), .dout(tmds_ch1)
);

tmds_encoder enc2 (
    .clk(clk_pix), .resetn(resetn),
    .din(r), .ctrl(2'b00), .de(de), .dout(tmds_ch2)
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
