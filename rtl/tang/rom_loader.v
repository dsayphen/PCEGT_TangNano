//
// HuCard ROM loader over UART for the Tang Nano 20K PC Engine port.
//
// Wire protocol (little endian, no handshaking, no checksum):
//
//   offset  size  content
//   ------  ----  ---------------------------------------------------------
//   0       4     magic  0x50 0x43 0x45 0x01  ("PCE" + protocol version 1)
//   4       4     image size in bytes, little endian (1 .. 4 MiB)
//   8       N     the raw .pce / .bin image, byte for byte
//
// The loader resynchronises on the magic at any time, so a failed transfer can
// simply be repeated.  If more than ~1 second passes between two payload bytes
// the transfer is aborted and the loader returns to looking for the magic.
//
// The image is written to SDRAM starting at byte address 0, header included.
// When the transfer completes the loader publishes
//
//   rom_sz     = size >> 16          (the ROM size code expected by pce_top)
//   rom_offset = 512 when the image carries the classic 512 byte .pce header
//                (size & 0x3FF == 0x200), 0 otherwise
//
// which matches what the MiST/MiSTer top level derives from ioctl_addr.
//
// `loading` is held high for the whole transfer; the top level keeps the core
// in reset while it is asserted.
//

module rom_loader #(
    parameter CLK_FREQ  = 43_200_000,
    parameter BAUD_RATE = 115200,
    parameter MAX_SIZE  = 32'h0040_0000   // 4 MiB
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        rx,

    // SDRAM write port
    output reg         ld_wr,
    output reg  [22:0] ld_addr,
    output reg  [7:0]  ld_data,
    input  wire        ld_busy,

    // status / ROM description
    output reg         loading,
    output reg         image_valid,
    output reg  [7:0]  rom_sz,
    output reg  [22:0] rom_offset,
    output reg         rx_activity      // toggles on every received byte
);

wire [7:0] rx_data;
wire       rx_valid;

uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) urx (
    .clk    (clk),
    .resetn (resetn),
    .rx     (rx),
    .data   (rx_data),
    .valid  (rx_valid)
);

localparam S_SYNC  = 3'd0;
localparam S_LEN   = 3'd1;
localparam S_DATA  = 3'd2;
localparam S_WRITE = 3'd3;
localparam S_DONE  = 3'd4;

// ~1 s of silence aborts a transfer in progress
localparam [31:0] TIMEOUT = CLK_FREQ;

reg  [2:0]  state;
reg  [31:0] magic;
reg  [31:0] length;
reg  [31:0] count;
reg  [1:0]  lenbyte;
reg  [22:0] wr_ptr;
reg  [31:0] timeout;

always @(posedge clk) begin
    ld_wr <= 1'b0;

    if (rx_valid) begin
        magic      <= {magic[23:0], rx_data};
        timeout    <= 32'd0;
        rx_activity <= ~rx_activity;
    end else if (timeout != TIMEOUT) begin
        timeout <= timeout + 32'd1;
    end

    case (state)
        // ------------------------------------------------ look for the magic
        S_SYNC: begin
            if (rx_valid && ({magic[23:0], rx_data} == 32'h5043_4501)) begin
                state   <= S_LEN;
                lenbyte <= 2'd0;
                length  <= 32'd0;
            end
        end

        // ------------------------------------------------ 32 bit size, LE
        S_LEN: begin
            if (rx_valid) begin
                case (lenbyte)
                    2'd0: length[7:0]   <= rx_data;
                    2'd1: length[15:8]  <= rx_data;
                    2'd2: length[23:16] <= rx_data;
                    2'd3: length[31:24] <= rx_data;
                endcase
                if (lenbyte == 2'd3) begin
                    state <= S_DATA;
                end else begin
                    lenbyte <= lenbyte + 2'd1;
                end
            end
            if (timeout == TIMEOUT)
                state <= S_SYNC;
        end

        // ------------------------------------------------ payload
        S_DATA: begin
            if (!loading) begin
                // first cycle in this state: validate the announced size
                if (length == 32'd0 || length > MAX_SIZE) begin
                    state <= S_SYNC;
                end else begin
                    loading     <= 1'b1;
                    image_valid <= 1'b0;
                    wr_ptr      <= 23'd0;
                    count       <= 32'd0;
                end
            end else if (rx_valid) begin
                ld_data <= rx_data;
                state   <= S_WRITE;
            end else if (timeout == TIMEOUT) begin
                // transfer stalled - give up and wait for a new magic
                loading <= 1'b0;
                state   <= S_SYNC;
            end
        end

        // ------------------------------------------------ push byte to SDRAM
        // ld_addr and ld_wr must become valid in the same clock, so the
        // address is taken from wr_ptr instead of being pre-incremented.
        S_WRITE: begin
            if (!ld_busy && !ld_wr) begin
                ld_wr   <= 1'b1;
                ld_addr <= wr_ptr;
                wr_ptr  <= wr_ptr + 23'd1;
                count   <= count + 32'd1;
                if (count + 32'd1 == length)
                    state <= S_DONE;
                else
                    state <= S_DATA;
            end
        end

        // ------------------------------------------------ publish the result
        S_DONE: begin
            rom_sz      <= length[23:16];
            rom_offset  <= (length[9:0] == 10'h200) ? 23'd512 : 23'd0;
            image_valid <= 1'b1;
            loading     <= 1'b0;
            state       <= S_SYNC;
        end

        default: state <= S_SYNC;
    endcase

    if (!resetn) begin
        state       <= S_SYNC;
        magic       <= 32'd0;
        length      <= 32'd0;
        count       <= 32'd0;
        lenbyte     <= 2'd0;
        timeout     <= 32'd0;
        ld_wr       <= 1'b0;
        ld_addr     <= 23'd0;
        wr_ptr      <= 23'd0;
        ld_data     <= 8'd0;
        loading     <= 1'b0;
        image_valid <= 1'b0;
        rom_sz      <= 8'd0;
        rom_offset  <= 23'd0;
        rx_activity <= 1'b0;
    end
end

endmodule
