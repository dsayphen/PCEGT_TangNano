`timescale 1ns/10ps
module tb_megadrive_video;
    reg clk = 0, clk_pixel = 0;
    always #4.94 clk = ~clk;
    always #8.55 clk_pixel = ~clk_pixel;
    reg resetn = 0, ce = 0, hblank = 1, vblank = 1;
    reg [11:0] rgb = 0;
    reg [1:0] zoom = 0, scanline = 0;
    reg overlay = 0;
    reg pattern = 0;
    reg [23:0] overlay_rgb = 24'h123456;
    wire [10:0] osd_x, pixel_x;
    wire [9:0] osd_y, pixel_y;
    wire osd_de, hs, vs, de;
    wire [23:0] out_rgb;
    megadrive_video dut (
        .clk(clk), .resetn(resetn), .ce(ce), .hblank(hblank), .vblank(vblank),         .rgb(rgb), .v30(1'b0), .pal(1'b0),
        .clk_pixel(clk_pixel), .pixel_resetn(resetn), .zoom(zoom), .scanline(scanline),
        .overlay(overlay), .overlay_rgb(overlay_rgb), .osd_x(osd_x), .osd_y(osd_y), .osd_de(osd_de),
        .out_rgb(out_rgb), .hs(hs), .vs(vs), .de(de), .pixel_x(pixel_x), .pixel_y(pixel_y)
    );
    task send_line(input integer width, input integer clocks_per_pixel);
        integer p;
        begin
            @(negedge clk); hblank = 0; vblank = 0;
            for (p = 0; p < width; p = p + 1) begin
                rgb = pattern ? {p[3:0], ~p[3:0], 4'h4} : 12'hf84;
                ce = 1;
                @(negedge clk); ce = 0;
                repeat (clocks_per_pixel - 1) @(negedge clk);
            end
            hblank = 1;
            repeat (3419 - width * clocks_per_pixel) @(negedge clk);
        end
    endtask
    task measure_scanline(input [23:0] dark_rgb);
        integer index;
        reg [23:0] expected;
        begin
            repeat (4*988) @(negedge clk_pixel);
            do @(negedge clk_pixel); while (pixel_x != 0);
            for (index = 0; index < 2*988; index = index + 1) begin
                if (de) begin
                    expected = pixel_y[0] ? dark_rgb : 24'hff8844;
                    if (out_rgb !== expected)
                        $fatal(1, "scanline row%0d x%0d got%h expected%h",
                               pixel_y, pixel_x, out_rgb, expected);
                end
                @(negedge clk_pixel);
            end
        end
    endtask
    task measure_pattern(input integer width);
        integer index, source_index;
        reg [3:0] color, inverse_color;
        reg [23:0] expected;
        begin
            repeat (4*988) @(negedge clk_pixel);
            do @(negedge clk_pixel); while (pixel_x != 0);
            for (index = 0; index < 640; index = index + 1) begin
                source_index = width == 320 ? index / 2 : (index * 2) / 5;
                color = source_index;
                inverse_color = ~color;
                expected = {color,color,inverse_color,inverse_color,8'h44};
                if (!de || out_rgb !== expected)
                    $fatal(1,"nearest-neighbor pixel%0d width%0d got%h expected%h",
                           index,width,out_rgb,expected);
                @(negedge clk_pixel);
            end
        end
    endtask
    integer lit, active, left, right, row;
    task measure(input integer expected_width);
        begin
            wait (dut.x == 0 && dut.read_valid);
            // Skip the first buffered line and collect one complete output line.
            repeat (988) @(negedge clk_pixel);
            do @(negedge clk_pixel); while (pixel_x != 0);
            lit = 0; active = 0; left = -1; right = -1; row = pixel_y;
            do begin
                if (de) active = active + 1;
                if (de && out_rgb == 24'hff8844) begin
                    if (left == -1) left = pixel_x;
                    right = pixel_x;
                    lit = lit + 1;
                end
                @(negedge clk_pixel);
            end while (pixel_x != 0);
            if (active != 640 || lit != expected_width)
                $fatal(1,"video active=%0d lit=%0d expected=%0d row=%0d bounds=%0d..%0d",
                       active,lit,expected_width,row,left,right);
            if (expected_width == 512 && (left != 64 || right != 575))
                $fatal(1,"H32 integer centering %0d..%0d",left,right);
        end
    endtask
    initial begin
        #200; resetn = 1;
        fork
            begin repeat (8) send_line(320,8); end
            measure(640);
        join
        zoom = 0;
        fork
            begin repeat (8) send_line(256,10); end
            begin repeat (4*988) @(negedge clk_pixel); measure(512); end
        join
        zoom = 1;
        fork
            begin repeat (8) send_line(256,10); end
            begin repeat (4*988) @(negedge clk_pixel); measure(640); end
        join
        pattern = 1;
        fork
            begin repeat (8) send_line(256,10); end
            measure_pattern(256);
        join
        fork
            begin repeat (8) send_line(320,8); end
            measure_pattern(320);
        join
        pattern = 0;
        scanline = 1;
        fork
            begin repeat (8) send_line(320,8); end
            measure_scanline(24'hc06633);
        join
        scanline = 2;
        fork
            begin repeat (8) send_line(320,8); end
            measure_scanline(24'h7f4422);
        join
        scanline = 3;
        fork
            begin repeat (8) send_line(320,8); end
            measure_scanline(24'h000000);
        join
        overlay = 1;
        repeat (10) @(negedge clk_pixel);
        if (out_rgb !== overlay_rgb) $fatal(1,"overlay RGB missing");
        resetn = 0;
        repeat (4) @(negedge clk_pixel);
        if (de !== 0 || out_rgb !== 0) $fatal(1,"pixel reset");
        $display("PASS Mega Drive video: H40, H32 integer/stretch, exact pixel repeats, all scanline strengths, overlay, reset");
        $finish;
    end
    initial begin #6000000; $fatal(1,"timeout"); end
endmodule
