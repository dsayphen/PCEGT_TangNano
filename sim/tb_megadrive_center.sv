`timescale 1ns/10ps
module tb_megadrive_center;
    reg clk = 0, clk_pixel = 0;
    always #4.94 clk = ~clk;
    always #8.55 clk_pixel = ~clk_pixel;
    reg resetn = 0, ce = 0, hblank = 1, vblank = 1, v30 = 0, pal = 0;
    reg [11:0] rgb = 12'hf84;
    wire [23:0] out_rgb;
    wire [10:0] pixel_x;
    wire [9:0] pixel_y, frame_height;
    wire de, vs;
    megadrive_video dut (
        .clk(clk), .resetn(resetn), .ce(ce), .hblank(hblank), .vblank(vblank),
        .rgb(rgb), .v30(v30), .pal(pal), .clk_pixel(clk_pixel), .pixel_resetn(resetn),
        .zoom(2'd1), .scanline(2'd0), .overlay(1'b0), .overlay_rgb(24'b0),
        .out_rgb(out_rgb), .pixel_x(pixel_x), .pixel_y(pixel_y), .frame_height(frame_height), .de(de), .vs(vs)
    );
    task frame(input integer height, input integer total, input integer pal_mode);
        integer line_index, tick, source_line;
        begin
            for (line_index = 0; line_index < total; line_index = line_index + 1) begin
                for (tick = 0; tick < 3420; tick = tick + 1) begin
                    hblank = tick >= 2560;
                    vblank = line_index == 0 ? tick < 2500 :
                             line_index <= height ? 0 :
                             line_index == height + 1 ? tick >= 2500 : 1;
                    source_line = line_index - 1;
                    rgb = source_line >= 0 && source_line < height ?
                          {4'hf, source_line[3:0], source_line[7:4]} : 12'd0;
                    ce = tick % 8 == 0;
                    @(negedge clk);
                end
            end
        end
    endtask
    task measure(input integer height, input integer total);
        integer rows, lit_rows, first, last, top, bottom, source_line;
        reg [23:0] expected_color;
        begin
            wait (frame_height == total * 2);
            do @(negedge clk_pixel); while (!(pixel_x == 100 && pixel_y == 0));
            lit_rows = 0; first = -1; last = -1; top = 0; bottom = 0;
            for (rows = 0; rows < 480; rows = rows + 1) begin
                if (!de || pixel_y != rows) $fatal(1,"raster continuity row%0d actual%0d",rows,pixel_y);
                source_line = (rows - (height == 224 ? 16 : 0)) / 2;
                expected_color = {8'hff, {2{source_line[3:0]}}, {2{source_line[7:4]}}};
                if (rows >= (height == 224 ? 16 : 0) &&
                    rows < (height == 224 ? 464 : 480) &&
                    out_rgb !== expected_color)
                    $fatal(1,"vertical source order row%0d got%h expected line%0d color%h",
                           rows,out_rgb,source_line,expected_color);
                if (rows >= (height == 224 ? 16 : 0) &&
                    rows < (height == 224 ? 464 : 480)) begin
                    if (first == -1) first = rows;
                    last = rows;
                    lit_rows = lit_rows + 1;
                end else if (out_rgb != 0) $fatal(1,"unexpected border color");
                if (rows < (480 - height * 2) / 2 && out_rgb == 0) top = top + 1;
                if (rows >= 480 - (480 - height * 2) / 2 && out_rgb == 0) bottom = bottom + 1;
                if (rows != 479)
                    do @(negedge clk_pixel); while (pixel_x != 100);
            end
            if (lit_rows != height * 2 || first != (480 - height * 2) / 2 ||
                last != 479 - (480 - height * 2) / 2 || top != bottom)
                $fatal(1,"centering %0d/%0d lit%0d bounds%0d..%0d borders%0d/%0d",
                       height,total,lit_rows,first,last,top,bottom);
        end
    endtask
    // Console lines must stay phase-locked: only the first line may resync.
    integer resyncs = 0;
    integer pixel_count = 0;
    always @(posedge clk_pixel) pixel_count = pixel_count + 1;
    always @(posedge clk_pixel)
        if (resetn && dut.line_event && !dut.event_locked) resyncs = resyncs + 1;
    // Every console line is exactly 1976 pixel clocks.
    task frame_period(input integer total);
        integer pixels, expected;
        begin
            expected = total * 1976;
            @(posedge vs); pixels = pixel_count;
            @(posedge vs); pixels = pixel_count - pixels;
            if (pixels != expected)
                $fatal(1,"frame period %0d pixels expected %0d",pixels,expected);
        end
    endtask
    task scenario(input integer height, input integer total, input integer pal_mode);
        begin
            v30 = height == 240;
            pal = pal_mode;
            fork
                begin repeat (6) frame(height,total,pal_mode); end
                begin
                    repeat (2 * total * 3420) @(negedge clk);
                    measure(height,total);
                    frame_period(total);
                end
            join
        end
    endtask
    initial begin
        repeat (10) @(negedge clk); resetn = 1;
        scenario(224,262,0);
        scenario(240,263,0);
        scenario(224,263,0);
        scenario(224,312,1);
        scenario(240,313,1);
        if (resyncs != 1) $fatal(1,"line lock lost: %0d resyncs",resyncs);
        $display("PASS Mega Drive vertical order/centering: V28/V30 NTSC/PAL, 262/263/312/313 lines, locked, exact frame period");
        $finish;
    end
    initial begin #900000000; $fatal(1,"timeout"); end
endmodule
