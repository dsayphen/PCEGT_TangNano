`timescale 1ns/1ps

module tb_arcade_ram;
reg clk = 0, clk_mem = 0, clk_sdram = 0, resetn = 0;
always #11.574 clk = ~clk;
always #5.787 clk_mem = ~clk_mem;
always @(clk_mem) clk_sdram <= #5.787 clk_mem;
reg [2:0] slot = 0;
reg clkref = 0;
always @(negedge clk) begin
    slot <= slot + 1'b1;
    clkref <= (slot == 3'd0);
end

wire [31:0] dq;
wire [10:0] addr;
wire [1:0] bank;
wire [3:0] dqm;
wire sclk, cke, cs_n, cas_n, ras_n, wen_n;
reg cd_rd = 0, cd_wr = 0;
reg [21:0] cd_addr = 0;
reg [7:0] cd_din = 0;
wire [7:0] cd_dout;
wire cd_rdy, init_done;
integer errors = 0;

pce_sdram_ctrl_3ch mem (
    .clk(clk), .clk_mem(clk_mem), .clk_sdram(clk_sdram),
    .clkref(clkref), .refresh_window(1'b0), .resetn(resetn),
    .O_sdram_clk(sclk), .O_sdram_cke(cke), .O_sdram_cs_n(cs_n),
    .O_sdram_cas_n(cas_n), .O_sdram_ras_n(ras_n),
    .O_sdram_wen_n(wen_n), .IO_sdram_dq(dq), .O_sdram_addr(addr),
    .O_sdram_ba(bank), .O_sdram_dqm(dqm),
    .ld_wr(1'b0), .ld_addr(23'd0), .ld_data(8'd0),
    .ld_busy(), .ld_idle(), .ld_active(1'b0),
    .rom_rd(1'b0), .rom_a(22'd0), .rom_offset(23'd0),
    .rom_do(), .rom_rdy(),
    .vram_addr(16'd0), .vram_din(16'd0), .vram_dout(),
    .vram_rd(1'b0), .vram_we(1'b0),
    .vram1_addr(16'd0), .vram1_din(16'd0), .vram1_dout(),
    .vram1_rd(1'b0), .vram1_we(1'b0),
    .rv_valid(1'b0), .rv_ready(), .rv_addr(23'd0),
    .rv_wdata(32'd0), .rv_wstrb(4'd0), .rv_rdata(),
    .cdram_rd(cd_rd), .cdram_wr(cd_wr), .cdram_addr(cd_addr),
    .cdram_din(cd_din), .cdram_dout(cd_dout), .cdram_rdy(cd_rdy),
    .adram_addr(17'd0), .adram_din(4'd0), .adram_dout(),
    .adram_we(1'b0), .adram_rd(1'b0), .adram_clken(1'b0),
    .init_done(init_done)
);

sdram_model sd (
    .DQ(dq), .A(addr), .BA(bank), .nCS(cs_n), .nWE(wen_n),
    .nRAS(ras_n), .nCAS(cas_n), .CLK(sclk), .CKE(cke),
    .DQM(dqm), .clk(clk_mem)
);

task write_byte;
    input [21:0] address;
    input [7:0] value;
    begin
        @(negedge clk);
        cd_addr = address;
        cd_din = value;
        cd_wr = 1;
        wait (!cd_rdy);
        wait (cd_rdy);
        @(negedge clk);
        cd_wr = 0;
    end
endtask

task read_byte;
    input [21:0] address;
    input [7:0] expected;
    begin
        @(negedge clk);
        cd_addr = address;
        cd_rd = 1;
        wait (!cd_rdy);
        wait (cd_rdy);
        #1;
        if (cd_dout !== expected) begin
            $display("FAIL %h: got %h, expected %h", address, cd_dout, expected);
            errors = errors + 1;
        end
        @(negedge clk);
        cd_rd = 0;
    end
endtask

initial begin
    #100;
    resetn = 1;
    wait (init_done);
    write_byte(22'h000000, 8'h11);
    write_byte(22'h03ffff, 8'h22);
    write_byte(22'h040000, 8'h33);
    write_byte(22'h1fffff, 8'h44);
    write_byte(22'h200000, 8'h55);
    read_byte(22'h000000, 8'h11);
    read_byte(22'h200000, 8'h55);
    read_byte(22'h03ffff, 8'h22);
    read_byte(22'h040000, 8'h33);
    read_byte(22'h1fffff, 8'h44);
    read_byte(22'h000000, 8'h11);
    $display("Arcade RAM: %0d errors", errors);
    if (errors) $fatal(1, "Arcade RAM mismatch");
    $finish;
end

initial begin
    #5000000;
    $fatal(1, "Arcade RAM timeout");
end
endmodule