`timescale 1ns/1ps

module tb_frame_snapshot;
reg clk = 1'b0;
always #5 clk = ~clk;

reg resetn = 1'b0;
reg capture_start = 1'b0;
reg capture_supported = 1'b1;
reg paused = 1'b0;
reg video_ce = 1'b0;
reg video_vs = 1'b0;
reg video_vbl = 1'b0;
reg video_hbl = 1'b1;
reg [8:0] video_rgb = 9'd0;
reg [15:0] video_mode = 16'd1;
wire busy;
wire frame_valid;
wire failed;
wire [3:0] failure_reason;
wire video_override;
wire [8:0] snapshot_rgb;
wire [17:0] frame_pixels;
wire mem_valid;
wire mem_write;
wire [22:0] mem_addr;
wire [31:0] mem_wdata;
wire [3:0] mem_wstrb;
reg stall_mem = 1'b0;
reg [2:0] read_wait = 3'd0;
reg read_servicing = 1'b0;
wire mem_ready = mem_valid && !stall_mem &&
                 (mem_write || (read_servicing && read_wait == 3'd0));
wire [31:0] mem_rdata;
reg [31:0] memory [0:49151];
reg [8:0] observed_pixels [0:7];
integer observed_count = 0;

assign mem_rdata = memory[(mem_addr - 23'h57_0000) >> 2];

always @(posedge clk) begin
    if (!resetn) begin
        read_wait <= 3'd0;
        read_servicing <= 1'b0;
    end else if (mem_valid && !mem_write && !read_servicing) begin
        read_servicing <= 1'b1;
        read_wait <= 3'd6;
    end else if (read_servicing && read_wait != 3'd0) begin
        read_wait <= read_wait - 3'd1;
    end else if (mem_valid && !mem_write && mem_ready) begin
        read_servicing <= 1'b0;
    end
    if (mem_valid && mem_ready && mem_write)
        memory[(mem_addr - 23'h57_0000) >> 2] <= mem_wdata;
    if (paused && video_ce && !video_hbl && !video_vbl && video_override) begin
        observed_pixels[observed_count] <= snapshot_rgb;
        observed_count <= observed_count + 1;
    end
end

frame_snapshot dut (
    .clk(clk), .resetn(resetn), .capture_start(capture_start),
    .capture_supported(capture_supported), .paused(paused),
    .video_ce(video_ce), .video_vs(video_vs), .video_vbl(video_vbl),
    .video_hbl(video_hbl), .video_rgb(video_rgb), .video_mode(video_mode),
    .busy(busy), .frame_valid(frame_valid), .failed(failed),
    .failure_reason(failure_reason),
    .video_override(video_override), .snapshot_rgb(snapshot_rgb),
    .frame_pixels(frame_pixels), .mem_valid(mem_valid),
    .mem_write(mem_write), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
    .mem_wstrb(mem_wstrb), .mem_ready(mem_ready), .mem_rdata(mem_rdata)
);

task pulse_vsync;
    begin
        @(negedge clk); video_vs = 1'b1;
        repeat (2) @(negedge clk);
        video_vs = 1'b0;
        repeat (10) @(negedge clk);
    end
endtask

task send_pixel;
    input [8:0] pixel;
    begin
        @(negedge clk);
        video_hbl = 1'b0;
        video_rgb = pixel;
        video_ce = 1'b1;
        @(posedge clk); #1;
        video_ce = 1'b0;
        repeat (3) @(negedge clk);
    end
endtask

initial begin
    repeat (3) @(negedge clk);
    resetn = 1'b1;
    capture_start = 1'b1;
    @(negedge clk); capture_start = 1'b0;
    if (!busy || frame_valid) $fatal(1, "capture did not enter wait state");

    pulse_vsync();
    video_vbl = 1'b1;
    send_pixel(9'h1ff);
    video_vbl = 1'b0;
    send_pixel(9'h001);
    send_pixel(9'h012);
    send_pixel(9'h034);
    send_pixel(9'h056);
    send_pixel(9'h078);
    send_pixel(9'h09a);
    if (frame_valid) $fatal(1, "partial frame was declared valid");

    pulse_vsync();
    wait (frame_valid);
    if (busy || frame_pixels != 18'd6)
        $fatal(1, "completed frame metadata is wrong");
    if (memory[0] !== {5'd0, 9'h034, 9'h012, 9'h001} ||
        memory[1] !== {5'd0, 9'h09a, 9'h078, 9'h056})
        $fatal(1, "captured pixels were not packed in order");

    paused = 1'b1;
    repeat (8) @(negedge clk);
    pulse_vsync();
    if (!video_override) $fatal(1, "snapshot playback did not activate");
    send_pixel(9'h1ff);
    send_pixel(9'h1fe);
    send_pixel(9'h1fd);
    send_pixel(9'h1fc);
    send_pixel(9'h1fb);
    send_pixel(9'h1fa);
    if (observed_count != 6 || observed_pixels[0] !== 9'h001 ||
        observed_pixels[1] !== 9'h012 || observed_pixels[2] !== 9'h034 ||
        observed_pixels[3] !== 9'h056 || observed_pixels[4] !== 9'h078 ||
        observed_pixels[5] !== 9'h09a)
        $fatal(1, "scandoubler sample pixels were shifted or corrupted");
    pulse_vsync();
    send_pixel(9'h1f9);
    if (observed_count != 7 || observed_pixels[6] !== 9'h001 ||
        !frame_valid || !video_override)
        $fatal(1, "snapshot did not remain stable on the next frame");

    paused = 1'b0;
    #1;
    if (video_override) $fatal(1, "resume did not select live video");

    capture_start = 1'b1;
    @(negedge clk); capture_start = 1'b0;
    wait (dut.state == 3'd1);
    pulse_vsync();
    send_pixel(9'h011);
    video_mode = 16'd2;
    send_pixel(9'h022);
    pulse_vsync();
    repeat (4) @(negedge clk);
    if (frame_valid || !failed || failure_reason != 4'd3)
        $fatal(1, "mid-frame mode change was not rejected");

    capture_supported = 1'b0;
    capture_start = 1'b1;
    @(negedge clk); capture_start = 1'b0;
    repeat (3) @(negedge clk);
    if (frame_valid || !failed || failure_reason != 4'd1)
        $fatal(1, "unsupported mode did not report capture failure");

    capture_supported = 1'b1;
    stall_mem = 1'b1;
    capture_start = 1'b1;
    @(negedge clk); capture_start = 1'b0;
    wait (dut.state == 3'd1);
    pulse_vsync();
    send_pixel(9'h101);
    send_pixel(9'h102);
    send_pixel(9'h103);
    send_pixel(9'h104);
    send_pixel(9'h105);
    send_pixel(9'h106);
    if (!busy || !mem_valid || !mem_write || !failed || failure_reason != 4'd5)
        $fatal(1, "capture overrun did not hold failed write pending");
    begin : check_write_stability
        reg [22:0] held_addr;
        reg [31:0] held_data;
        held_addr = mem_addr;
        held_data = mem_wdata;
        repeat (4) begin
            @(negedge clk);
            if (!mem_valid || !mem_write || mem_addr !== held_addr ||
                mem_wdata !== held_data)
                $fatal(1, "pending snapshot write changed before ACK");
        end
    end
    stall_mem = 1'b0;
    wait (!busy);
    if (frame_valid || !failed || mem_valid)
        $fatal(1, "failed capture did not drain cleanly");

    $display("tb_frame_snapshot PASSED");
    $finish;
end
endmodule