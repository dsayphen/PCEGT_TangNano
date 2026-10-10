`timescale 1ns/1ps
module tb_rv_memory_probe;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg stalled = 0;
reg ready = 0;
reg [31:0] read_data = 0;
reg [127:0] expected_snapshot = 0;
wire valid;
wire [22:0] address;
wire [127:0] snapshot;
wire has_result;
integer read_index;
rv_memory_probe #(.WAIT_CYCLES(10), .ADDRESS(23'h59ff70)) probe (
    .clk(clk), .resetn(resetn), .stalled(stalled), .ready(ready),
    .rdata(read_data), .valid(valid), .address(address),
    .snapshot(snapshot), .has_result(has_result)
);
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    repeat (20) @(negedge clk);
    if (valid || has_result)
        $fatal(1, "Probe started without stall");
    stalled = 1;
    for (read_index = 1; read_index <= 4; read_index = read_index + 1) begin
        wait (valid);
        repeat (5) @(negedge clk);
        if (!valid || address !== 23'h59ff70)
            $fatal(1, "Probe request not stable");
        read_data = 32'h000187b7 + read_index;
        expected_snapshot = {expected_snapshot[95:0], read_data};
        ready = 1;
        @(negedge clk);
        ready = 0;
        if (valid || has_result !== (read_index == 4) || snapshot !== expected_snapshot)
            $fatal(1, "Probe response mismatch");
    end
    repeat (30) @(negedge clk);
    if (valid)
        $fatal(1, "Probe issued more than four requests");
    $display("PASS memory probe: stall trigger, stable requests, four read responses");
    $finish;
end
initial begin
    #10000;
    $fatal(1, "Probe test timeout");
end
endmodule

module tb_rv_stack_watch;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg completed = 0;
reg [31:0] address = 32'h0019ff70;
reg [3:0] strobes = 0;
reg instruction = 0;
wire [127:0] snapshot;
rv_stack_watch watch (
    .clk(clk), .resetn(resetn), .completed(completed), .address(address),
    .write_data(32'h00018000), .read_data(32'h03c003c0),
    .write_strobes(strobes), .instruction(instruction), .snapshot(snapshot)
);
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    completed = 1;
    strobes = 15;
    @(negedge clk);
    strobes = 0;
    @(negedge clk);
    address = 32'h0019ff74;
    strobes = 1;
    @(negedge clk);
    address = 32'h0019ff70;
    instruction = 1;
    @(negedge clk);
    completed = 0;
    if (snapshot !== 128'h00018000_03c003c0_f0000001_00000001)
        $fatal(1, "Stack read/write capture mismatch");
    $display("PASS stack watch: address filter, read/write values and counts");
    $finish;
end
endmodule