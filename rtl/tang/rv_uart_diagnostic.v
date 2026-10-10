module rv_uart_diagnostic #(
    parameter FREQ = 43_200_000,
    parameter WAIT_CYCLES = FREQ / 100,
    parameter REPORT_CYCLES = FREQ,
    parameter TRACE_ENABLE = 1,
    parameter X22_ENABLE = 0,
    parameter STACK_ENABLE = 0
) (
    input wire clk,
    input wire resetn,
    input wire [127:0] snapshot,
    input wire [127:0] x22_snapshot,
    input wire [7:0] extra_tag,
    input wire [127:0] stack_snapshot,
    input wire [127:0] transaction,
    input wire waiting,
    input wire completed,
    input wire trap,
    input wire uart_busy,
    output wire owned,
    output wire write_byte,
    output reg [7:0] byte_data
);
reg [31:0] wait_count;
reg [31:0] idle_count;
reg [31:0] report_count;
reg [2:0] reasons;
reg trap_seen;
reg pending;
reg sending;
reg byte_sent;
reg [5:0] byte_index;
reg [127:0] saved_snapshot;
reg [3:0] saved_reason;
reg [127:0] saved_x22;
reg x22_frame;
reg [7:0] saved_extra_tag;
reg [127:0] saved_stack;
reg stack_frame;
reg [127:0] trace_history [0:7];
reg [2:0] trace_write_index;
reg [3:0] trace_count;
reg trace_frozen;
reg trace_dump_pending;
reg trace_frame;
reg [2:0] trace_read_index;
reg [3:0] trace_remaining;
wire wait_event = waiting && wait_count == WAIT_CYCLES - 1;
wire idle_event = !completed && idle_count == WAIT_CYCLES - 1;
wire trap_event = trap && !trap_seen;
wire report_event = report_count == REPORT_CYCLES - 1;
wire freeze_event = TRACE_ENABLE != 0 && !trace_frozen && trace_count != 0 &&
                    (wait_event || trap_event);
wire [3:0] hex_value = byte_index == 6 ? saved_reason :
                       saved_snapshot >> ((39 - byte_index) * 4);

assign owned = sending || pending;
assign write_byte = sending && !byte_sent && !uart_busy;

always @* begin
    case (byte_index)
        0: byte_data = 8'h0d;
        1: byte_data = 8'h0a;
        2: byte_data = "R";
        3: byte_data = "V";
        4: byte_data = stack_frame ? "S" : x22_frame ? saved_extra_tag : trace_frame ? "T" : "D";
        5, 7: byte_data = " ";
        40: byte_data = 8'h0d;
        41: byte_data = 8'h0a;
        default: byte_data = hex_value < 10 ? 8'h30 + hex_value : 8'h61 + hex_value - 10;
    endcase
end

always @(posedge clk) begin
    if (!resetn) begin
        wait_count <= 0;
        idle_count <= 0;
        report_count <= 0;
        reasons <= 0;
        trap_seen <= 0;
        pending <= 0;
        sending <= 0;
        byte_sent <= 0;
        byte_index <= 0;
        saved_snapshot <= 0;
        saved_reason <= 0;
        saved_x22 <= 0;
        saved_extra_tag <= "X";
        saved_stack <= 0;
        stack_frame <= 0;
        x22_frame <= 0;
        trace_write_index <= 0;
        trace_count <= 0;
        trace_frozen <= 0;
        trace_dump_pending <= 0;
        trace_frame <= 0;
        trace_read_index <= 0;
        trace_remaining <= 0;
    end else begin
        if (trace_frozen && !owned && !trace_dump_pending && completed && !waiting && !trap) begin
            trace_frozen <= 0;
            trace_count <= 0;
            trace_write_index <= 0;
        end
        if (TRACE_ENABLE != 0 && completed && !trace_frozen && !freeze_event) begin
            trace_history[trace_write_index] <= transaction;
            trace_write_index <= trace_write_index + 3'd1;
            if (trace_count < 8)
                trace_count <= trace_count + 4'd1;
        end
        if (freeze_event) begin
            trace_frozen <= 1;
            trace_dump_pending <= 1;
        end
        if (!waiting)
            wait_count <= 0;
        else if (wait_count < WAIT_CYCLES)
            wait_count <= wait_count + 1;
        if (completed || owned)
            idle_count <= 0;
        else if (idle_count < WAIT_CYCLES)
            idle_count <= idle_count + 1;
        report_count <= report_event ? 0 : report_count + 1;
        trap_seen <= trap;
        reasons <= reasons | {trap_event, idle_event, wait_event};
        if (!owned && (wait_event || idle_event || trap_event || report_event)) begin
            saved_snapshot <= snapshot;
            saved_x22 <= x22_snapshot;
            saved_extra_tag <= extra_tag;
            saved_stack <= stack_snapshot;
            saved_reason <= {1'b0, reasons | {trap_event, idle_event, wait_event}};
            reasons <= 0;
            pending <= 1;
        end
        if (pending && !uart_busy) begin
            pending <= 0;
            sending <= 1;
            byte_index <= 0;
            byte_sent <= 0;
            trace_frame <= 0;
            x22_frame <= 0;
            stack_frame <= 0;
        end
        if (write_byte)
            byte_sent <= 1;
        if (sending && byte_sent && !uart_busy) begin
            byte_sent <= 0;
            if (byte_index == 41) begin
                if (!trace_frame && !x22_frame && !stack_frame && X22_ENABLE != 0) begin
                    x22_frame <= 1;
                    saved_snapshot <= saved_x22;
                    saved_reason <= 0;
                    byte_index <= 0;
                end else if (!trace_frame && !stack_frame && STACK_ENABLE != 0) begin
                    x22_frame <= 0;
                    stack_frame <= 1;
                    saved_snapshot <= saved_stack;
                    saved_reason <= 0;
                    byte_index <= 0;
                end else if (!trace_frame && trace_dump_pending) begin
                    stack_frame <= 0;
                    x22_frame <= 0;
                    trace_dump_pending <= 0;
                    trace_frame <= 1;
                    trace_remaining <= trace_count;
                    trace_read_index <= trace_write_index - trace_count[2:0];
                    saved_snapshot <= trace_history[trace_write_index - trace_count[2:0]];
                    saved_reason <= 0;
                    byte_index <= 0;
                end else if (trace_frame && trace_remaining > 1) begin
                    trace_remaining <= trace_remaining - 4'd1;
                    trace_read_index <= trace_read_index + 3'd1;
                    saved_snapshot <= trace_history[trace_read_index + 3'd1];
                    saved_reason <= saved_reason + 4'd1;
                    byte_index <= 0;
                end else begin
                    sending <= 0;
                    stack_frame <= 0;
                    trace_frame <= 0;
                    x22_frame <= 0;
                end
            end else
                byte_index <= byte_index + 1;
        end
    end
end
endmodule