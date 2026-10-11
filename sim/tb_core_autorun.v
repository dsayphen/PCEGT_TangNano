`timescale 1ns/1ps
module tb_core_autorun;
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
initial begin
    $readmemh("sim/core_autorun_test.hex", memory, 0, 131071);
    repeat (5) @(negedge clk);
    resetn = 1;
    repeat (2000000) @(posedge clk);
    $fatal(1, "Autorun test timeout");
end
always @(posedge clk) if (resetn) begin
    if (trap) $fatal(1, "CPU trap");
    if (valid && ready && |strobes) begin
        if (ram_selected) begin
            for (index = 0; index < 4; index = index + 1)
                if (strobes[index]) memory[{address[20:2],2'b00} + index] <= wdata[index*8 +: 8];
        end else if (address == 32'h03000000) begin
            if (wdata != 0) $fatal(1, "Autorun test case %0d failed", wdata);
            $display("tb_core_autorun PASSED (15 cases)");
            $finish;
        end
    end
end
endmodule