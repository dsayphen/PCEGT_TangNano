`timescale 1ns/1ps

module tb_dvi_video_window;
reg clk_pix = 0;
reg clk_pix5 = 0;
reg resetn = 0;
reg audio_enable = 1;
reg [10:0] pix_x = 0;
reg [9:0] pix_y = 0;

always #19.290 clk_pix = ~clk_pix;
always #3.858 clk_pix5 = ~clk_pix5;

GSR GSR (.GSRI(resetn));

dvi_tx dut (
    .clk_pix(clk_pix), .clk_pix5(clk_pix5), .resetn(resetn),
    .r(8'd0), .g(8'd0), .b(8'd0), .de(1'b0),
    .hsync(1'b0), .vsync(1'b0), .pix_x(pix_x), .pix_y(pix_y),
    .audio_enable(audio_enable), .clk_audio(clk_pix),
    .audio_left(16'sd0), .audio_right(16'sd0),
    .tmds_clk_p(), .tmds_clk_n(), .tmds_d_p(), .tmds_d_n()
);

integer line_number;
integer frame_lines;
integer preamble_lines;
integer guard_lines;
integer errors = 0;
reg expected_video;

initial begin
    repeat (4) @(posedge clk_pix);
    @(negedge clk_pix);
    resetn = 1;
    repeat (4) @(posedge clk_pix);

    for (frame_lines = 524; frame_lines <= 526; frame_lines = frame_lines + 2) begin
        preamble_lines = 0;
        guard_lines = 0;
        for (line_number = 0; line_number < frame_lines; line_number = line_number + 1) begin
            expected_video = line_number >= 42 && line_number < 522;
            pix_y = line_number;
            pix_x = 142;
            #1;
            if (dut.video_preamble)
                preamble_lines = preamble_lines + 1;
            if (dut.video_preamble !== expected_video || dut.c1[0] !== expected_video) begin
                $display("FAIL preamble on line %0d of %0d", line_number, frame_lines);
                errors = errors + 1;
            end
            pix_x = 150;
            #1;
            if (dut.video_guard)
                guard_lines = guard_lines + 1;
            if (dut.video_guard !== expected_video || dut.mode !== (expected_video ? 3'd2 : 3'd0)) begin
                $display("FAIL guard on line %0d of %0d", line_number, frame_lines);
                errors = errors + 1;
            end
            pix_x = 152;
            #1;
            if (dut.video_preamble || dut.video_guard) begin
                $display("FAIL video signalling overlaps active pixels on line %0d", line_number);
                errors = errors + 1;
            end
        end
        if (preamble_lines != 480 || guard_lines != 480) begin
            $display("FAIL frame %0d: %0d preambles, %0d guards, expected 480",
                     frame_lines, preamble_lines, guard_lines);
            errors = errors + 1;
        end
    end

    @(negedge clk_pix);
    audio_enable = 0;
    repeat (4) @(posedge clk_pix);
    pix_y = 521;
    pix_x = 142;
    #1;
    if (dut.video_preamble || dut.video_guard || dut.mode !== 3'd0) begin
        $display("FAIL DVI mode unexpectedly emits HDMI video signalling");
        errors = errors + 1;
    end
    pix_x = 150;
    #1;
    if (dut.video_preamble || dut.video_guard || dut.mode !== 3'd0) begin
        $display("FAIL DVI mode unexpectedly emits HDMI video guard");
        errors = errors + 1;
    end

    if (errors != 0)
        $fatal(1, "tb_dvi_video_window FAILED: %0d errors", errors);
    $display("*** tb_dvi_video_window PASSED ***");
    $finish;
end
endmodule