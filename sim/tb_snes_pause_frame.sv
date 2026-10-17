`timescale 1ns / 1ps
module tb_snes_pause_frame;
reg clk = 0, fclk = 0, clk_pixel = 0;
always #23.148 clk = ~clk;
always #5.787 fclk = ~fclk;
always #19.841 clk_pixel = ~clk_pixel;
reg resetn = 0, pause = 0, running = 1;
reg [1:0] zoom = 0, scanline = 0;
reg overlay = 0, overlay_text = 0;
reg [10:0] tick = 0;
reg [8:0] row = 0;
reg [7:0] field = 0;
wire hold_core, ready, display_active, row_request, sync_pause;
wire frame_req, frame_ack, frame_we;
wire [15:0] frame_address;
wire [14:0] frame_data, frame_q;
wire buffer_write;
wire [9:0] buffer_address;
wire [2:0] buffer_bank;
wire [14:0] buffer_data;
wire busy;
wire [8:0] source_y = row < 224 ? {field[0], row[7:0]} : {field[0], 8'd224};
function automatic [14:0] pattern(input [7:0] x, input [7:0] y, input [7:0] frame);
    pattern = {5'((y >> 5) ^ (x >> 5) ^ frame), y[4:0], x[4:0]};
endfunction
wire [14:0] source_rgb = pattern(tick[9:2], row[7:0], field);
// Mirrors the even-length stall guard on the SNES ENABLE in the top level.
reg core_odd_stall = 0;
wire core_enable = !busy && running && !hold_core && !sync_pause && !core_odd_stall;
always @(posedge clk)
    core_odd_stall <= !core_enable && !core_odd_stall;
always @(posedge clk) begin
    if (!resetn) begin
        tick <= 0;
        row <= 0;
        field <= 0;
    end else if (core_enable) begin
        if (tick == 1363) begin
            tick <= 0;
            row <= row == 261 ? 9'd0 : row + 1'b1;
            if (row == 261)
                field <= field + 1'b1;
        end else
            tick <= tick + 1'b1;
    end
end
snes_pause_frame capture (
    .clk(clk), .resetn(resetn), .running(running), .pause(pause),
    .dotclk(tick[1]), .hblank(tick >= 1024), .vblank(row >= 224),
    .xs({tick[9:2], tick[1]}), .ys(source_y), .rgb(source_rgb),
    .hold_core(hold_core), .ready(ready), .display_active(display_active), .row_request(row_request),
    .memory_req(frame_req), .memory_ack(frame_ack), .memory_we(frame_we),
    .memory_address(frame_address), .memory_data(frame_data), .memory_q(frame_q),
    .buffer_write(buffer_write), .buffer_address(buffer_address),
    .buffer_bank(buffer_bank), .buffer_data(buffer_data)
);
snes_video_640 video (
    .clk(clk), .resetn(resetn), .dotclk(tick[1]), .hblank(tick >= 1024),
    .vblank(row >= 224), .rgb5(source_rgb), .xs({tick[9:2], tick[1]}), .ys(source_y),
    .zoom(zoom), .scanline(scanline), .pause_pending(pause), .pause_ready(ready),
    .pause_display(display_active), .pause_row_request(row_request),
    .pause_buffer_write(buffer_write), .pause_buffer_address(buffer_address),
    .pause_buffer_bank(buffer_bank), .pause_buffer_data(buffer_data),
    .overlay(overlay), .overlay_text(overlay_text), .overlay_color(24'habcdef),
    .audio_l(16'd0), .audio_r(16'd0), .audio_ready(1'b0),
    .snes_refresh(tick >= 1100 && tick < 1140),
    .clk_pixel(clk_pixel), .clk_5x_pixel(clk_pixel), .locked(1'b1),
    .pause_snes_for_frame_sync(sync_pause)
);
wire [31:0] dq;
wire [10:0] memory_address;
wire [1:0] memory_bank;
wire [3:0] memory_mask;
wire cs, ras, cas, we, cke;
wire [23:0] refreshes;
reg vram_req = 0;
wire vram_ack;
reg [3:0] traffic = 0;
always @(posedge clk) begin
    if (!resetn) begin
        vram_req <= 0;
        traffic <= 0;
    end else begin
        traffic <= traffic + 1'b1;
        if (!hold_core && !busy && traffic == 0 && vram_req == vram_ack)
            vram_req <= ~vram_req;
    end
end
sdram_snes #(.SHARED_IOSYS(1), .SPLIT_WRAM(1), .UPSTREAM_RAM_LAYOUT(1), .FREQ(1000000)) ram (
    .clk(fclk), .mclk(clk), .clkref(tick[1:0] == 2'd1), .resetn(resetn), .busy(busy),
    .SDRAM_DQ(dq), .SDRAM_A(memory_address), .SDRAM_BA(memory_bank), .SDRAM_DQM(memory_mask),
    .SDRAM_nCS(cs), .SDRAM_nRAS(ras), .SDRAM_nCAS(cas), .SDRAM_nWE(we), .SDRAM_CKE(cke),
    .cpu_din(16'd0), .cpu_port(1'b0), .cpu_addr(22'd0), .cpu_req(1'b0), .cpu_we(1'b0), .cpu_ds(2'b11),
    .wram_addr(17'd0), .wram_din(8'd0), .wram_req(1'b0), .wram_we(1'b0),
    .bsram_addr(20'd0), .bsram_din(8'd0), .bsram_req(1'b0), .bsram_we(1'b0),
    .aram_16(1'b0), .aram_addr(16'd0), .aram_din(16'd0), .aram_req(1'b0), .aram_we(1'b0),
    .vram1_addr(15'h1234), .vram1_din(8'd0), .vram1_req(vram_req), .vram1_we(1'b0), .vram1_ack(vram_ack),
    .vram2_addr(15'd0), .vram2_din(8'd0), .vram2_req(1'b0), .vram2_we(1'b0),
    .rv_addr(22'd0), .rv_din(16'd0), .rv_ds(2'b11), .rv_req(1'b0), .rv_we(1'b0),
    .frame_req(frame_req), .frame_ack(frame_ack), .frame_we(frame_we),
    .frame_addr(frame_address), .frame_din(frame_data), .frame_dout(frame_q),
    .total_refresh(refreshes)
);
sdram_model #(.READ_HOLD_CYCLES(1)) memory (
    .DQ(dq), .A(memory_address), .BA(memory_bank), .DQM(memory_mask),
    .nCS(cs), .nRAS(ras), .nCAS(cas), .nWE(we), .CKE(cke), .CLK(~fclk), .clk(fclk)
);
// A core stall that shifts clkref by half an SDRAM slot makes the controller
// jump phases mid-transaction (duplicate ACTIVATE / skipped CAS on hardware).
reg clkref_locked = 0;
always @(posedge fclk)
    if (ram.normal && ram.clkref && !ram.clkref_r) begin
        if (clkref_locked && !ram.cycle[2])
            $fatal(1, "SDRAM ring realigned mid-slot: cycle=%b row=%0d x=%0d state=%0d hold=%b sync=%b pause=%b",
                   ram.cycle[7:0], row, tick, capture.state, hold_core, sync_pause, pause);
        clkref_locked <= 1;
    end
integer writes = 0;
reg previous_req = 0;
reg [7:0] captured_field;
always @(negedge clk) begin
    if (frame_req != previous_req && frame_we) begin
        if (writes == 0)
            captured_field = field;
        if (frame_address !== 16'(writes))
            $fatal(1, "Missing/duplicate captured pixel: got=%h expected=%h", frame_address, 16'(writes));
        writes = writes + 1;
    end
    previous_req = frame_req;
end
function automatic [4:0] avg(input [4:0] a, input [4:0] b);
    avg = (6'(a) + 6'(b)) >> 1;
endfunction
function automatic [4:0] interpolate(input [4:0] a, input [4:0] b, input integer weight);
    case (weight)
        0: interpolate = a;
        1: interpolate = avg(a, avg(a, b));
        2: interpolate = avg(a, b);
        default: interpolate = avg(b, avg(a, b));
    endcase
endfunction
integer x, y, index, mode, channel, sx, sy, nx, ny, wx, wy;
integer expected_active, checked;
reg [14:0] p00, p10, p01, p11;
reg [4:0] component;
reg [23:0] expected_rgb;
reg [31:0] stored;
task check_frame(input integer mode_value);
    wait(video.zoom_pixel == mode_value);
    wait(video.cy == 524 && video.cx == 799);
    @(negedge clk_pixel);
    checked = 0;
    repeat (800*525) begin
        expected_active = mode_value ? video.cx < 640 && video.cy < 480 :
            video.cx >= 64 && video.cx < 576 && video.cy >= 16 && video.cy < 464;
        expected_rgb = 0;
        if (expected_active) begin
            sx = mode_value ? video.cx * 2 / 5 : (video.cx - 64) / 2;
            sy = mode_value ? video.cy * 7 / 15 : (video.cy - 16) / 2;
            nx = sx == 255 ? sx : sx + 1;
            ny = sy == 223 ? sy : sy + 1;
            wx = mode_value == 2 && sx != 255 ? ((video.cx * 2 % 5) * 4 + 2) / 5 : 0;
            wy = mode_value == 2 && sy != 223 ? (video.cy * 7 % 15) / 4 : 0;
            p00 = pattern(sx, sy, captured_field);
            p10 = pattern(nx, sy, captured_field);
            p01 = pattern(sx, ny, captured_field);
            p11 = pattern(nx, ny, captured_field);
            for (channel = 0; channel < 3; channel = channel + 1) begin
                component = interpolate(interpolate(p00[channel*5 +: 5], p10[channel*5 +: 5], wx),
                                        interpolate(p01[channel*5 +: 5], p11[channel*5 +: 5], wx), wy);
                expected_rgb[(2-channel)*8 +: 8] = {component, 3'd0};
            end
            checked = checked + 1;
        end
        if (video.rgb !== expected_rgb)
            $fatal(1, "Paused frame mismatch zoom=%0d actual_zoom=%0d x=%0d y=%0d got=%h expected=%h read_y=%0d active=%b display=%b pixel=%h data=%h/%h group=%d",
                   mode_value, video.zoom_pixel, video.cx, video.cy, video.rgb, expected_rgb,
                   capture.read_y, video.active_pixel, display_active, video.pixel_data,
                   video.data_ee, video.data_oe, video.pixel_group);
        if (!hold_core)
            $fatal(1, "SNES resumed while displaying paused frame");
        @(negedge clk_pixel);
    end
    if (checked != (mode_value ? 640*480 : 512*448))
        $fatal(1, "Incomplete paused frame");
endtask
initial begin
    repeat (8) @(negedge clk);
    resetn = 1;
    wait(!busy);
    repeat (100) @(negedge clk);
    if (hold_core)
        $fatal(1, "Core stalled without a pause request");
    wait(row == 50);
    pause = 1;
    wait(ready);
    if (writes != 256*224)
        $fatal(1, "Incomplete snapshot: %0d pixels", writes);
    for (y = 0; y < 224; y = y + 1)
        for (x = 0; x < 256; x = x + 1) begin
            index = y * 256 + x;
            stored = memory.mem[(23'h600000 >> 2) + (index >> 1)];
            if ((index[0] ? stored[30:16] : stored[14:0]) !== pattern(x, y, captured_field))
                $fatal(1, "SDRAM snapshot mismatch x=%0d y=%0d", x, y);
        end
    wait(display_active);
    for (mode = 0; mode < 3; mode = mode + 1) begin
        zoom = 2'(mode);
        check_frame(mode);
    end
    overlay = 1;
    overlay_text = 1;
    repeat (4) @(negedge clk_pixel);
    if (video.rgb !== 24'habcdef)
        $fatal(1, "Pause OSD is not visible");
    overlay = 0;
    overlay_text = 0;
    pause = 0;
    wait(!hold_core);
    if (display_active)
        $fatal(1, "Core resumed before paused display was released");
    wait(row == 100);
    writes = 0;
    pause = 1;
    wait(capture.state == capture.CAPTURE && frame_req != frame_ack);
    pause = 0;
    wait(capture.state == capture.IDLE);
    if (frame_req != frame_ack)
        $fatal(1, "Cancelled capture left an outstanding transaction");
    writes = 0;
    pause = 1;
    wait(ready);
    wait(display_active);
    check_frame(2);
    running = 0;
    wait(capture.state == capture.IDLE);
    if (ready || display_active || frame_req != frame_ack)
        $fatal(1, "Reset/browser transition retained the paused frame");
    if (refreshes < 100)
        $fatal(1, "Snapshot traffic starved SDRAM refresh");
    $display("tb_snes_pause_frame PASSED: full SDRAM capture, all zoom modes, OSD, resume, cancellation, reset and refresh");
    $finish;
end
initial begin
    #350000000;
    $fatal(1, "Pause test timeout state=%0d row=%0d x=%0d writes=%0d", capture.state, row, tick, writes);
end
endmodule
