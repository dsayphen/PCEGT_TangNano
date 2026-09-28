// One-frame raw-video snapshot over the PicoRV32 SDRAM port.
// Pixels are stored as three 9-bit RGB samples per 32-bit word.
module frame_snapshot #(
    parameter [22:0] BASE_ADDR = 23'h57_0000,
    parameter [15:0] MAX_WORDS = 16'd49152
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        capture_start,
    input  wire        capture_supported,
    input  wire        paused,
    input  wire        video_ce,
    input  wire        video_vs,
    input  wire        video_vbl,
    input  wire        video_hbl,
    input  wire [8:0]  video_rgb,
    input  wire [15:0] video_mode,
    output wire        busy,
    output reg         frame_valid,
    output reg         failed,
    output reg  [3:0]  failure_reason,
    output wire        video_override,
    output wire [8:0]  snapshot_rgb,
    output reg  [17:0] frame_pixels,
    output wire        mem_valid,
    output wire        mem_write,
    output wire [22:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata
);

localparam [2:0] ST_IDLE    = 3'd0;
localparam [2:0] ST_WAIT_VS = 3'd1;
localparam [2:0] ST_CAPTURE = 3'd2;
localparam [2:0] ST_DRAIN   = 3'd3;
localparam [2:0] ST_VALID   = 3'd4;
localparam [17:0] MAX_PIXELS = {MAX_WORDS, 2'b00} - {MAX_WORDS, 2'b00} / 4;

reg [2:0] state;
reg       video_vs_d;
reg [1:0] pack_count;
reg [8:0] pack_pixel0;
reg [8:0] pack_pixel1;
reg [31:0] write_word;
reg        write_pending;
reg [15:0] write_index;
reg [17:0] capture_pixels;
reg [15:0] capture_mode;
reg        capture_mode_valid;
reg        capture_mode_mismatch;
reg        capture_queued;
reg        queued_supported;

reg        read_pending;
reg [15:0] read_index;
reg [31:0] read_word;
reg        read_word_valid;
reg [31:0] play_shift;
reg [1:0]  play_subpixel;
reg [17:0] play_pixels;
reg        display_active;

wire video_vs_rise = video_vs && !video_vs_d;
wire capture_pixel = video_ce && !video_hbl && !video_vbl;
wire [15:0] words_per_frame = (frame_pixels + 18'd2) / 18'd3;
wire read_prefetch = state == ST_VALID && paused && !video_vs_rise &&
                     !read_pending && read_index < words_per_frame &&
                     (!read_word_valid ||
                      (display_active && capture_pixel &&
                       play_subpixel == 2'd0));

assign busy = capture_queued || (state == ST_WAIT_VS) ||
              (state == ST_CAPTURE) || (state == ST_DRAIN);
assign video_override = paused && frame_valid && display_active;
assign snapshot_rgb = (play_subpixel == 2'd0) ? read_word[8:0] :
                                                   play_shift[8:0];
assign mem_valid = write_pending || read_pending;
assign mem_write = write_pending;
assign mem_addr = BASE_ADDR +
                  {(write_pending ? write_index : read_index), 2'b00};
assign mem_wdata = write_word;
assign mem_wstrb = 4'b1111;

always @(posedge clk) begin
    video_vs_d <= video_vs;

    if (!resetn) begin
        state            <= ST_IDLE;
        frame_valid      <= 1'b0;
        failed           <= 1'b0;
        failure_reason   <= 4'd0;
        frame_pixels     <= 18'd0;
        pack_count       <= 2'd0;
        pack_pixel0      <= 9'd0;
        pack_pixel1      <= 9'd0;
        write_word       <= 32'd0;
        write_pending    <= 1'b0;
        write_index      <= 16'd0;
        capture_pixels   <= 18'd0;
        capture_mode     <= 16'd0;
        capture_mode_valid <= 1'b0;
        capture_mode_mismatch <= 1'b0;
        capture_queued   <= 1'b0;
        queued_supported <= 1'b0;
        read_pending     <= 1'b0;
        read_index       <= 16'd0;
        read_word        <= 32'd0;
        read_word_valid  <= 1'b0;
        play_shift       <= 32'd0;
        play_subpixel    <= 2'd0;
        play_pixels      <= 18'd0;
        display_active   <= 1'b0;
    end else begin
        if (mem_valid && mem_ready) begin
            if (write_pending) begin
                write_pending <= 1'b0;
                write_index   <= write_index + 16'd1;
            end else if (read_pending) begin
                read_pending    <= 1'b0;
                read_word      <= mem_rdata;
                read_word_valid <= 1'b1;
                read_index     <= read_index + 16'd1;
            end
        end

        if (!paused)
            display_active <= 1'b0;

        if (capture_start) begin
            frame_valid    <= 1'b0;
            failed         <= 1'b0;
            failure_reason <= 4'd0;
            display_active <= 1'b0;
            read_word_valid <= 1'b0;
            capture_queued <= 1'b1;
            queued_supported <= capture_supported;
        end else begin
            if (capture_queued && !read_pending && !write_pending) begin
                capture_queued <= 1'b0;
                read_index <= 16'd0;
                write_index <= 16'd0;
                capture_pixels <= 18'd0;
                frame_pixels <= 18'd0;
                pack_count <= 2'd0;
                capture_mode_valid <= 1'b0;
                capture_mode_mismatch <= 1'b0;
                if (queued_supported)
                    state <= ST_WAIT_VS;
                else begin
                    state <= ST_IDLE;
                    failed <= 1'b1;
                    failure_reason <= 4'd1;
                end
            end

            if (!capture_queued) case (state)
                ST_WAIT_VS: begin
                    if (video_vs_rise) begin
                        capture_pixels <= 18'd0;
                        pack_count <= 2'd0;
                        capture_mode_valid <= 1'b0;
                        capture_mode_mismatch <= 1'b0;
                        state <= ST_CAPTURE;
                    end
                end

                ST_CAPTURE: begin
                    if (video_vs_rise) begin
                        frame_pixels <= capture_pixels;
                        if (capture_pixels == 18'd0 ||
                            capture_mode_mismatch ||
                            (pack_count != 2'd0 && write_pending &&
                             !(mem_valid && mem_ready && mem_write))) begin
                            if (!failed) begin
                                if (capture_pixels == 18'd0)
                                    failure_reason <= 4'd2;
                                else if (capture_mode_mismatch)
                                    failure_reason <= 4'd3;
                                else
                                    failure_reason <= 4'd4;
                            end
                            frame_valid <= 1'b0;
                            failed <= 1'b1;
                            pack_count <= 2'd0;
                            state <= write_pending ? ST_DRAIN : ST_IDLE;
                        end else begin
                            if (pack_count == 2'd1) begin
                                write_word <= {23'd0, pack_pixel0};
                                write_pending <= 1'b1;
                            end else if (pack_count == 2'd2) begin
                                write_word <= {5'd0, pack_pixel1, pack_pixel0};
                                write_pending <= 1'b1;
                            end
                            pack_count <= 2'd0;
                            state <= ST_DRAIN;
                        end
                    end else if (capture_pixel) begin
                        if (!capture_mode_valid) begin
                            capture_mode <= video_mode;
                            capture_mode_valid <= 1'b1;
                        end else if (capture_mode != video_mode) begin
                            capture_mode_mismatch <= 1'b1;
                        end
                        if (capture_pixels >= MAX_PIXELS ||
                            (pack_count == 2'd2 && write_index >= MAX_WORDS) ||
                            (pack_count == 2'd2 && write_pending &&
                             !(mem_valid && mem_ready && mem_write))) begin
                            frame_valid <= 1'b0;
                            failed <= 1'b1;
                            if (!failed)
                                failure_reason <= 4'd5;
                            pack_count <= 2'd0;
                            state <= ST_DRAIN;
                        end else begin
                            capture_pixels <= capture_pixels + 18'd1;
                            case (pack_count)
                                2'd0: begin
                                    pack_pixel0 <= video_rgb;
                                    pack_count <= 2'd1;
                                end
                                2'd1: begin
                                    pack_pixel1 <= video_rgb;
                                    pack_count <= 2'd2;
                                end
                                default: begin
                                    write_word <= {5'd0, video_rgb,
                                                   pack_pixel1, pack_pixel0};
                                    write_pending <= 1'b1;
                                    pack_count <= 2'd0;
                                end
                            endcase
                        end
                    end
                end

                ST_DRAIN: begin
                    if (!write_pending && pack_count == 2'd0) begin
                        if (failed) begin
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_VALID;
                            frame_valid <= 1'b1;
                        end
                    end
                end

                ST_VALID: begin
                    if (video_vs_rise && paused) begin
                        if (display_active && play_pixels != frame_pixels) begin
                            frame_valid <= 1'b0;
                            display_active <= 1'b0;
                            failed <= 1'b1;
                            if (!failed)
                                failure_reason <= 4'd6;
                        end else if (!display_active && read_word_valid) begin
                            if (capture_mode != video_mode) begin
                                frame_valid <= 1'b0;
                                failed <= 1'b1;
                                if (!failed)
                                    failure_reason <= 4'd7;
                            end else begin
                                display_active <= 1'b1;
                            end
                        end

                        if (display_active) begin
                            read_index <= 16'd0;
                            read_word_valid <= 1'b0;
                        end
                        play_pixels <= 18'd0;
                        play_subpixel <= 2'd0;
                    end else if (capture_pixel && paused && display_active) begin
                        if (play_pixels >= frame_pixels) begin
                            frame_valid <= 1'b0;
                            display_active <= 1'b0;
                            failed <= 1'b1;
                            if (!failed)
                                failure_reason <= 4'd9;
                        end else if (play_subpixel == 2'd0) begin
                            if (read_word_valid) begin
                                play_shift <= read_word >> 9;
                                read_word_valid <= 1'b0;
                                play_subpixel <= 2'd1;
                                play_pixels <= play_pixels + 18'd1;
                            end else begin
                                frame_valid <= 1'b0;
                                display_active <= 1'b0;
                                failed <= 1'b1;
                                if (!failed)
                                    failure_reason <= 4'd8;
                            end
                        end else begin
                            play_shift <= play_shift >> 9;
                            play_subpixel <= (play_subpixel == 2'd2) ?
                                             2'd0 : play_subpixel + 2'd1;
                            play_pixels <= play_pixels + 18'd1;
                        end
                    end

                    if (video_vs_rise && !paused) begin
                        read_index <= 16'd0;
                        read_word_valid <= 1'b0;
                    end
                end

                default: ;
            endcase

            if (read_prefetch)
                read_pending <= 1'b1;
        end
    end
end

endmodule