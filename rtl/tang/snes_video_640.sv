module snes_video_640 (
    input wire clk,
    input wire resetn,
    input wire dotclk,
    input wire hblank,
    input wire vblank,
    input wire [14:0] rgb5,
    input wire [8:0] xs,
    input wire [8:0] ys,
    input wire [1:0] zoom,
    input wire [1:0] scanline,
    input wire pause_pending,
    input wire pause_ready,
    output reg pause_display,
    output reg pause_row_request,
    input wire pause_buffer_write,
    input wire [9:0] pause_buffer_address,
    input wire [2:0] pause_buffer_bank,
    input wire [14:0] pause_buffer_data,
    input wire overlay,
    input wire overlay_text,
    input wire [23:0] overlay_color,
    output wire [10:0] overlay_x,
    output wire [9:0] overlay_y,
    output wire overlay_de,
    input wire [15:0] audio_l,
    input wire [15:0] audio_r,
    input wire audio_ready,
    input wire snes_refresh,
    input wire clk_pixel,
    input wire clk_5x_pixel,
    input wire locked,
    output reg pause_snes_for_frame_sync = 0,
    output wire tmds_clk_n,
    output wire tmds_clk_p,
    output wire [2:0] tmds_d_n,
    output wire [2:0] tmds_d_p
);

wire [10:0] cx, frame_width;
wire [9:0] cy, frame_height;
reg [1:0] zoom_meta = 0, zoom_pixel = 0;
reg [1:0] scan_meta = 0, scan_pixel = 0;
reg pause_meta = 0, pause_pixel = 0;
reg ready_meta = 0, ready_pixel = 0;
reg requested_odd = 1;
always @(posedge clk_pixel) begin
    zoom_meta <= zoom;
    if (!pause_display || (cx == 0 && cy == 480))
        zoom_pixel <= zoom_meta;
    scan_meta <= scanline;
    scan_pixel <= scan_meta;
    pause_meta <= pause_pending;
    pause_pixel <= pause_meta;
    ready_meta <= pause_ready;
    ready_pixel <= ready_meta;
    if (!resetn) begin
        pause_display <= 0;
        requested_odd <= 1;
        pause_row_request <= 0;
    end else begin
        if (cx == 799 && cy == 524)
            pause_display <= ready_pixel;
        if (!pause_display)
            requested_odd <= 1;
        else if (render_active && source_y[0] != requested_odd) begin
            requested_odd <= source_y[0];
            pause_row_request <= ~pause_row_request;
        end
    end
end

wire [10:0] render_x = cx == 11'd799 ? 11'd0 : cx + 11'd1;
wire [9:0] render_y = cx == 11'd799 ?
                       (cy == 10'd524 ? 10'd0 : cy + 10'd1) : cy;
wire integer_zoom = zoom_pixel == 0;
wire render_active = integer_zoom ?
    (render_x >= 64 && render_x < 576 && render_y >= 16 && render_y < 464) :
    (render_x < 640 && render_y < 480);
reg [7:0] stretch_x = 0, stretch_y = 0;
reg [2:0] phase_x = 0;
reg [3:0] phase_y = 0;
always @(posedge clk_pixel) begin
    if (!resetn || render_x == 799) begin
        stretch_x <= 0;
        phase_x <= 0;
    end else if (render_x < 639) begin
        if (phase_x >= 3) begin
            phase_x <= phase_x - 3'd3;
            stretch_x <= stretch_x + 1'b1;
        end else
            phase_x <= phase_x + 3'd2;
    end
    if (!resetn || (render_x == 799 && render_y == 524)) begin
        stretch_y <= 0;
        phase_y <= 0;
    end else if (render_x == 799 && render_y < 479) begin
        if (phase_y >= 8) begin
            phase_y <= phase_y - 4'd8;
            stretch_y <= stretch_y + 1'b1;
        end else
            phase_y <= phase_y + 4'd7;
    end
end
wire [7:0] source_x = integer_zoom ? ((render_x - 11'd64) >> 1) : stretch_x;
wire [7:0] source_y = integer_zoom ? ((render_y - 10'd16) >> 1) : stretch_y;
wire [6:0] even_column = source_x[7:1] + source_x[0];
reg previous_read_odd = 0;
reg [1:0] read_group_counter = 0;
reg [2:0] read_row_counter = 0;
wire new_read_line = source_y[0] != previous_read_odd;
wire [1:0] row_group = source_y == 0 ? 2'd0 : new_read_line ?
    (read_group_counter == 2 ? 2'd0 : read_group_counter + 1'b1) : read_group_counter;
wire [2:0] row_quotient = source_y == 0 ? 3'd0 :
    read_row_counter + (new_read_line && read_group_counter == 2);
always @(posedge clk_pixel) begin
    if (!resetn) begin
        previous_read_odd <= 0;
        read_group_counter <= 0;
        read_row_counter <= 0;
    end else if (render_active) begin
        previous_read_odd <= source_y[0];
        read_group_counter <= row_group;
        read_row_counter <= row_quotient;
    end
end
wire [2:0] row_zero = row_quotient + (row_group == 2);
wire [9:0] address_ee = {row_zero, even_column};
wire [9:0] address_eo = {row_zero, source_x[7:1]};
wire [9:0] address_oe = {row_quotient[2:0], even_column};
wire [9:0] address_oo = {row_quotient[2:0], source_x[7:1]};
reg [1:0] fraction_x, fraction_y;
reg [1:0] horizontal_weight;
always @* begin
    case (phase_x)
        0: horizontal_weight = 0;
        1: horizontal_weight = 1;
        2: horizontal_weight = 2;
        3: horizontal_weight = 2;
        default: horizontal_weight = 3;
    endcase
end

(* syn_ramstyle = "block_ram" *) reg [14:0] lines_ee [0:1023];
(* syn_ramstyle = "block_ram" *) reg [14:0] lines_eo [0:1023];
(* syn_ramstyle = "block_ram" *) reg [14:0] lines_oe [0:1023];
(* syn_ramstyle = "block_ram" *) reg [14:0] lines_oo [0:1023];
(* syn_ramstyle = "block_ram" *) reg [14:0] lines_te [0:1023];
(* syn_ramstyle = "block_ram" *) reg [14:0] lines_to [0:1023];
reg [14:0] data_ee, data_eo, data_oe, data_oo, data_te, data_to;
reg odd_x;
reg [1:0] pixel_group;
reg active_pixel = 0;
reg dark_pixel = 0;
reg [9:0] write_address;
reg [2:0] write_bank;
reg [14:0] write_data;
reg write_enable = 0;
reg dotclk_previous = 0;
reg previous_write_odd = 0;
reg [1:0] write_group_counter = 0;
reg [2:0] write_row_counter = 0;
wire new_write_line = ys[0] != previous_write_odd;
wire [1:0] write_group = ys[7:0] == 0 ? 2'd0 : new_write_line ?
    (write_group_counter == 2 ? 2'd0 : write_group_counter + 1'b1) : write_group_counter;
wire [2:0] write_row = ys[7:0] == 0 ? 3'd0 :
    write_row_counter + (new_write_line && write_group_counter == 2);
integer pixel_index;
initial begin
    for (pixel_index = 0; pixel_index < 1024; pixel_index = pixel_index + 1) begin
        lines_ee[pixel_index] = 0;
        lines_eo[pixel_index] = 0;
        lines_oe[pixel_index] = 0;
        lines_oo[pixel_index] = 0;
        lines_te[pixel_index] = 0;
        lines_to[pixel_index] = 0;
    end
end

always @(posedge clk) begin
    if (!resetn) begin
        previous_write_odd <= 0;
        write_group_counter <= 0;
        write_row_counter <= 0;
    end else begin
        previous_write_odd <= ys[0];
        write_group_counter <= write_group;
        write_row_counter <= write_row;
    end
    dotclk_previous <= dotclk;
    write_enable <= resetn && (pause_buffer_write ||
                    (!pause_ready && dotclk && !dotclk_previous && !hblank && !vblank && ys[7:0] < 224));
    write_address <= pause_buffer_write ? pause_buffer_address : {write_row, xs[8:2]};
    write_bank <= pause_buffer_write ? pause_buffer_bank : {write_group, xs[1]};
    write_data <= pause_buffer_write ? pause_buffer_data : rgb5;
    if (write_enable) begin
        case (write_bank)
            0: lines_ee[write_address] <= write_data;
            1: lines_eo[write_address] <= write_data;
            2: lines_oe[write_address] <= write_data;
            3: lines_oo[write_address] <= write_data;
            4: lines_te[write_address] <= write_data;
            5: lines_to[write_address] <= write_data;
        endcase
    end
end

always @(posedge clk_pixel) begin
    data_ee <= lines_ee[address_ee];
    data_eo <= lines_eo[address_eo];
    data_oe <= lines_oe[address_oe];
    data_oo <= lines_oo[address_oo];
    data_te <= lines_te[address_oe];
    data_to <= lines_to[address_oo];
    odd_x <= source_x[0];
    pixel_group <= row_group;
    fraction_x <= zoom_pixel == 2 && source_x != 255 ? horizontal_weight : 2'd0;
    fraction_y <= zoom_pixel == 2 && source_y != 223 ? phase_y[3:2] : 2'd0;
    active_pixel <= render_active;
    dark_pixel <= render_y[0];
end

wire [14:0] upper_even = ({15{pixel_group == 0}} & data_ee) |
                         ({15{pixel_group == 1}} & data_oe) | ({15{pixel_group == 2}} & data_te);
wire [14:0] upper_odd = ({15{pixel_group == 0}} & data_eo) |
                        ({15{pixel_group == 1}} & data_oo) | ({15{pixel_group == 2}} & data_to);
wire [14:0] lower_even = ({15{pixel_group == 0}} & data_oe) |
                         ({15{pixel_group == 1}} & data_te) | ({15{pixel_group == 2}} & data_ee);
wire [14:0] lower_odd = ({15{pixel_group == 0}} & data_oo) |
                        ({15{pixel_group == 1}} & data_to) | ({15{pixel_group == 2}} & data_eo);
wire [14:0] upper_left = odd_x ? upper_odd : upper_even;
wire [14:0] upper_right = odd_x ? upper_even : upper_odd;
wire [14:0] lower_left = odd_x ? lower_odd : lower_even;
wire [14:0] lower_right = odd_x ? lower_even : lower_odd;
function automatic [4:0] average(input [4:0] first, input [4:0] second);
    reg [5:0] total;
    begin
        total = {1'b0, first} + {1'b0, second};
        average = total[5:1];
    end
endfunction
wire [14:0] pixel_data;
wire select_odd = odd_x ^ (&fraction_x);
wire [14:0] upper_selected = select_odd ? upper_odd : upper_even;
wire [14:0] lower_selected = select_odd ? lower_odd : lower_even;
genvar channel;
generate for (channel = 0; channel < 3; channel = channel + 1) begin : g_bilinear
    wire [4:0] upper_middle = average(upper_even[channel*5 +: 5], upper_odd[channel*5 +: 5]);
    wire [4:0] lower_middle = average(lower_even[channel*5 +: 5], lower_odd[channel*5 +: 5]);
    wire [4:0] upper = fraction_x[0] ? average(upper_selected[channel*5 +: 5], upper_middle) :
                      fraction_x[1] ? upper_middle : upper_selected[channel*5 +: 5];
    wire [4:0] lower = fraction_x[0] ? average(lower_selected[channel*5 +: 5], lower_middle) :
                      fraction_x[1] ? lower_middle : lower_selected[channel*5 +: 5];
    wire [4:0] middle = average(upper, lower);
    wire [4:0] selected = (&fraction_y) ? lower : upper;
    assign pixel_data[channel*5 +: 5] = fraction_y[0] ? average(selected, middle) :
                                       fraction_y[1] ? middle : selected;
end endgenerate
wire [7:0] red_raw = {pixel_data[4:0], 3'd0};
wire [7:0] green_raw = {pixel_data[9:5], 3'd0};
wire [7:0] blue_raw = {pixel_data[14:10], 3'd0};
function automatic [7:0] shade(input [7:0] color, input [1:0] strength);
    case (strength)
        1: shade = color - (color >> 2);
        2: shade = color >> 1;
        3: shade = 0;
        default: shade = color;
    endcase
endfunction
wire [7:0] red = dark_pixel ? shade(red_raw, scan_pixel) : red_raw;
wire [7:0] green = dark_pixel ? shade(green_raw, scan_pixel) : green_raw;
wire [7:0] blue = dark_pixel ? shade(blue_raw, scan_pixel) : blue_raw;
wire [23:0] game_rgb = active_pixel && (!pause_pixel || pause_display) ?
                       {red, green, blue} : 24'd0;
wire [23:0] rgb = overlay ? (overlay_text ? overlay_color :
    {1'b0, game_rgb[23:17], 1'b0, game_rgb[15:9], 1'b0, game_rgb[7:1]}) : game_rgb;

wire [10:0] osd_lookahead = cx + 11'd3;
assign overlay_x = osd_lookahead >= 800 ? osd_lookahead - 11'd800 : osd_lookahead;
assign overlay_y = osd_lookahead >= 800 ? (cy == 524 ? 10'd0 : cy + 10'd1) : cy;
assign overlay_de = overlay_x < 640 && overlay_y < 480;

reg frame_start_pixel = 0;
reg frame_start_meta = 0, frame_start_sync = 0;
reg sync_done = 0;
reg pause_phase = 0;
always @(posedge clk_pixel)
    frame_start_pixel <= cy == (integer_zoom ? 16 : 0) && cx < 128;
always @(posedge clk) begin
    frame_start_meta <= frame_start_pixel;
    frame_start_sync <= frame_start_meta;
    if (!resetn) begin
        pause_snes_for_frame_sync <= 0;
        sync_done <= 0;
        pause_phase <= 0;
    end else begin
        if (pause_snes_for_frame_sync)
            pause_phase <= ~pause_phase;
        if (!sync_done) begin
            if (!pause_snes_for_frame_sync && ys[7:0] == 2 && snes_refresh) begin
                pause_snes_for_frame_sync <= 1;
                pause_phase <= 0;
            end else if (pause_snes_for_frame_sync && frame_start_sync && pause_phase) begin
                pause_snes_for_frame_sync <= 0;
                sync_done <= 1;
            end
        end
        if (ys[7:0] == 200)
            sync_done <= 0;
    end
end

localparam AUDIO_DELAY = 25200000 / 32000 / 2;
reg [$clog2(AUDIO_DELAY)-1:0] audio_divider = 0;
reg clk_audio = 0;
reg audio_read = 0;
reg [15:0] audio_sample_word [1:0];
wire [31:0] audio_sample;
wire audio_empty;
always @(posedge clk_pixel) begin
    audio_read <= 0;
    if (!resetn) begin
        audio_divider <= 0;
        clk_audio <= 0;
        audio_sample_word[0] <= 0;
        audio_sample_word[1] <= 0;
    end else if (audio_divider == AUDIO_DELAY - 1) begin
        audio_divider <= 0;
        clk_audio <= ~clk_audio;
        if (!clk_audio && !audio_empty) begin
            {audio_sample_word[0], audio_sample_word[1]} <= audio_sample;
            audio_read <= 1;
        end
    end else begin
        audio_divider <= audio_divider + 1'b1;
    end
end

dual_clk_fifo #(.DATESIZE(32), .ADDRSIZE(4)) audio_fifo (
    .clk(clk), .wrst_n(resetn), .winc(audio_ready), .wdata({audio_l, audio_r}), .wfull(),
    .rclk(clk_pixel), .rrst_n(resetn), .rinc(audio_read), .rdata(audio_sample), .rempty(audio_empty),
    .almost_full(), .almost_empty()
);

wire [2:0] tmds;
hdmi #(.VIDEO_ID_CODE(1), .BIT_WIDTH(11), .BIT_HEIGHT(10), .DVI_OUTPUT(0),
       .VIDEO_REFRESH_RATE(60.0), .IT_CONTENT(1), .AUDIO_RATE(32000), .AUDIO_BIT_WIDTH(16)) hdmi (
    .clk_pixel_x5(clk_5x_pixel), .clk_pixel(clk_pixel), .clk_audio(clk_audio), .reset(!resetn),
    .rgb(rgb), .audio_sample_word(audio_sample_word), .tmds(tmds), .tmds_clock(),
    .cx(cx), .cy(cy), .frame_width(frame_width), .frame_height(frame_height)
);
ELVDS_OBUF tmds_buffers [3:0] (
    .I({clk_pixel, tmds}), .O({tmds_clk_p, tmds_d_p}), .OB({tmds_clk_n, tmds_d_n})
);
endmodule