// Two 512-pixel lines fit in one BSRAM. No frame buffer or interpolation.
// Each 3420-MCLK console line becomes two fixed H_TOTAL-pixel output lines;
// the board's 494/855 pixel/console clock ratio makes 3420 MCLKs exactly
// 2*988 pixel clocks. The output free-runs and console lines only steer its
// phase, so a lost or early line resynchronizes once instead of tearing.
module megadrive_video #(
    parameter H_TOTAL = 988
) (
    input wire clk, resetn, ce, hblank, vblank,
    input wire [11:0] rgb,
    input wire v30, pal,
    input wire clk_pixel, pixel_resetn,
    input wire [1:0] zoom, scanline,
    input wire overlay,
    input wire [23:0] overlay_rgb,
    output wire [10:0] osd_x,
    output wire [9:0] osd_y,
    output wire osd_de,
    output reg [23:0] out_rgb,
    output reg hs, vs, de,
    output reg [10:0] pixel_x,
    output reg [9:0] pixel_y,
    output wire [9:0] frame_height
);
    (* syn_ramstyle = "block_ram" *) reg [11:0] lines [0:1023];
    reg blank_d = 1, vblank_d = 1, line_vblank = 1, ce_d = 0;
    reg bank = 0, line_toggle = 0;
    reg [8:0] write_x = 0;
    reg line_h40 = 0;
    reg frame_pending = 1, line_first = 0, line_valid = 0;
    integer i;
    initial for (i = 0; i < 1024; i = i + 1) lines[i] = 0;
    always @(posedge clk) begin
        blank_d <= hblank;
        vblank_d <= vblank;
        ce_d <= ce;
        if (line_start) line_vblank <= vblank;
        if (!resetn) begin
            write_x <= 0;
            bank <= 0;
            line_toggle <= 0;
            frame_pending <= 1;
            line_first <= 0;
            line_valid <= 0;
            line_vblank <= 1;
        end else begin
            if (vblank_d && !vblank) frame_pending <= 1;
            if (ce_d && !hblank && line_active && write_x < 320) begin
                lines[{bank, write_x}] <= rgb;
                write_x <= write_x + 1'b1;
            end
            if (hblank && !blank_d) begin
                line_h40 <= write_x > 256;
                line_valid <= write_x != 0;
                line_first <= frame_pending && write_x != 0;
                if (write_x != 0) frame_pending <= 0;
                write_x <= 0;
                bank <= ~bank;
                line_toggle <= ~line_toggle;
            end
        end
    end

    reg [2:0] sync_line = 0, sync_bank = 0;
    reg [1:0] zoom_meta = 0, zoom_pix = 0, scan_meta = 0, scan_pix = 0;
    reg first_meta = 0, valid_meta = 0, h40_meta = 0;
    reg v30_meta = 0, v30_pix = 0, pal_meta = 0, pal_pix = 0;
    reg frame_long = 1;
    reg [8:0] source_lines = 0;
    reg frame_seen = 0;
    reg [10:0] x = 0;
    reg [9:0] y = 0;
    reg half = 0, read_valid = 0, read_bank = 0;
    reg read_h40 = 0;
    wire [8:0] read_width = read_h40 ? 9'd320 : 9'd256;
    reg [8:0] source = 0;
    reg [2:0] fraction = 0;
    wire integer_256 = zoom_pix == 0 && read_width <= 256;
    wire game_window = x >= (integer_256 ? 11'd64 : 11'd0) &&
                       x < (integer_256 ? 11'd576 : 11'd640);
    reg [11:0] read_rgb;
    reg [2:0] active_pipe = 0, hs_pipe = 0, vs_pipe = 0, game_pipe = 0, dark_pipe = 0;
    reg [10:0] x0, x1, x2;
    reg [9:0] y0, y1, y2;
    reg [11:0] color0, color1;
    wire line_event = sync_line[2] ^ sync_line[1];
    wire line_start = !hblank && blank_d;
    wire line_active = line_start ? !vblank : !line_vblank;
    localparam [10:0] X_LAST = H_TOTAL - 1;
    // A console line normally arrives LOCK_LEAD pixels before a pair starts;
    // anything outside the window forces a resynchronization.
    localparam [10:0] LOCK_LEAD = 12;
    localparam [10:0] LOCK_WINDOW = 24;
    reg event_pending = 0;
    wire line_end = x == X_LAST;
    wire event_locked = half && x >= H_TOTAL - LOCK_WINDOW;
    wire apply_line = line_end && half && (event_pending || line_event);
    wire [9:0] next_y = y == frame_height - 1'b1 ? 10'd0 : y + 1'b1;
    wire next_frame_long = frame_seen && first_meta ? source_lines[0] : frame_long;
    wire [9:0] frame_height_now = pal_pix ?
                                  (next_frame_long ? 10'd626 : 10'd624) :
                                  (next_frame_long ? 10'd526 : 10'd524);
    assign osd_x = x;
    assign osd_y = y;
    assign osd_de = x < 640 && y < 480;
    assign frame_height = frame_height_now;

    function [7:0] attenuate(input [3:0] color, input dark, input [1:0] strength);
        reg [7:0] value;
        begin
            value = {color, color};
            case (dark ? strength : 2'b0)
                1: attenuate = value - (value >> 2);
                2: attenuate = value >> 1;
                3: attenuate = 0;
                default: attenuate = value;
            endcase
        end
    endfunction
    always @(posedge clk_pixel) begin
        sync_line <= {sync_line[1:0], line_toggle};
        sync_bank <= {sync_bank[1:0], bank};
        first_meta <= line_first;
        valid_meta <= line_valid;
        h40_meta <= line_h40;
        zoom_meta <= zoom;
        zoom_pix <= zoom_meta;
        scan_meta <= scanline;
        scan_pix <= scan_meta;
        v30_meta <= v30;
        v30_pix <= v30_meta;
        pal_meta <= pal;
        pal_pix <= pal_meta;
        if (line_event) event_pending <= 1;
        if (line_event && !event_locked) begin
            x <= H_TOTAL - LOCK_LEAD;
            y[0] <= 1'b1;
            half <= 1;
        end else if (line_end) begin
            x <= 0;
            half <= ~half;
            y <= next_y;
            if (apply_line) begin
                event_pending <= 0;
                read_bank <= ~sync_bank[1];
                // Source fields stay unchanged for the whole console line, so
                // sampling them a few pixels after the event is safe.
                read_h40 <= h40_meta;
                read_valid <= valid_meta;
                if (frame_seen) source_lines <= source_lines + 1'b1;
                if (first_meta) begin
                    y <= v30_pix ? 10'd0 : 10'd16;
                    if (frame_seen)
                        frame_long <= source_lines[0];
                    source_lines <= 1;
                    frame_seen <= 1;
                end
            end
        end else x <= x + 1'b1;
        if (line_end || !game_window) begin
            source <= 0;
            fraction <= 0;
        end else if (game_window) begin
            if (read_width <= 256 && zoom_pix != 0) begin
                // Five output pixels cover two input pixels: repeat 3, then 2.
                if (fraction == 2 || fraction == 4) source <= source + 1'b1;
                fraction <= fraction == 4 ? 0 : fraction + 1'b1;
            end else begin
                if (fraction[0]) source <= source + 1'b1;
                fraction <= {2'b0, ~fraction[0]};
            end
        end
        read_rgb <= lines[{read_bank, source}];
        active_pipe <= {active_pipe[1:0], osd_de};
        hs_pipe <= {hs_pipe[1:0], x >= 664 && x < 760};
        vs_pipe <= {vs_pipe[1:0], y >= 490 && y < 496};
        game_pipe <= {game_pipe[1:0], game_window && read_valid && source < read_width};
        dark_pipe <= {dark_pipe[1:0], half};
        x0 <= x;
        x1 <= x0;
        x2 <= x1;
        y0 <= y;
        y1 <= y0;
        y2 <= y1;
        pixel_x <= x2;
        pixel_y <= y2;
        de <= active_pipe[2];
        hs <= hs_pipe[2];
        vs <= vs_pipe[2];
        if (overlay) out_rgb <= overlay_rgb;
        else out_rgb <= {
            attenuate(color1[11:8], dark_pipe[2], scan_pix),
            attenuate(color1[7:4], dark_pipe[2], scan_pix),
            attenuate(color1[3:0], dark_pipe[2], scan_pix)};
        color1 <= color0;
        if (game_pipe[0]) color0 <= read_rgb;
        else color0 <= 0;
        if (!pixel_resetn) begin
            x <= 0;
            y <= 0;
            half <= 0;
            event_pending <= 0;
            active_pipe <= 0;
            read_valid <= 0;
            frame_seen <= 0;
            source_lines <= 0;
            frame_long <= 1;
            out_rgb <= 0;
            de <= 0;
        end
    end
endmodule
