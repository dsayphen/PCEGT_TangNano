// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module nes2hdmi (
	input clk,      // nes clock
	input resetn,

    // nes video signals
    input [5:0] color,
    input [8:0] cycle,
    input [8:0] scanline,
    input [15:0] sample,
    input aspect_8x7,       // 1: 8x7 pixel aspect ratio mode
    input [1:0] zoom_mode,
    input [1:0] effect_strength,
    input [6:0] nintendo_color,
    input gameboy_mode,
    input gameboy_color,    // pixels are CGB palette indexes {obj, palette[2:0], color[1:0]}
    input game_active,
    input [5:0] gameboy_pixel,
    input gameboy_hs,
    input gameboy_vs,
    input gameboy_valid,
    input gameboy_pal_wr,         // CGB palette RAM mirror, clk domain
    input [6:0] gameboy_pal_addr, // {obj, byte_index[5:0]}
    input [7:0] gameboy_pal_data,

    // overlay interface
    input overlay,
    output [10:0] overlay_x,
    output [9:0] overlay_y,
    input [15:0] overlay_color, // BGR5, [15] marks an OSD glyph pixel

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// include from tang_primer_25k/config.sv and tang_nano_20k/config.sv

localparam FRAMEWIDTH = 640;
localparam FRAMEHEIGHT = 480;
localparam TOTALWIDTH = 800;
localparam TOTALHEIGHT = 525;
localparam VIDEOID = 1;
localparam VIDEO_REFRESH = 60.0;

// localparam IDIV_SEL_X5 = 3;
// localparam FBDIV_SEL_X5 = 54;
// localparam ODIV_SEL_X5 = 2;
// localparam DUTYDA_SEL_X5 = "1000";
// localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 25200;

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

// Main clock frequency
localparam FREQ=27_000_000;          // at least 10x baudrate
// localparam FREQ=37_800_000;

// UART baudrate: BAUDRATE <= FREQ/10
localparam BAUDRATE=115200;
// localparam BAUDRATE=921600;

// define this to execute one NES cycle per 0.01 second and print the operation done
// `define STEP_TRACING

`ifdef VERILATOR
`define EMBED_GAME
`endif

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

assign overlay_x = cx;
assign overlay_y = cy;


//
// BRAM frame buffer
//
localparam MEM_DEPTH=256*240;
localparam MEM_ABITS=16;

// Even/odd banks expose adjacent pixels without duplicating the framebuffer.
logic [5:0] mem_even [0:128*240-1];
logic [5:0] mem_odd [0:128*240-1];
logic [15:0] mem_portA_addr;
logic [5:0] mem_portA_wdata;
logic mem_portA_we;

wire [14:0] even_read_addr, odd_read_addr;
logic [5:0] even_rdata, odd_rdata;

logic initializing = 1;
logic [7:0] init_y = 0;
logic [7:0] init_x = 0; 
logic [7:0] gb_x = 0;
logic [7:0] gb_y = 0;

// BRAM port A read/write
always_ff @(posedge clk) begin
    if (mem_portA_we && !mem_portA_addr[0])
        mem_even[mem_portA_addr[15:1]] <= mem_portA_wdata;
    if (mem_portA_we && mem_portA_addr[0])
        mem_odd[mem_portA_addr[15:1]] <= mem_portA_wdata;
end

// BRAM port B read
always_ff @(posedge clk_pixel) begin
    even_rdata <= mem_even[even_read_addr];
    odd_rdata <= mem_odd[odd_read_addr];
end

// localparam [0:65] LOGO [0:12] = '{
//     'b11110000110011111111001111001111111110000000000000000000000000000,
//     'b11110000110011111111011111101111111110000000000000000000000000000,
//     'b11111000110011100000011100100001110000000000000000000000000000000,
//     'b11111000110011100000011100000001110000011111000111111100001111110,
//     'b11011100110011111110001110000001110000110011100111001110011100111,
//     'b11001110110011111110000111000001110000000011100110001110011000111,
//     'b11001111110011000000000011100001110000111111100110001110111000111,
//     'b11000111110011000000110011100001110001111111100110001110111000111,
//     'b11000011110011111110111111100001100001110011100110001110011001111,
//     'b11000011110011111110011111000001100000111111100110001110001111111,
//     'b00000000000000000000000000000000000000000000000000000000000000111,
//     'b00000000000000000000000000000000000000000000000000000000011001110,
//     'b00000000000000000000000000000000000000000000000000000000011111100
// };

// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
always @(posedge clk) begin
    if (~resetn) begin
        initializing <= 1;
        init_y <= 0;
        init_x <= 0;
        gb_x <= 0;
        gb_y <= 0;
        mem_portA_we <= 0;
    end else if (initializing) begin    // setup background at initialization
        if (init_x == 8'd255) begin
            init_x <= 0;
            if (init_y == 8'd239)
                initializing <= 0;
            else
                init_y <= init_y + 1'b1;
        end else
            init_x <= init_x + 1'b1;
        mem_portA_we <= 1;
        mem_portA_addr <= {init_y, init_x};
        mem_portA_wdata <= 0;
        // if (init_x >= 96 && init_x <= 160 && init_y >= 212 && init_y <= 224 && LOGO[init_y - 212][init_x - 96])
        //     mem_portA_wdata <= 4;       // blue logo
        // else
        //     mem_portA_wdata <= 13;      // black
    end else if (gameboy_mode) begin
        mem_portA_we <= 1'b0;
        if (gameboy_vs) begin
            gb_x <= 0;
            gb_y <= 0;
        end else if (gameboy_hs) begin
            gb_x <= 0;
        end else if (gameboy_valid && gb_x < 8'd160 && gb_y < 8'd144) begin
            mem_portA_addr <= {gb_y, gb_x};
            mem_portA_wdata <= gameboy_pixel;
            mem_portA_we <= 1'b1;
            if (gb_x == 8'd159) begin
                gb_x <= 0;
                if (gb_y == 8'd143)
                    gb_y <= 0;
                else
                    gb_y <= gb_y + 1'b1;
            end else
                gb_x <= gb_x + 1'b1;
        end
    end else begin
        gb_x <= 0;
        gb_y <= 0;
        r_scanline <= scanline;
        r_cycle <= cycle;
        mem_portA_we <= 1'b0;
        if ((r_scanline != scanline || r_cycle != cycle) && scanline < 9'd240 && ~cycle[8]) begin
            mem_portA_addr <= {scanline[7:0], cycle[7:0]};
            mem_portA_wdata <= color;
            mem_portA_we <= 1'b1;
        end
    end
end

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sample;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sample;
    audio_sample_word[1] <= audio_sample_word0[1];
end

//
// NES: integer x2, full-width nearest, or full-width horizontal bilinear.
// GB: integer x3, or x4 horizontally / x3 vertically (Wide Stretch).
//
reg [13:0] settings_meta = 0, settings_pixel = 0;
always @(posedge clk_pixel) begin
    settings_meta <= {game_active, gameboy_color, gameboy_mode,
                      nintendo_color, effect_strength, zoom_mode};
    settings_pixel <= settings_meta;
end
wire [1:0] zoom = settings_pixel[1:0];
wire [1:0] strength = settings_pixel[3:2];
wire [2:0] palette_id = settings_pixel[6:4];
wire [1:0] gbc_correction = settings_pixel[8:7];
wire [1:0] dmg_palette = settings_pixel[10:9];
wire gb_mode = settings_pixel[11];
wire cgb_mode = settings_pixel[12];
wire playing = settings_pixel[13];

// Fetch four pixels ahead: framebuffer, palette, interpolation, composition.
wire [10:0] render_x = cx < 11'd796 ? cx + 11'd4 : cx - 11'd796;
wire [9:0] render_y = cx < 11'd796 ? cy : (cy == 10'd524 ? 10'd0 : cy + 1'b1);
wire nes_window = render_y < 480 &&
                  (zoom != 0 ? render_x < 640 : render_x >= 64 && render_x < 576);
wire gb_window = render_y >= 24 && render_y < 456 &&
                 (zoom != 0 ? render_x < 640 : render_x >= 80 && render_x < 560);
wire [10:0] nes_display_x = render_x - 11'd64;
wire [10:0] nes_scaled_x = (render_x * 11'd2) / 11'd5;
wire [10:0] gb_local_x = zoom != 0 ? render_x : render_x - 11'd80;
wire [9:0] gb_local_y = render_y - 10'd24;
wire [10:0] gb_source_x = zoom != 0 ? gb_local_x >> 2 : gb_local_x / 11'd3;
wire [9:0] gb_source_y = gb_local_y / 10'd3;
wire [7:0] source_x = gb_mode ?
    gb_source_x[7:0] :
    (zoom != 0 ? nes_scaled_x[7:0] : nes_display_x[8:1]);
wire [7:0] source_y = gb_mode ? gb_source_y[7:0] : render_y[8:1];
wire in_window = playing && (gb_mode ? gb_window : nes_window);
wire [7:0] next_x = source_x == 255 ? 8'd255 : source_x + 1'b1;
assign even_read_addr = in_window ?
    {source_y, (source_x[0] ? next_x[7:1] : source_x[7:1])} : 15'd0;
assign odd_read_addr = in_window ? {source_y, source_x[7:1]} : 15'd0;
wire grid_gap = (zoom != 0 ? gb_local_x[1:0] == 0 : gb_local_x % 11'd3 == 0) ||
                gb_local_y % 10'd3 == 0;
wire [2:0] fraction = (render_x * 11'd2) % 11'd5;
reg odd_read, window_read, gb_read, cgb_read;
reg [1:0] correction_read, dmg_palette_read;
reg [2:0] palette_read, fraction_read;
reg [1:0] strength_read;
reg effect_read;
always @(posedge clk_pixel) begin
    odd_read <= source_x[0];
    window_read <= in_window;
    gb_read <= gb_mode;
    cgb_read <= cgb_mode;
    correction_read <= gbc_correction;
    dmg_palette_read <= dmg_palette;
    palette_read <= palette_id;
    fraction_read <= !gb_mode && zoom == 2 && source_x != 255 ? fraction : 3'd0;
    strength_read <= strength;
    effect_read <= gb_mode ? grid_gap : render_y[0];
end
wire [5:0] index_first = odd_read ? odd_rdata : even_rdata;
reg [23:0] palette_rom [0:511];
initial $readmemh("rtl/nestang/palettes/nes.hex", palette_rom);
reg [23:0] rgb;     // actual RGB output

// Mirror of the 2x64-byte CGB palette RAM. Colours are looked up when the
// frame is displayed, so mid-frame palette rewrites are not reproduced.
reg [7:0] gbc_pal_lo [0:63];
reg [7:0] gbc_pal_hi [0:63];
always_ff @(posedge clk) begin
    if (gameboy_pal_wr && !gameboy_pal_addr[0])
        gbc_pal_lo[{gameboy_pal_addr[6], gameboy_pal_addr[5:1]}] <= gameboy_pal_data;
    if (gameboy_pal_wr && gameboy_pal_addr[0])
        gbc_pal_hi[{gameboy_pal_addr[6], gameboy_pal_addr[5:1]}] <= gameboy_pal_data;
end
wire [7:0] gbc_lo = gbc_pal_lo[index_first];
wire [7:0] gbc_hi = gbc_pal_hi[index_first];
wire [4:0] gbc_r = gbc_lo[4:0];
wire [4:0] gbc_g = {gbc_hi[1:0], gbc_lo[7:5]};
wire [4:0] gbc_b = gbc_hi[6:2];
wire [23:0] gbc_rgb = {gbc_r, gbc_r[4:2], gbc_g, gbc_g[4:2], gbc_b, gbc_b[4:2]};

// Gambatte's integer Fast correction, retaining the reference's 5-bit rounding.
function automatic [23:0] gbc_fast(input [4:0] r, g, b);
    reg [8:0] red, blue;
    reg [6:0] green;
    begin
        red = r * 9'd13 + g * 9'd2 + b;
        green = g * 7'd3 + b;
        blue = r * 9'd3 + g * 9'd2 + b * 9'd11;
        gbc_fast = {red[8:4], red[8:6], green[6:2], green[6:4], blue[8:4], blue[8:6]};
    end
endfunction

// Revisit all 64 palette entries continuously, so byte writes and live mode
// changes never need to stall the core. A sweep takes 384 core clocks.
reg [5:0] correction_index = 0;
reg [2:0] correction_phase = 0;
reg [14:0] correction_color;
reg [7:0] correction_r, correction_g;
wire [7:0] correction_value;
wire [1:0] correction_component = correction_phase == 2 ? 2'd1 :
                                  correction_phase == 3 ? 2'd2 : 2'd0;
reg [23:0] corrected_palette [0:63];
gbc_color_correct u_correct (
    .clk(clk), .color(correction_color), .component(correction_component),
    .corrected(correction_value)
);
always @(posedge clk) begin
    if (correction_phase == 0)
        correction_color <= {gbc_pal_hi[correction_index][6:0], gbc_pal_lo[correction_index]};
    if (correction_phase == 3) correction_r <= correction_value;
    if (correction_phase == 4) correction_g <= correction_value;
    if (correction_phase == 5) begin
        corrected_palette[correction_index] <= {correction_r, correction_g, correction_value};
        correction_phase <= 0;
        correction_index <= correction_index + 1'b1;
    end else
        correction_phase <= correction_phase + 1'b1;
end

// Hardware-mimicking palettes from Gambatte's GB DMG/Pocket/Light set.
function automatic [23:0] gb_palette(input [1:0] mode, shade);
    case ({mode, shade})
        4'h0: gb_palette = 24'hf8fcf8;
        4'h1: gb_palette = 24'ha8b0a8;
        4'h2: gb_palette = 24'h506050;
        4'h3: gb_palette = 24'h000000;
        4'h4: gb_palette = 24'h578200;
        4'h5: gb_palette = 24'h317400;
        4'h6: gb_palette = 24'h005121;
        4'h7: gb_palette = 24'h00420c;
        4'h8: gb_palette = 24'ha7b19a;
        4'h9: gb_palette = 24'h86927c;
        4'ha: gb_palette = 24'h535f49;
        4'hb: gb_palette = 24'h2a3325;
        4'hc: gb_palette = 24'h01cbdf;
        4'hd: gb_palette = 24'h01b6d5;
        4'he: gb_palette = 24'h269bad;
        default: gb_palette = 24'h00778d;
    endcase
endfunction

reg [23:0] nes_even_rgb, nes_odd_rgb, gb_rgb;
reg palette_odd, palette_window, palette_gb, palette_effect;
reg [1:0] palette_strength;
reg [2:0] palette_fraction;
always @(posedge clk_pixel) begin
    nes_even_rgb <= palette_rom[{palette_read, even_rdata}];
    nes_odd_rgb <= palette_rom[{palette_read, odd_rdata}];
    gb_rgb <= cgb_read ?
        (correction_read == 1 ? corrected_palette[index_first] :
         correction_read == 2 ? gbc_fast(gbc_r, gbc_g, gbc_b) : gbc_rgb) :
        gb_palette(dmg_palette_read, index_first[1:0]);
    palette_odd <= odd_read;
    palette_window <= window_read;
    palette_gb <= gb_read;
    palette_effect <= effect_read;
    palette_strength <= strength_read;
    palette_fraction <= fraction_read;
end
wire [23:0] rgb_first = palette_odd ? nes_odd_rgb : nes_even_rgb;
wire [23:0] rgb_next = palette_odd ? nes_even_rgb : nes_odd_rgb;
function automatic [7:0] blend(input [7:0] a, b, input [2:0] f);
    reg [7:0] weight;
    reg [16:0] sum;
    begin
        case (f)
            1: weight = 51;
            2: weight = 102;
            3: weight = 154;
            4: weight = 205;
            default: weight = 0;
        endcase
        sum = a * (9'd256 - weight) + b * weight + 17'd128;
        blend = sum[15:8];
    end
endfunction
reg [23:0] interpolated;
reg image_window, image_gb, image_effect;
reg [1:0] image_strength;
always @(posedge clk_pixel) begin
    interpolated <= palette_gb ? gb_rgb :
        {blend(rgb_first[23:16], rgb_next[23:16], palette_fraction),
         blend(rgb_first[15:8], rgb_next[15:8], palette_fraction),
         blend(rgb_first[7:0], rgb_next[7:0], palette_fraction)};
    image_window <= palette_window;
    image_gb <= palette_gb;
    image_effect <= palette_effect;
    image_strength <= palette_strength;
end

function automatic [7:0] pixel_effect(input [7:0] v, input gb, edge_on,
                                     input [1:0] amount);
    reg [7:0] ink;
    reg [9:0] gap_lift;
    begin
        // White grid gaps leave white backgrounds untouched (dot-matrix style).
        ink = gb ? 8'd255 - v : v;
        if (edge_on) begin
            if (gb) begin
                gap_lift = (ink * amount + 10'd5) / 10'd10;
                ink = ink - gap_lift[7:0];
            end else begin
                case (amount)
                    1: ink = ink - (ink >> 2);
                    2: ink = ink >> 1;
                    3: ink = 0;
                    default: ink = ink;
                endcase
            end
        end
        pixel_effect = gb ? 8'd255 - ink : ink;
    end
endfunction

always_ff @(posedge clk_pixel) begin
    reg [23:0] rgb_game;
    rgb_game = !image_window ? 24'd0 :
        {pixel_effect(interpolated[23:16], image_gb, image_effect, image_strength),
         pixel_effect(interpolated[15:8], image_gb, image_effect, image_strength),
         pixel_effect(interpolated[7:0], image_gb, image_effect, image_strength)};

    // overlay_color[15] marks an OSD glyph pixel; elsewhere the game is dimmed.
    if (overlay)
        rgb <= overlay_color[15] ?
               {overlay_color[4:0], 3'b0, overlay_color[9:5], 3'b0,
                overlay_color[14:10], 3'b0} :
               {1'b0, rgb_game[23:17], 1'b0, rgb_game[15:9],
                1'b0, rgb_game[7:1]};
    else
        rgb <= rgb_game;
end

// HDMI output.
logic[2:0] tmds;

hdmi #( .VIDEO_ID_CODE(VIDEOID),
        .BIT_WIDTH(11),
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( ~resetn ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

endmodule
