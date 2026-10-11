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
rv_memory_probe #(.WAIT_CYCLES(10), .ADDRESS(23'h59ff7c)) probe (
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
        if (!valid || address !== 23'h59ff7c)
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

module tb_rv_stack_watch #(
    parameter BUS_TRACE = 0
);
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg completed = 0;
reg [31:0] address = 32'h0019ff7c;
reg [3:0] strobes = 0;
reg instruction = 0;
wire [127:0] snapshot;
rv_stack_watch #(.ADDRESS(32'h0019ff7c), .BUS_TRACE(BUS_TRACE)) watch (
    .clk(clk), .resetn(resetn), .completed(completed), .address(address),
    .write_data(32'h00018000), .read_data(32'h03c003c0),
    .write_strobes(strobes), .instruction(instruction), .snapshot(snapshot),
    .capture_data(64'h0059ff7c_11223344), .bridge_data(32'h55667788),
    .bus_data(128'h12345678_33cccc33_cc3333cc_03c003c0),
    .read_path(), .has_read()
);
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    completed = 1;
    strobes = 15;
    @(negedge clk);
    strobes = 0;
    @(negedge clk);
    if (!watch.has_read || watch.read_path !== (BUS_TRACE != 0 ?
        128'h12345678_33cccc33_cc3333cc_03c003c0 :
        128'h0059ff7c_11223344_55667788_03c003c0))
        $fatal(1, "Stack read path capture mismatch");
    address = 32'h0019ff74;
    strobes = 1;
    @(negedge clk);
    address = 32'h0019ff7c;
    instruction = 1;
    @(negedge clk);
    completed = 0;
    if (snapshot !== 128'h00018000_03c003c0_f0000001_00000001)
        $fatal(1, "Stack read/write capture mismatch");
    if (watch.read_path !== (BUS_TRACE != 0 ?
        128'h12345678_33cccc33_cc3333cc_03c003c0 :
        128'h0059ff7c_11223344_55667788_03c003c0))
        $fatal(1, "Stack read path changed after unrelated transfers");
    $display("PASS stack watch: address filter, read/write values and counts");
    $finish;
end
endmodule

module tb_rv_suspect_read;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg completed = 0;
reg instruction = 0;
reg [31:0] address = 32'h02000070;
reg [31:0] data = 32'h03c003c0;
wire [127:0] snapshot;
wire [127:0] path;
wire has_read;
wire [22:0] target;
wire [22:0] probe_address;
rv_stack_watch #(.SUSPECT_READ(1)) watch (
    .clk(clk), .resetn(resetn), .completed(completed), .address(address),
    .write_data(32'd0), .read_data(data), .write_strobes(4'd0),
    .instruction(instruction), .capture_data({9'd0, 23'h59ff8c, 32'h03c003c0}),
    .bridge_data(32'h03c003c0), .bus_data(128'h12345678_0_1_03c003c0),
    .read_path(path), .snapshot(snapshot), .has_read(has_read),
    .suspect_address(target)
);
rv_memory_probe #(.DYNAMIC_ADDRESS(1)) probe (
    .clk(clk), .resetn(resetn), .stalled(1'b0), .ready(1'b0), .rdata(32'd0),
    .target_address(target), .address(probe_address), .valid(), .snapshot(), .has_result()
);
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    completed = 1;
    @(negedge clk);
    if (has_read) $fatal(1, "MMIO triggered suspect capture");
    address = 32'h0001089c;
    @(negedge clk);
    if (has_read) $fatal(1, "ROM buffer pattern triggered capture");
    data = 32'h33cccc33;
    @(negedge clk);
    if (has_read) $fatal(1, "Ordinary data pattern triggered capture");
    address = 32'h000024c4;
    instruction = 1;
    data = 32'h000187b7;
    @(negedge clk);
    if (has_read) $fatal(1, "Correct known instruction triggered capture");
    address = 32'h0019ff8c;
    instruction = 0;
    data = 32'h00000000;
    @(negedge clk);
    if (has_read) $fatal(1, "Ordinary zero data triggered capture");
    data = 32'h03c003c0;
    @(negedge clk);
    if (!has_read || snapshot !== 128'h0019ff8c_03c003c0_03c003c0_03c003c0 ||
        probe_address !== 23'h59ff8c)
        $fatal(1, "Suspect address/data capture failed");
    address = 32'h000024c4;
    data = 0;
    instruction = 1;
    @(negedge clk);
    if (snapshot[127:96] !== 32'h0019ff8c || path !== 128'h12345678_0_1_03c003c0)
        $fatal(1, "First suspect was overwritten");
    resetn = 0;
    @(negedge clk);
    resetn = 1;
    @(negedge clk);
    if (!has_read || snapshot[127:96] !== 32'h000024c4)
        $fatal(1, "Invalid RV32I instruction was not captured");
    resetn = 0;
    @(negedge clk);
    resetn = 1;
    data = 32'h000007b7;
    @(negedge clk);
    if (!has_read || snapshot[31:0] !== 32'h000007b7)
        $fatal(1, "Known instruction mismatch was not captured");
    $display("PASS suspect read: buffer exclusion, stack pattern, known opcode, first-event freeze, dynamic address");
    $finish;
end
endmodule