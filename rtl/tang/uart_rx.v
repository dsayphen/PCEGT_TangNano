//
// Minimal 8N1 UART receiver (receive only, no flow control).
//
// The sample point is the middle of each bit cell; the start bit is validated
// half a bit time after the falling edge so that a glitch on the line does not
// start a frame.
//

module uart_rx #(
    parameter CLK_FREQ  = 43_200_000,
    parameter BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       rx,          // asynchronous serial input
    output reg  [7:0] data,
    output reg        valid        // single cycle strobe
);

localparam integer DIVISOR   = CLK_FREQ / BAUD_RATE;
localparam integer HALF_DIV  = DIVISOR / 2;
localparam integer CNT_WIDTH = 16;

// input synchroniser
reg [2:0] rx_sync;
wire      rx_s = rx_sync[2];

reg [CNT_WIDTH-1:0] cnt;
reg [3:0]           bitno;
reg [7:0]           shifter;
reg [1:0]           state;

localparam S_IDLE  = 2'd0;
localparam S_START = 2'd1;
localparam S_DATA  = 2'd2;
localparam S_STOP  = 2'd3;

always @(posedge clk) begin
    rx_sync <= {rx_sync[1:0], rx};
    valid   <= 1'b0;

    case (state)
        S_IDLE: begin
            cnt <= 0;
            if (!rx_s) begin
                state <= S_START;
                cnt   <= 0;
            end
        end

        S_START: begin
            if (cnt == HALF_DIV[CNT_WIDTH-1:0] - 1) begin
                cnt <= 0;
                if (!rx_s) begin
                    state <= S_DATA;
                    bitno <= 4'd0;
                end else begin
                    state <= S_IDLE;    // glitch
                end
            end else begin
                cnt <= cnt + 1'b1;
            end
        end

        S_DATA: begin
            if (cnt == DIVISOR[CNT_WIDTH-1:0] - 1) begin
                cnt     <= 0;
                shifter <= {rx_s, shifter[7:1]};
                if (bitno == 4'd7)
                    state <= S_STOP;
                else
                    bitno <= bitno + 4'd1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end

        S_STOP: begin
            if (cnt == DIVISOR[CNT_WIDTH-1:0] - 1) begin
                cnt <= 0;
                // only accept the byte when the stop bit is really there
                if (rx_s) begin
                    data  <= shifter;
                    valid <= 1'b1;
                end
                state <= S_IDLE;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    endcase

    if (!resetn) begin
        state   <= S_IDLE;
        cnt     <= 0;
        bitno   <= 4'd0;
        valid   <= 1'b0;
        rx_sync <= 3'b111;
    end
end

endmodule
