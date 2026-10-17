`timescale 1ns / 1ps
module tb_snes_video;
reg clk = 0, clk_pixel = 0;
always #23 clk = ~clk;
always #20 clk_pixel = ~clk_pixel;
reg resetn = 0;
reg [1:0] zoom = 0;
reg overlay = 0, overlay_text = 0;
reg dotclk = 0, hblank = 1, vblank = 1;
reg [8:0] source_x = 0, source_y = 0;
reg [14:0] source_color = 0;
wire [10:0] osd_x;
wire [9:0] osd_y;
wire osd_de;
snes_video_640 dut (
    .clk(clk), .resetn(resetn), .dotclk(dotclk), .hblank(hblank), .vblank(vblank),
    .rgb5(source_color), .xs(source_x), .ys(source_y), .zoom(zoom), .scanline(2'd0),
    .pause_pending(1'b0), .pause_ready(1'b0), .pause_buffer_write(1'b0),
    .pause_buffer_address(10'd0), .pause_buffer_bank(3'd0), .pause_buffer_data(15'd0),
    .overlay(overlay), .overlay_text(overlay_text), .overlay_color(24'habcdef),
    .overlay_x(osd_x), .overlay_y(osd_y), .overlay_de(osd_de),
    .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0), .snes_refresh(1'b0),
    .clk_pixel(clk_pixel), .clk_5x_pixel(clk_pixel), .locked(1'b1)
);
integer pixel_index, mode, active_pixels, expected_x, expected_y, line_index;
integer weight_x, weight_y, next_x, next_y, expected_red, expected_green;
integer upper_blue, lower_blue, expected_blue, next_source_x, next_source_y;
reg expected_active;
reg [23:0] expected_rgb;
task write_pixel(input [7:0] row_index);
    source_y = 0;
    repeat (2) @(negedge clk);
    repeat (row_index) begin
        source_y = source_y + 1'b1;
        @(negedge clk);
    end
    @(negedge clk);
    source_x = {8'd7, 1'b1};
    source_y = {1'b0, row_index};
    source_color = {5'(((row_index ^ 7) & 1) * 31), 5'(row_index % 24), 5'd7};
    hblank = 0;
    vblank = 0;
    dotclk = 1;
    repeat (3) @(negedge clk);
    dotclk = 0;
    hblank = 1;
    vblank = 1;
    repeat (3) @(negedge clk);
endtask
initial begin
    #1;
    for (pixel_index = 0; pixel_index < 1024; pixel_index = pixel_index + 1) begin
        dut.lines_ee[pixel_index] = {5'(((pixel_index >> 7) & 1)*31), 5'((pixel_index >> 7)*3), 5'(pixel_index*2)};
        dut.lines_eo[pixel_index] = {5'((1-((pixel_index >> 7) & 1))*31), 5'((pixel_index >> 7)*3), 5'(pixel_index*2+1)};
        dut.lines_oe[pixel_index] = {5'((1-((pixel_index >> 7) & 1))*31), 5'((pixel_index >> 7)*3+1), 5'(pixel_index*2)};
        dut.lines_oo[pixel_index] = {5'(((pixel_index >> 7) & 1)*31), 5'((pixel_index >> 7)*3+1), 5'(pixel_index*2+1)};
        dut.lines_te[pixel_index] = {5'(((pixel_index >> 7) & 1)*31), 5'((pixel_index >> 7)*3+2), 5'(pixel_index*2)};
        dut.lines_to[pixel_index] = {5'((1-((pixel_index >> 7) & 1))*31), 5'((pixel_index >> 7)*3+2), 5'(pixel_index*2+1)};
    end
    repeat (5) @(negedge clk_pixel);
    resetn = 1;
    dut.lines_to[643] = 0;
    write_pixel(17);
    if (dut.lines_to[643] !== source_color)
        $fatal(1, "Odd bank line-buffer write failed");
    dut.lines_to[643] = 0;
    write_pixel(41);
    if (dut.lines_to[643] !== source_color)
        $fatal(1, "24-line wrap write failed");
    for (mode = 0; mode < 3; mode = mode + 1) begin
        zoom = mode;
        repeat (4) @(negedge clk_pixel);
        wait(dut.cy == 524 && dut.cx == 799);
        @(negedge clk_pixel);
        active_pixels = 0;
        repeat (800*525) begin
            expected_active = mode ? dut.cx < 640 && dut.cy < 480 :
                dut.cx >= 64 && dut.cx < 576 && dut.cy >= 16 && dut.cy < 464;
            if (dut.active_pixel !== expected_active)
                $fatal(1, "active window mismatch mode=%d x=%d y=%d", mode, dut.cx, dut.cy);
            if (expected_active) begin
                expected_x = mode ? dut.cx * 2 / 5 : (dut.cx - 64) / 2;
                expected_y = mode ? dut.cy * 7 / 15 : (dut.cy - 16) / 2;
                line_index = expected_y % 24;
                expected_red = expected_x % 32;
                expected_green = line_index;
                expected_blue = ((expected_x ^ expected_y) & 1) * 31;
                if (mode == 2) begin
                    weight_x = ((dut.cx * 2 % 5) * 4 + 2) / 5;
                    weight_y = (dut.cy * 7 % 15) / 4;
                    next_x = expected_x == 255 ? expected_red : (expected_x + 1) % 32;
                    next_y = expected_y == 223 ? line_index : (line_index + 1) % 24;
                    expected_red = (expected_red * (4-weight_x) + next_x * weight_x) / 4;
                    expected_green = (line_index * (4-weight_y) + next_y * weight_y) / 4;
                    next_source_x = expected_x == 255 ? expected_x : expected_x + 1;
                    next_source_y = expected_y == 223 ? expected_y : expected_y + 1;
                    upper_blue = (expected_blue * (4-weight_x) +
                        (((next_source_x ^ expected_y) & 1) * 31) * weight_x) / 4;
                    lower_blue = ((((expected_x ^ next_source_y) & 1) * 31) * (4-weight_x) +
                        (((next_source_x ^ next_source_y) & 1) * 31) * weight_x) / 4;
                    expected_blue = (upper_blue * (4-weight_y) + lower_blue * weight_y) / 4;
                end
                expected_rgb = {5'(expected_red), 3'd0, 5'(expected_green), 3'd0, 5'(expected_blue), 3'd0};
                active_pixels = active_pixels + 1;
            end else begin
                expected_rgb = 0;
            end
            if (dut.rgb !== expected_rgb)
                $fatal(1, "pixel mismatch mode=%d x=%d y=%d got=%h expected=%h", mode, dut.cx, dut.cy, dut.rgb, expected_rgb);
            @(negedge clk_pixel);
        end
        if (active_pixels != (mode ? 640*480 : 512*448))
            $fatal(1, "incorrect active pixel count");
    end
    overlay = 1;
    overlay_text = 1;
    repeat (5) @(negedge clk_pixel);
    if (dut.rgb !== 24'habcdef)
        $fatal(1, "OSD glyph color mismatch");
    $display("tb_snes_video PASSED: 640x480 timing, integer/stretch/bilinear pixels, edge clamp and OSD");
    $finish;
end
initial begin
    #150000000;
    $fatal(1, "Video test timeout");
end
endmodule

module tb_snes_video_stream #(
    parameter MODE = 1
);
reg clk = 0, clk_pixel = 0;
always #23.148 clk = ~clk;
always #19.841 clk_pixel = ~clk_pixel;
reg resetn = 0;
reg [10:0] source_tick = 0;
reg [8:0] source_row = 0;
reg source_field = 0;
wire pause_source;
always @(posedge clk) begin
    if (!resetn) begin
        source_tick <= 0;
        source_row <= 0;
        source_field <= 0;
    end else if (!pause_source) begin
        if (source_tick == 1363) begin
            source_tick <= 0;
            source_row <= source_row == 261 ? 0 : source_row + 1'b1;
            if (source_row == 261)
                source_field <= ~source_field;
        end else
            source_tick <= source_tick + 1'b1;
    end
end
wire [14:0] source_color = {source_row[7:0], 7'b1010101};
wire [7:0] ppu_row = source_row < 224 ? source_row[7:0] : 8'd224;
snes_video_640 dut (
    .clk(clk), .resetn(resetn), .dotclk(source_tick[1]),
    .hblank(source_tick >= 1024), .vblank(source_row >= 224), .rgb5(source_color),
    .xs({source_tick[9:2], 1'b0}), .ys({source_field, ppu_row}), .zoom(2'(MODE)), .scanline(2'd0),
    .pause_pending(1'b0), .pause_ready(1'b0), .pause_buffer_write(1'b0),
    .pause_buffer_address(10'd0), .pause_buffer_bank(3'd0), .pause_buffer_data(15'd0),
    .overlay(1'b0), .overlay_text(1'b0), .overlay_color(24'd0),
    .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0),
    .snes_refresh(source_tick >= 1100 && source_tick < 1140),
    .clk_pixel(clk_pixel), .clk_5x_pixel(clk_pixel), .locked(1'b1),
    .pause_snes_for_frame_sync(pause_source)
);
integer output_pixel, row_index, row_next, weight, channel_index, first, second, expected;
integer frame_index;
reg [14:0] first_color, second_color;
initial begin
    repeat (8) @(negedge clk);
    resetn = 1;
    wait(dut.sync_done);
    for (frame_index = 0; frame_index < 2; frame_index = frame_index + 1) begin
    wait(dut.cy == 1 && dut.cx == 0);
    @(negedge clk_pixel);
    for (output_pixel = 0; output_pixel < 800*479; output_pixel = output_pixel + 1) begin
        if (dut.cx < 640 && dut.cy < 480) begin
            row_index = dut.cy * 7 / 15;
            row_next = row_index == 223 ? row_index : row_index + 1;
            weight = MODE == 2 ? (dut.cy * 7 % 15) / 4 : 0;
            first_color = {8'(row_index), 7'b1010101};
            second_color = {8'(row_next), 7'b1010101};
            for (channel_index = 0; channel_index < 3; channel_index = channel_index + 1) begin
                first = (first_color >> (channel_index * 5)) & 31;
                second = (second_color >> (channel_index * 5)) & 31;
                expected = (first * (4-weight) + second * weight) / 4;
                if (dut.pixel_data[channel_index*5 +: 5] !== 5'(expected))
                    $fatal(1, "Live line overwritten mode=%0d output=%0d/%0d source=%0d producer=%0d data=%h expected_channel=%0d",
                        MODE, dut.cx, dut.cy, row_index, source_row, dut.pixel_data, expected);
            end
        end
        @(negedge clk_pixel);
    end
    end
    $display("tb_snes_video_stream PASSED: mode=%0d two PPU fields with vertical blanking", MODE);
    $finish;
end
initial begin
    #60000000;
    $fatal(1, "Live video test timeout");
end
endmodule

module tb_snes_video_stream_bilinear;
tb_snes_video_stream #(.MODE(2)) test_bilinear ();
endmodule

module hdmi #(
    parameter VIDEO_ID_CODE=1, BIT_WIDTH=11, BIT_HEIGHT=10, DVI_OUTPUT=0,
    parameter VIDEO_REFRESH_RATE=60.0, IT_CONTENT=1, AUDIO_RATE=32000, AUDIO_BIT_WIDTH=16
) (
    input clk_pixel_x5, clk_pixel, clk_audio, reset,
    input [23:0] rgb,
    input [15:0] audio_sample_word [1:0],
    output [2:0] tmds,
    output tmds_clock,
    output reg [10:0] cx = 0,
    output reg [9:0] cy = 0,
    output [10:0] frame_width,
    output [9:0] frame_height
);
assign frame_width = 800;
assign frame_height = 525;
assign tmds = rgb[2:0];
assign tmds_clock = clk_pixel;
initial if (VIDEO_ID_CODE != 1) $fatal(1, "Output is not VGA");
always @(posedge clk_pixel) begin
    if (reset) begin
        cx <= 0;
        cy <= 0;
    end else if (cx == 799) begin
        cx <= 0;
        cy <= cy == 524 ? 0 : cy + 1'b1;
    end else cx <= cx + 1'b1;
end
endmodule

module ELVDS_OBUF(input I, output O, output OB);
assign O = I;
assign OB = ~I;
endmodule