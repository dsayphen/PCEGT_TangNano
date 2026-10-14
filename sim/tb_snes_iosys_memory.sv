`timescale 1ns / 1ps
module tb_snes_iosys_memory;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg rv_req = 0;
reg aram_req = 0;
reg [22:1] rv_addr = 0;
reg [15:0] aram_addr = 0;
wire [31:0] dq;
sdram_snes #(.SHARED_IOSYS(1)) dut (
    .clk(clk), .mclk(clk), .clkref(1'b0), .resetn(resetn), .SDRAM_DQ(dq),
    .cpu_din(16'd0), .cpu_port(1'b0), .cpu_addr(22'd0), .cpu_req(1'b0),
    .cpu_we(1'b0), .cpu_ds(2'b11),
    .bsram_addr(20'd0), .bsram_din(8'd0), .bsram_req(1'b0), .bsram_we(1'b0),
    .aram_16(1'b0), .aram_addr(aram_addr), .aram_din(16'd0), .aram_req(aram_req), .aram_we(1'b0),
    .vram1_addr(15'd0), .vram1_din(8'd0), .vram1_req(1'b0), .vram1_we(1'b0),
    .vram2_addr(15'd0), .vram2_din(8'd0), .vram2_req(1'b0), .vram2_we(1'b0),
    .rv_addr(rv_addr), .rv_din(16'd0), .rv_ds(2'b11), .rv_req(rv_req), .rv_we(1'b0)
);
task check_address(input [22:0] expected);
    #1;
    if (dut.next_addr[1] !== expected)
        $fatal(1, "address got=%h expected=%h", dut.next_addr[1], expected);
endtask
initial begin
    repeat (2) @(negedge clk);
    resetn = 1;
    rv_req = 1;
    rv_addr = 23'h400000 >> 1;
    check_address(23'h400000);
    rv_addr = 23'h590000 >> 1;
    check_address(23'h590000);
    rv_addr = 23'h5e1234 >> 1;
    check_address(23'h3c1234);
    rv_req = 0;
    aram_req = 1;
    aram_addr = 16'h1234;
    check_address(23'h5a1234);
    $display("tb_snes_iosys_memory PASSED: firmware, stack, BSRAM and ARAM mapping");
    $finish;
end
endmodule