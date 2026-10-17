module snes_pause_frame (
    input wire clk,
    input wire resetn,
    input wire running,
    input wire pause,
    input wire dotclk,
    input wire hblank,
    input wire vblank,
    input wire [8:0] xs,
    input wire [8:0] ys,
    input wire [14:0] rgb,
    output wire hold_core,
    output wire ready,
    input wire display_active,
    input wire row_request,
    output reg memory_req,
    input wire memory_ack,
    output wire memory_we,
    output wire [15:0] memory_address,
    output wire [14:0] memory_data,
    input wire [14:0] memory_q,
    output wire buffer_write,
    output wire [9:0] buffer_address,
    output wire [2:0] buffer_bank,
    output wire [14:0] buffer_data
);

localparam IDLE = 3'd0, WAIT_BLANK = 3'd1, WAIT_FRAME = 3'd2,
           CAPTURE = 3'd3, PREFILL = 3'd4, PLAY = 3'd5, RELEASE = 3'd6;
reg [2:0] state;
reg dot_previous;
reg captured;
reg row_active;
reg reading;
reg [7:0] read_x, read_y;
reg [1:0] read_group;
reg [2:0] read_slot;
reg row_pending;
reg row_meta, row_sync, row_seen;
reg display_meta, display_sync;
wire memory_idle = memory_req == memory_ack;
wire capture_pixel = dotclk && !dot_previous && !hblank && !vblank && ys[7:0] < 224;
wire playing = state == PREFILL || state == PLAY;
wire row_edge = state == PLAY && row_sync != row_seen;
wire read_done = playing && memory_idle && reading;

// While the core is held, the PPU outputs stay unchanged until SDRAM acknowledges them.
assign hold_core = state >= PREFILL ||
                   (state == CAPTURE && (!memory_idle || capture_pixel));
assign ready = state == PLAY && pause && running;
assign memory_we = state == CAPTURE;
assign memory_address = memory_we ? {ys[7:0], xs[8:1]} : {read_y, read_x};
assign memory_data = rgb;
assign buffer_write = read_done;
assign buffer_address = {read_slot, read_x[7:1]};
assign buffer_bank = {read_group, read_x[0]};
assign buffer_data = memory_q;

always @(posedge clk) begin
    dot_previous <= dotclk;
    row_meta <= row_request;
    row_sync <= row_meta;
    display_meta <= display_active;
    display_sync <= display_meta;
    if (!resetn) begin
        state <= IDLE;
        memory_req <= 0;
        captured <= 0;
        row_active <= 0;
        reading <= 0;
        read_x <= 0;
        read_y <= 0;
        read_group <= 0;
        read_slot <= 0;
        row_pending <= 0;
        row_seen <= 0;
    end else if ((!pause || !running) && state != IDLE && state != RELEASE) begin
        // Drain the toggle handshake before abandoning a capture or a read.
        if (memory_idle) begin
            state <= RELEASE;
            row_active <= 0;
            reading <= 0;
            row_pending <= 0;
        end
    end else begin
        case (state)
            IDLE: if (pause && running)
                state <= WAIT_BLANK;
            WAIT_BLANK: if (vblank)
                state <= WAIT_FRAME;
            WAIT_FRAME: if (!vblank) begin
                captured <= 0;
                state <= CAPTURE;
            end
            CAPTURE: if (memory_idle) begin
                if (captured && vblank) begin
                    read_x <= 0;
                    read_y <= 0;
                    read_group <= 0;
                    read_slot <= 0;
                    row_active <= 0;
                    reading <= 0;
                    row_pending <= 1;
                    state <= PREFILL;
                end else if (capture_pixel) begin
                    memory_req <= ~memory_req;
                    if (ys[7:0] == 223 && xs[8:1] == 255)
                        captured <= 1;
                end
            end
            PREFILL, PLAY: begin
                row_seen <= row_sync;
                if (read_done) begin
                    reading <= 0;
                    if (read_x == 255) begin
                        row_active <= 0;
                        read_x <= 0;
                        read_y <= read_y == 223 ? 8'd0 : read_y + 1'b1;
                        read_group <= read_y == 223 || read_group == 2 ? 2'd0 : read_group + 1'b1;
                        if (read_y == 223)
                            read_slot <= 0;
                        else if (read_group == 2)
                            read_slot <= read_slot + 1'b1;
                        if (state == PREFILL) begin
                            if (read_y == 1) begin
                                state <= PLAY;
                                row_pending <= 0;
                            end else
                                row_pending <= 1;
                        end else if (row_edge)
                            row_pending <= 1;
                    end else begin
                        read_x <= read_x + 1'b1;
                        if (row_edge)
                            row_pending <= 1;
                    end
                end else if (memory_idle && (row_active || row_pending)) begin
                    memory_req <= ~memory_req;
                    reading <= 1;
                    row_active <= 1;
                    row_pending <= row_active && (row_pending || row_edge);
                end else if (row_edge)
                    row_pending <= 1;
            end
            RELEASE: if (memory_idle && !display_sync) begin
                state <= IDLE;
                row_seen <= row_sync;
            end
            default: state <= IDLE;
        endcase
    end
end
endmodule
