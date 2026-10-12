`timescale 1ns/1ps
module tb_state_bridge;
reg clk = 0;
always #5 clk = !clk;
reg resetn = 0;
reg core_reset = 0;
reg valid = 0;
reg [1:0] address = 0;
reg [31:0] write_data = 0;
reg [3:0] write_strobe = 0;
reg [1:0] dot_count = 0;
reg [1:0] video_history = 0;
wire video_ce = dot_count == 0;
wire safe_to_hold = !video_ce && video_history == 0;
always @(posedge clk) begin
    dot_count <= dot_count + 1'b1;
    video_history <= {video_history[0], video_ce};
end
wire ready, hold_core, state_write;
wire [31:0] read_data, state_data;
wire [19:0] state_address;
wire [22:0] raw_base;
wire disabled_ready, disabled_hold, disabled_write;
wire [31:0] disabled_data;
integer writes = 0;
always @(posedge clk) if (state_write) writes <= writes + 1;
state_bridge dut (
    .clk(clk), .resetn(resetn), .core_reset(core_reset), .safe_to_hold(safe_to_hold),
    .valid(valid), .address(address), .write_data(write_data), .write_strobe(write_strobe),
    .ready(ready), .read_data(read_data), .hold_core(hold_core),
    .state_write(state_write), .state_address(state_address), .state_data(state_data),
    .state_q(32'h12345678), .raw_base(raw_base)
);
state_bridge #(.SUPPORTED(0)) disabled (
    .clk(clk), .resetn(resetn), .core_reset(core_reset), .safe_to_hold(safe_to_hold),
    .valid(valid), .address(address), .write_data(write_data), .write_strobe(write_strobe),
    .ready(disabled_ready), .read_data(disabled_data), .hold_core(disabled_hold),
    .state_write(disabled_write), .state_q(32'hffffffff)
);
task transaction(input [1:0] register_address, input [31:0] value, input bit writing);
begin
    @(negedge clk);
    address = register_address; write_data = value;
    write_strobe = writing ? 4'hf : 0; valid = 1;
    do begin @(posedge clk); #1; end while (!ready);
    if (!disabled_ready) $fatal(1, "Disabled bridge changed bus timing");
    @(negedge clk); valid = 0; write_strobe = 0;
    @(posedge clk); #1;
end
endtask
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    transaction(0, 0, 0);
    if (read_data !== 32'h53530100 || disabled_data !== 32'h53530000)
        $fatal(1, "Invalid bridge capability signature");
    transaction(1, 32'h00040023, 1);
    if (state_address !== 20'h40023) $fatal(1, "State address mismatch");
    transaction(2, 32'h87654321, 1);
    if (writes != 0) $fatal(1, "State written before hold");
    transaction(0, 1, 1);
    repeat (100) @(negedge clk);
    transaction(0, 0, 0);
    if (read_data !== 32'h53530101 || !hold_core || disabled_hold)
        $fatal(1, "Hold did not acknowledge with four-clock dot mode");
    transaction(2, 32'h87654321, 1);
    if (writes != 1 || state_data !== 32'h87654321 || disabled_write)
        $fatal(1, "State write pulse mismatch");
    transaction(2, 0, 0);
    if (read_data !== 32'h12345678 || disabled_data !== 0)
        $fatal(1, "State read mismatch");
    transaction(3, 32'h007f0000, 1);
    if (raw_base !== 23'h7f0000) $fatal(1, "Raw window base mismatch");
    core_reset = 1;
    repeat (3) @(negedge clk);
    if (hold_core) $fatal(1, "Reset failed to release hold");
    $display("PASS: MMIO signature, hold, state read/write, raw base and disabled bridge");
    $finish;
end
initial begin #100000; $fatal(1, "State bridge timeout"); end
endmodule