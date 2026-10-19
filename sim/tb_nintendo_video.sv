`timescale 1ns/1ps
module tb_nintendo_video;
    reg clk = 0, pixel_clk = 0;
    always #5 clk = ~clk;
    always #10 pixel_clk = ~pixel_clk;
    reg [10:0] raster_x = 0;
    reg [9:0] raster_y = 0;
    reg gb = 0, cgb = 0, active = 1, overlay = 0;
    reg [1:0] zoom = 0, strength = 0;
    reg [6:0] colors = 0;
    reg [15:0] osd_color = 0;
    reg pal_wr = 0;
    reg [6:0] pal_addr = 0;
    reg [7:0] pal_data = 0;
    reg [15:0] capture_addr = 0;
    reg [5:0] capture_data = 0;
    integer x, y, mode, bank, i, expected_x, expected_y, step;
    integer actual_channel, expected_channel;
    reg [23:0] expected_rgb;
    reg [23:0] dmg_colors [0:15];
    nes2hdmi dut (
        .clk(clk), .resetn(1'b1), .color(6'd0), .cycle(9'd0), .scanline(9'd0),
        .sample(16'd0), .aspect_8x7(1'b0), .zoom_mode(zoom),
        .effect_strength(strength), .nintendo_color(colors),
        .gameboy_mode(gb), .gameboy_color(cgb), .game_active(active),
        .gameboy_pixel(6'd0), .gameboy_hs(1'b0), .gameboy_vs(1'b0),
        .gameboy_valid(1'b0), .gameboy_pal_wr(pal_wr),
        .gameboy_pal_addr(pal_addr), .gameboy_pal_data(pal_data),
        .overlay(overlay), .overlay_color(osd_color),
        .clk_pixel(pixel_clk), .clk_5x_pixel(clk)
    );
    task check(input condition, input [255:0] message);
        if (condition !== 1'b1) begin
            $display("FAILED %0s gb=%0d zoom=%0d x=%0d y=%0d actual=%h expected=%h",
                     message, gb, zoom, x, y, dut.rgb, expected_rgb);
            $fatal(1);
        end
    endtask
    task settle;
        repeat (9) @(negedge pixel_clk);
    endtask
    // Present a framebuffer fetch coordinate, including look-ahead at line wrap.
    task position(input integer px, py);
        begin
            raster_x = px < 4 ? px + 796 : px - 4;
            raster_y = px < 4 ? (py == 0 ? 524 : py - 1) : py;
            #1;
        end
    endtask
    task palette_byte(input [6:0] address, input [7:0] value);
        begin
            @(negedge clk);
            pal_wr = 1; pal_addr = address; pal_data = value;
            @(negedge clk);
            pal_wr = 0;
        end
    endtask
    function automatic [23:0] mix_rgb(input [23:0] a, b, input integer f);
        integer channel, value;
        begin
            for (channel = 0; channel < 3; channel++) begin
                value = (((a >> (channel*8)) & 255) * (5-f) +
                         ((b >> (channel*8)) & 255) * f + 2) / 5;
                mix_rgb[channel*8 +: 8] = value;
            end
        end
    endfunction
    initial begin
        dmg_colors[0] = 24'hf8fcf8; dmg_colors[1] = 24'ha8b0a8;
        dmg_colors[2] = 24'h506050; dmg_colors[3] = 0;
        dmg_colors[4] = 24'h578200; dmg_colors[5] = 24'h317400;
        dmg_colors[6] = 24'h005121; dmg_colors[7] = 24'h00420c;
        dmg_colors[8] = 24'ha7b19a; dmg_colors[9] = 24'h86927c;
        dmg_colors[10] = 24'h535f49; dmg_colors[11] = 24'h2a3325;
        dmg_colors[12] = 24'h01cbdf; dmg_colors[13] = 24'h01b6d5;
        dmg_colors[14] = 24'h269bad; dmg_colors[15] = 24'h00778d;
        force dut.cx = raster_x;
        force dut.cy = raster_y;
        force dut.initializing = 0;
        force dut.mem_portA_addr = capture_addr;
        force dut.mem_portA_wdata = capture_data;
        force dut.mem_portA_we = 1;
        capture_addr = 16'h143e; capture_data = 6'h35;
        @(negedge clk);
        capture_addr = 16'h143f; capture_data = 6'h2a;
        @(negedge clk);
        check(dut.mem_even[15'h0a1f] == 6'h35 &&
              dut.mem_odd[15'h0a1f] == 6'h2a, "framebuffer even/odd writes");
        force dut.mem_portA_we = 0;
        for (y = 0; y < 240; y++)
            for (x = 0; x < 128; x++) begin
                dut.mem_even[y*128+x] = (x*2+y) % 64;
                dut.mem_odd[y*128+x] = (x*2+1+y) % 64;
            end
        for (mode = 0; mode < 3; mode++) begin
            zoom = mode;
            settle();
            // Exhaustive active-raster geometry and address bounds.
            for (y = 0; y < 480; y++)
                for (x = 0; x < 640; x++) begin
                    position(x,y);
                    check(dut.in_window === (mode != 0 || (x >= 64 && x < 576)), "NES window");
                    if (dut.in_window) begin
                        expected_x = mode != 0 ? x*2/5 : (x-64)/2;
                        check(dut.source_x == expected_x && dut.source_y == y/2, "NES geometry");
                        check(dut.even_read_addr < 30720 && dut.odd_read_addr < 30720, "NES RAM bounds");
                    end
                end
            // Full scanline, across even/odd pairs, borders and right-edge clamp.
            y = 101;
            for (x = 0; x < 640; x++) begin
                position(x,y);
                settle();
                expected_rgb = 0;
                if (mode != 0 || (x >= 64 && x < 576)) begin
                    expected_x = mode != 0 ? x*2/5 : (x-64)/2;
                    expected_rgb = dut.palette_rom[(expected_x+y/2)%64];
                    if (mode == 2 && expected_x < 255)
                        expected_rgb = mix_rgb(expected_rgb,
                            dut.palette_rom[(expected_x+1+y/2)%64], (x*2)%5);
                end
                // Q8 bilinear weights differ by at most one output level.
                for (i = 0; i < 3; i++) begin
                    actual_channel = (dut.rgb >> (i*8)) & 255;
                    expected_channel = (expected_rgb >> (i*8)) & 255;
                    check(actual_channel >= expected_channel - 1 &&
                          actual_channel <= expected_channel + 1, "NES RGB/bilinear");
                end
            end
        end
        zoom = 0;
        for (bank = 0; bank < 8; bank++) begin
            colors = bank;
            position(100,100); settle();
            check(dut.rgb === dut.palette_rom[bank*64+(18+50)%64], "NES palette selection");
        end
        colors = 0;
        for (mode = 0; mode < 3; mode++) begin
            zoom = mode; strength = 0;
            raster_x = 700; raster_y = 100; settle();
            for (step = 0; step < 900; step++) begin
                @(negedge pixel_clk);
                x = (700+step)%800;
                y = 100+(700+step)/800;
                raster_x = x; raster_y = y;
                @(posedge pixel_clk);
                if (y == 101 && x < 640) begin
                    expected_rgb = 0;
                    if (mode != 0 || (x >= 64 && x < 576)) begin
                        expected_x = mode != 0 ? x*2/5 : (x-64)/2;
                        expected_rgb = dut.palette_rom[(expected_x+y/2)%64];
                        if (mode == 2 && expected_x < 255)
                            expected_rgb = mix_rgb(expected_rgb,
                                dut.palette_rom[(expected_x+1+y/2)%64], (x*2)%5);
                    end
                    for (i = 0; i < 3; i++) begin
                        actual_channel = (dut.rgb >> (i*8)) & 255;
                        expected_channel = (expected_rgb >> (i*8)) & 255;
                        check(actual_channel >= expected_channel - 1 &&
                              actual_channel <= expected_channel + 1, "NES streaming alignment");
                    end
                end
            end
        end
        zoom = 0;
        position(100,101);
        for (i = 0; i < 4; i++) begin
            strength = i; settle();
            expected_rgb = dut.palette_rom[(18+50)%64];
            for (bank = 0; bank < 3; bank++) begin
                expected_x = (expected_rgb >> (bank*8)) & 255;
                case (i)
                    1: expected_x = expected_x - (expected_x >> 2);
                    2: expected_x = expected_x >> 1;
                    3: expected_x = 0;
                endcase
                check(dut.rgb[bank*8 +: 8] == expected_x, "NES scanline strength");
            end
        end
        gb = 1; strength = 0;
        for (mode = 0; mode < 3; mode++) begin
            zoom = mode; settle();
            for (y = 0; y < 480; y++)
                for (x = 0; x < 640; x++) begin
                    position(x,y);
                    check(dut.in_window ===
                        (y >= 24 && y < 456 && (mode != 0 || (x >= 80 && x < 560))), "GB window");
                    if (dut.in_window) begin
                        expected_x = mode != 0 ? x/4 : (x-80)/3;
                        check(dut.source_x == expected_x && dut.source_y == (y-24)/3, "GB geometry");
                    end
                end
            // Grid gaps follow source pixels in both x3 and x4 modes.
            strength = 3;
            for (y = 24; y < 33; y++)
                for (x = 80; x < 104; x++) begin
                    position(x,y); settle();
                    expected_x = mode != 0 ? x%4 : (x-80)%3;
                    expected_y = (y-24)%3;
                    expected_rgb = dmg_colors[(dut.source_x + dut.source_y)%4];
                    for (bank = 0; bank < 3; bank++) begin
                        actual_channel = (expected_rgb >> (bank*8)) & 255;
                        if (!expected_x || !expected_y)
                            actual_channel += ((255-actual_channel)*3+5)/10;
                        check(dut.rgb[bank*8 +: 8] == actual_channel, "GB 30% grid gaps");
                    end
                end
            strength = 0;
        end
        zoom = 1;
        position(4,28); // source (1,1), shade 2, on a vertical grid gap
        for (i = 0; i < 4; i++) begin
            strength = i; settle();
            expected_rgb = 24'h506050;
            for (bank = 0; bank < 3; bank++) begin
                expected_x = (expected_rgb >> (bank*8)) & 255;
                expected_x += ((255-expected_x)*i+5)/10;
                check(dut.rgb[bank*8 +: 8] == expected_x, "GB 10/20/30% grid strength");
            end
        end
        strength = 0;
        for (mode = 0; mode < 4; mode++) begin
            colors = mode << 5;
            for (x = 0; x < 4; x++) begin
                position(x*4,27); settle();
                expected_rgb = dmg_colors[mode*4+(x+1)%4];
                check(dut.rgb == expected_rgb, "GB hardware palette");
            end
        end
        // Every channel value and percentage, independently of image content.
        for (x = 0; x < 256; x++)
            for (i = 0; i < 4; i++) begin
                expected_x = x + ((255-x)*i+5)/10;
                check(dut.pixel_effect(x, 1, 1, i) == expected_x, "GB exact grid percentages");
                check(dut.pixel_effect(x, 1, 0, i) == x, "GB pixel interiors unchanged");
            end
        // Fast must exactly retain the reference's integer 5-bit truncation.
        for (x = 0; x < 32768; x++) begin
            expected_x = (((x & 31)*13 + ((x>>5)&31)*2 + ((x>>10)&31)) >> 4);
            expected_y = ((((x>>5)&31)*3 + ((x>>10)&31)) >> 2);
            actual_channel = (((x & 31)*3 + ((x>>5)&31)*2 + ((x>>10)&31)*11) >> 4);
            expected_rgb = ((expected_x*8+expected_x/4)<<16) |
                           ((expected_y*8+expected_y/4)<<8) |
                           (actual_channel*8+actual_channel/4);
            check(dut.gbc_fast(x & 31, (x>>5)&31, (x>>10)&31) == expected_rgb, "GBC Fast exhaustive");
        end
        // Raw RGB555 and Accurate correction, including live palette byte writes.
        colors = 0; cgb = 1; zoom = 1; position(4,27); // source (1,1), index 2
        palette_byte(4, 8'h1f); palette_byte(5, 0); // red
        settle();
        check(dut.rgb == 24'hff0000, "CGB raw red");
        colors = 8;
        repeat (800) @(negedge clk);
        settle();
        check(dut.rgb[23:16] > 200 && dut.rgb[15:8] > 50 && dut.rgb[7:0] > 80 &&
              dut.rgb != 24'hff0000, "CGB Accurate applied");
        colors = 16; settle();
        check(dut.rgb == 24'hce0029, "CGB Fast pipeline");
        colors = 8; settle();
        palette_byte(4, 8'hff); palette_byte(5, 8'h7f); // white
        repeat (800) @(negedge clk); settle();
        check(dut.rgb[23:16] > 240 && dut.rgb[15:8] > 240 && dut.rgb[7:0] > 240, "CGB live correction");
        overlay = 1; osd_color = 16'h801f; settle();
        check(dut.rgb == 24'hf80000, "OSD bypasses video effects");
        overlay = 0; active = 0; settle();
        check(dut.rgb == 0, "browser backdrop black");
        $display("tb_nintendo_video PASSED");
        $finish;
    end
endmodule
