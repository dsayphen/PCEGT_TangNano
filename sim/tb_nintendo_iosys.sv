`timescale 1ns/1ps
module tb_nintendo_iosys;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;
    reg valid = 0;
    reg [31:0] address = 0, data = 0;
    reg [3:0] strobes = 0;
    wire [6:0] colors;
    wire [1:0] region;
    iosys #(.CORE_ID(16'd5)) dut (
        .clk(clk), .resetn(resetn), .nintendo_color(colors), .console_region(region)
    );
    initial begin
        force dut.mem_valid = valid;
        force dut.mem_addr = address;
        force dut.mem_wdata = data;
        force dut.mem_wstrb = strobes;
        repeat (3) @(negedge clk);
        if (colors !== 0 || region !== 0) $fatal(1, "FAILED register reset");
        resetn = 1;
        valid = 1; address = 32'h020000d8; data = 2; strobes = 1;
        @(negedge clk);
        if (region !== 2 || dut.mem_ready !== 1 || dut.mem_rdata !== 2)
            $fatal(1, "FAILED console-region register write/read");
        data = 1; strobes = 2;
        @(negedge clk);
        if (region !== 2) $fatal(1, "FAILED console-region byte-lane guard");
        valid = 1; address = 32'h020000d4; data = 32'hffffffff; strobes = 1;
        @(negedge clk);
        if (colors !== 7'h7f || dut.mem_ready !== 1 || dut.mem_rdata !== 32'h7f)
            $fatal(1, "FAILED Nintendo register write/read");
        data = 0; strobes = 2;
        @(negedge clk);
        if (colors !== 7'h7f) $fatal(1, "FAILED Nintendo byte lane guard");
        strobes = 1; data = 32'h8;
        @(negedge clk);
        if (colors !== 4'h8) $fatal(1, "FAILED independent NES/GBC controls");
        data = 32'h70;
        @(negedge clk);
        if (colors !== 7'h70) $fatal(1, "FAILED Fast and GB Light register fields");
        address = 32'h02000060; data = 0; strobes = 0;
        @(negedge clk);
        if (!dut.mem_ready || dut.mem_rdata[15] !== 1'b1)
            $fatal(1, "FAILED extended settings capability flag");
        address = 32'h0200005c; data = 1; strobes = 1;
        @(negedge clk);
        if (dut.color_mode !== 1 || colors !== 7'h70)
            $fatal(1, "FAILED legacy color register isolation");
        $display("tb_nintendo_iosys PASSED");
        $finish;
    end
endmodule
