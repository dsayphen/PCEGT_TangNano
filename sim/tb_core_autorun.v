`timescale 1ns/1ps
module tb_core_autorun #(parameter integer MAX_CYCLES = 4000000);
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
wire valid, ready, instruction, trap;
wire [31:0] address, wdata, rdata;
wire [3:0] strobes;
reg [7:0] memory [0:2097151];
wire ram_selected = address < 32'h00200000;
assign ready = valid;
assign rdata = ram_selected ?
    {memory[{address[20:2],2'b11}], memory[{address[20:2],2'b10}],
     memory[{address[20:2],2'b01}], memory[{address[20:2],2'b00}]} : 0;
picorv32 #(.ENABLE_COUNTERS(0), .ENABLE_COUNTERS64(0)) cpu (
    .clk(clk), .resetn(resetn), .trap(trap),
    .mem_valid(valid), .mem_ready(ready), .mem_instr(instruction),
    .mem_addr(address), .mem_wdata(wdata), .mem_wstrb(strobes), .mem_rdata(rdata),
    .irq(32'd0), .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
);
integer index;
reg [1023:0] image_file;
initial begin
    if (!$value$plusargs("IMAGE=%s", image_file))
        image_file = "sim/core_autorun_test.hex";
    $readmemh(image_file, memory, 0, 131071);
    repeat (5) @(negedge clk);
    resetn = 1;
    repeat (MAX_CYCLES) @(posedge clk);
    $fatal(1, "Firmware test timeout: %0s", image_file);
end
always @(posedge clk) if (resetn) begin
    if (trap) $fatal(1, "CPU trap");
    if (valid && ready && |strobes) begin
        if (ram_selected) begin
            for (index = 0; index < 4; index = index + 1)
                if (strobes[index]) memory[{address[20:2],2'b00} + index] <= wdata[index*8 +: 8];
        end else if (address == 32'h03000000) begin
            if (wdata != 0) $fatal(1, "Autorun test case %0d failed", wdata);
            $display("Firmware test PASSED: %0s", image_file);
            $finish;
        end
    end
end
endmodule