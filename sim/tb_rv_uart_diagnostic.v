`timescale 1ns/1ps
module tb_rv_uart_diagnostic #(
    parameter TRACE_ENABLE = 0,
    parameter X22_ENABLE = 0,
    parameter STACK_ENABLE = 0,
    parameter READ_PATH_ENABLE = 0,
    parameter HISTORY_DEPTH = 8
);
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg diagnostic_enabled = 0;
reg waiting = 0;
reg completed = 0;
reg trap = 0;
reg firmware_write = 0;
wire busy;
wire owned;
wire write_byte;
wire [7:0] byte_data;
wire serial;
localparam [127:0] SNAPSHOT = 128'h01234567_89abcdef_fedcba98_76543210;
reg [7:0] received [0:1023];
reg [127:0] transaction = 0;
reg [95:0] read_path = 0;
reg [127:0] x22_snapshot = 128'h00001234_12345678_03c003c0_0019ff80;
reg [127:0] stack_snapshot = 128'h00018000_03c003c0_f0000001_00000001;
reg [127:0] expected_trace [0:7];
reg [127:0] expected_read_path [0:7];
localparam TRACE_STRIDE = READ_PATH_ENABLE != 0 ? 84 : 42;
localparam TRACE_BASE = 42 * (1 + (X22_ENABLE != 0) + (STACK_ENABLE != 0));
integer transaction_index;
integer trace_index;
integer received_count = 0;
integer bit_index;
integer char_index;
reg [7:0] decoded;
reg [3:0] nibble;

rv_uart_diagnostic #(.WAIT_CYCLES(20), .REPORT_CYCLES(10000), .TRACE_ENABLE(TRACE_ENABLE), .X22_ENABLE(X22_ENABLE), .STACK_ENABLE(STACK_ENABLE), .READ_PATH_ENABLE(READ_PATH_ENABLE), .HISTORY_DEPTH(HISTORY_DEPTH)) diagnostic (
    .clk(clk), .resetn(resetn && diagnostic_enabled), .snapshot(SNAPSHOT),
    .transaction(transaction),
    .read_path(read_path),
    .x22_snapshot(x22_snapshot),
    .extra_tag("X"),
    .stack_snapshot(stack_snapshot),
    .waiting(waiting), .completed(completed), .trap(trap),
    .uart_busy(busy), .owned(owned), .write_byte(write_byte), .byte_data(byte_data)
);
simpleuart #(.DEFAULT_DIV(3)) uart (
    .clk(clk), .resetn(resetn), .ser_tx(serial), .ser_rx(1'b1),
    .reg_div_we(4'd0), .reg_div_di(32'd0), .reg_div_do(),
    .reg_dat_we(owned ? write_byte : firmware_write), .reg_dat_re(1'b0),
    .reg_dat_di(owned ? {24'd0, byte_data} : 32'h58),
    .reg_dat_do(), .reg_dat_wait(), .tx_busy(busy)
);
initial begin
    forever begin
        @(negedge serial);
        repeat (2) @(posedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            repeat (5) @(posedge clk);
            decoded[bit_index] = serial;
        end
        repeat (5) @(posedge clk);
        if (serial !== 1'b1)
            $fatal(1, "Invalid UART stop bit");
        received[received_count] = decoded;
        received_count = received_count + 1;
    end
end

initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    wait (!busy);
    if ($test$plusargs("x22_test")) begin
        @(negedge clk);
        diagnostic_enabled = 1;
        waiting = 1;
        wait (owned);
        @(negedge clk);
        x22_snapshot = 0;
        stack_snapshot = 0;
        wait (received_count == 84);
        if (received[46] !== "X")
            $fatal(1, "RVX header missing");
        for (char_index = 0; char_index < 32; char_index = char_index + 1) begin
            nibble = 128'h00001234_12345678_03c003c0_0019ff80 >> ((31 - char_index) * 4);
            if (received[50 + char_index] !==
                (nibble < 10 ? 8'h30 + nibble : 8'h61 + nibble - 10))
                $fatal(1, "RVX snapshot mismatch");
        end
        if (STACK_ENABLE != 0) begin
            wait (received_count == 126);
            if (received[88] !== "S")
                $fatal(1, "RVS header missing");
            for (char_index = 0; char_index < 32; char_index = char_index + 1) begin
                nibble = 128'h00018000_03c003c0_f0000001_00000001 >> ((31 - char_index) * 4);
                if (received[92 + char_index] !==
                    (nibble < 10 ? 8'h30 + nibble : 8'h61 + nibble - 10))
                    $fatal(1, "RVS snapshot mismatch");
            end
        end
        $display("PASS RVX/RVS UART snapshot");
        $finish;
    end
    if ($test$plusargs("trace_test")) begin
        if (TRACE_ENABLE == 0)
            $fatal(1, "trace_test requires TRACE_ENABLE=1");
        @(negedge clk);
        diagnostic_enabled = 1;
        for (transaction_index = 0; transaction_index < 12; transaction_index = transaction_index + 1) begin
            @(negedge clk);
            transaction = {32'h1000 + transaction_index * 32'd4,
                           32'hf0000000 + transaction_index,
                           32'd100 + transaction_index,
                           (transaction_index % 2 == 0) ? 32'h10 : 32'h0f};
            read_path = {32'h400000 + transaction_index * 32'd4,
                         32'ha0000000 + transaction_index,
                         32'hb0000000 + transaction_index};
            if (transaction_index >= 12 - HISTORY_DEPTH) begin
                expected_trace[transaction_index - (12 - HISTORY_DEPTH)] = transaction;
                expected_read_path[transaction_index - (12 - HISTORY_DEPTH)] = {read_path, transaction[95:64]};
            end
            completed = 1;
            @(negedge clk);
            completed = 0;
        end
        waiting = 1;
        wait (diagnostic.trace_frozen);
        @(negedge clk);
        transaction = 128'hdeadbeef_deadbeef_deadbeef_deadbeef;
        read_path = 0;
        completed = 1;
        waiting = 0;
        wait (received_count == TRACE_BASE + HISTORY_DEPTH * TRACE_STRIDE);
        for (trace_index = 0; trace_index < HISTORY_DEPTH; trace_index = trace_index + 1) begin
            if (received[TRACE_BASE + trace_index * TRACE_STRIDE + 4] !== "T" ||
                received[TRACE_BASE + trace_index * TRACE_STRIDE + 6] !== 8'h30 + trace_index)
                $fatal(1, "Trace frame header/order mismatch");
            for (char_index = 0; char_index < 32; char_index = char_index + 1) begin
                nibble = expected_trace[trace_index] >> ((31 - char_index) * 4);
                if (received[TRACE_BASE + trace_index * TRACE_STRIDE + 8 + char_index] !==
                    (nibble < 10 ? 8'h30 + nibble : 8'h61 + nibble - 10))
                    $fatal(1, "Trace record %0d nibble %0d mismatch", trace_index, char_index);
            end
            if (READ_PATH_ENABLE != 0) begin
                if (received[TRACE_BASE + 42 + trace_index * TRACE_STRIDE + 4] !== "L" ||
                    received[TRACE_BASE + 42 + trace_index * TRACE_STRIDE + 6] !== 8'h30 + trace_index)
                    $fatal(1, "Read path frame header/order mismatch");
                for (char_index = 0; char_index < 32; char_index = char_index + 1) begin
                    nibble = expected_read_path[trace_index] >> ((31 - char_index) * 4);
                    if (received[TRACE_BASE + 42 + trace_index * TRACE_STRIDE + 8 + char_index] !==
                        (nibble < 10 ? 8'h30 + nibble : 8'h61 + nibble - 10))
                        $fatal(1, "Read path record %0d nibble %0d mismatch", trace_index, char_index);
                end
            end
        end
        wait (!owned);
        repeat (3) @(negedge clk);
        if (diagnostic.trace_frozen)
            $fatal(1, "Trace did not rearm after recovered stall");
        $display("PASS rv_uart_trace: ring wrap, chronological records, freeze and recovery rearm");
        $finish;
    end
    @(negedge clk);
    firmware_write = 1;
    @(negedge clk);
    firmware_write = 0;
    diagnostic_enabled = 1;
    waiting = 1;
    wait (received_count == 43);
    if (received[0] !== "X" || received[3] !== "R" || received[7] !== "3")
        $fatal(1, "Firmware character or timeout reason corrupted");
    for (char_index = 0; char_index < 32; char_index = char_index + 1) begin
        nibble = SNAPSHOT >> ((31 - char_index) * 4);
        if (received[9 + char_index] !== (nibble < 10 ? 8'h30 + nibble : 8'h61 + nibble - 10))
            $fatal(1, "Snapshot hex mismatch at %0d", char_index);
    end
    wait (!owned);
    @(negedge clk);
    waiting = 0;
    completed = 1;
    repeat (5) @(negedge clk);
    trap = 1;
    wait (received_count == 85);
    if (received[49] !== "4")
        $fatal(1, "Trap reason missing");
    @(negedge clk);
    trap = 0;
    wait (received_count == 127);
    if (received[91] !== "0")
        $fatal(1, "Periodic progress report missing");
    $display("PASS rv_uart_diagnostic: UART arbitration, snapshot, timeout, trap and periodic report");
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "Diagnostic test timed out");
end
endmodule