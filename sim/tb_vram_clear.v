//
// Proves that the loader's byte port can actually reach the two VDC VRAM
// windows, i.e. that the addresses iosys.v uses to zero VRAM before a load
// really land where the VDCs read.
//
// Derived from the RAS/CAS mapping in pce_sdram_ctrl_3ch.v:
//   VDC0 CAS: bank 2'b11, row {5'b11111, vram_addr[14:9]},  col addr[9:2]
//   VDC1 CAS: bank 2'b10, row {5'b11111, vram1_addr[14:9]}, col addr[9:2]
// and the host port, which uses host_addr[22:21] as bank, host_addr[20:10]
// as row, host_addr[9:2] as column and host_addr[1] to pick the 16-bit half.
// Solving the two for the same physical cell gives
//   VDC0 byte address = 0x7f0000 + 2*vram_addr
//   VDC1 byte address = 0x5f0000 + 2*vram1_addr
// which is exactly what iosys.v's clear FSM walks.
//
// The test seeds VRAM with a "previous game" pattern, checks the VDCs really
// see it, then zeroes those words through the loader port only and checks the
// VDCs now read back zero.
//
`timescale 1ns/1ps

module tb_vram_clear;

reg clk = 0;
reg clk_mem = 0;
reg clk_sdram = 0;
reg resetn = 0;

always #11.574 clk = ~clk;
always #5.787 clk_mem = ~clk_mem;
always @(clk_mem) clk_sdram <= #5.787 clk_mem;

wire [31:0] IO_sdram_dq;
wire [10:0] O_sdram_addr;
wire [1:0]  O_sdram_ba;
wire        O_sdram_cs_n, O_sdram_wen_n, O_sdram_ras_n, O_sdram_cas_n;
wire        O_sdram_clk, O_sdram_cke;
wire [3:0]  O_sdram_dqm;

reg  [15:0] vram_addr = 16'd0;
reg         vram_rd   = 1'b0;
wire [15:0] vram_dout;
reg  [15:0] vram1_addr = 16'd0;
reg         vram1_rd   = 1'b0;
wire [15:0] vram1_dout;

reg         ld_wr   = 1'b0;
reg  [22:0] ld_addr = 23'd0;
reg  [7:0]  ld_data = 8'd0;
wire        ld_busy;

reg  refresh_window = 1'b0;
reg  clkref = 1'b0;
wire sdram_init_done;

pce_sdram_ctrl_3ch #(.FREQ(86_400_000)) mem (
    .clk(clk), .clk_mem(clk_mem), .clk_sdram(clk_sdram),
    .clkref(clkref), .refresh_window(refresh_window), .resetn(resetn),
    .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
    .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
    .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
    .IO_sdram_dq(IO_sdram_dq), .O_sdram_addr(O_sdram_addr),
    .O_sdram_ba(O_sdram_ba), .O_sdram_dqm(O_sdram_dqm),
    .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data),
    .ld_busy(ld_busy), .ld_idle(), .ld_active(1'b1),
    .rom_rd(1'b0), .rom_a(22'd0), .rom_offset(23'd0), .rom_do(), .rom_rdy(),
    .vram_addr(vram_addr), .vram_din(16'd0), .vram_dout(vram_dout),
    .vram_rd(vram_rd), .vram_we(1'b0),
    .vram1_addr(vram1_addr), .vram1_din(16'd0), .vram1_dout(vram1_dout),
    .vram1_rd(vram1_rd), .vram1_we(1'b0),
    .rv_valid(1'b0), .rv_ready(), .rv_addr(23'd0), .rv_wdata(32'd0),
    .rv_wstrb(4'd0), .rv_rdata(),
    .init_done(sdram_init_done)
);

sdram_model sd (
    .DQ(IO_sdram_dq), .A(O_sdram_addr), .BA(O_sdram_ba),
    .nCS(O_sdram_cs_n), .nWE(O_sdram_wen_n), .nRAS(O_sdram_ras_n),
    .nCAS(O_sdram_cas_n), .CLK(O_sdram_clk), .CKE(O_sdram_cke),
    .DQM(O_sdram_dqm), .clk(clk_mem)
);

// Same physical word addresses the other testbenches use.
function [20:0] phys_word_addr;  input [15:0] a;
    begin phys_word_addr  = 21'h1FC000 + {6'd0, a[14:1]}; end
endfunction
function [20:0] phys_word_addr1; input [15:0] a;
    begin phys_word_addr1 = 21'h17C000 + {6'd0, a[14:1]}; end
endfunction

// The byte addresses iosys.v's clear FSM uses.
localparam [22:0] VRAM0_CLEAR_BASE = 23'h7f_0000;
localparam [22:0] VRAM1_CLEAR_BASE = 23'h5f_0000;

integer errors = 0;
reg [31:0] w32;

task poke0; input [15:0] a; input [15:0] v; begin
    w32 = sd.mem[phys_word_addr(a)];
    if (a[0]) w32[31:16] = v; else w32[15:0] = v;
    sd.mem[phys_word_addr(a)] = w32;
end endtask

task poke1; input [15:0] a; input [15:0] v; begin
    w32 = sd.mem[phys_word_addr1(a)];
    if (a[0]) w32[31:16] = v; else w32[15:0] = v;
    sd.mem[phys_word_addr1(a)] = w32;
end endtask

task vdc_read0; input [15:0] a; begin
    @(negedge clk); vram_addr <= a; vram_rd <= 1'b1; clkref <= 1'b1;
    @(posedge clk); @(negedge clk); clkref <= 1'b0;
    repeat (6) @(posedge clk);
end endtask

task vdc_read1; input [15:0] a; begin
    @(negedge clk); vram1_addr <= a; vram1_rd <= 1'b1; clkref <= 1'b1;
    @(posedge clk); @(negedge clk); clkref <= 1'b0;
    repeat (6) @(posedge clk);
end endtask

// One loader byte write, exactly as iosys.v drives it.
task ld_byte; input [22:0] a; input [7:0] d; begin
    while (ld_busy) @(posedge clk);
    @(negedge clk); ld_wr <= 1'b1; ld_addr <= a; ld_data <= d;
    @(negedge clk); ld_wr <= 1'b0;
    while (ld_busy) @(posedge clk);
    repeat (10) @(posedge clk);
end endtask

task expect0; input [255:0] lbl; input [15:0] exp; begin
    if (vram_dout !== exp) begin
        $display("FAIL %0s: VRAM0 = %h, expected %h", lbl, vram_dout, exp);
        errors = errors + 1;
    end else $display("ok   %0s: VRAM0 = %h", lbl, vram_dout);
end endtask

task expect1; input [255:0] lbl; input [15:0] exp; begin
    if (vram1_dout !== exp) begin
        $display("FAIL %0s: VRAM1 = %h, expected %h", lbl, vram1_dout, exp);
        errors = errors + 1;
    end else $display("ok   %0s: VRAM1 = %h", lbl, vram1_dout);
end endtask

integer k;
reg [15:0] wa;

initial begin
    $dumpfile("sim/tb_vram_clear.vcd");
    $dumpvars(0, tb_vram_clear);

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (sdram_init_done);
    repeat (10) @(posedge clk);

    // ---- "previous game" leaves structured data behind in both VRAMs ----
    for (k = 0; k < 8; k = k + 1) begin
        wa = k[15:0] * 3;              // exercise odd and even word addresses
        poke0(wa, 16'hBEE0 + k[15:0]);
        poke1(wa, 16'hCAF0 + k[15:0]);
    end
    repeat (5) @(posedge clk);

    $display("--- the VDCs see the previous game's VRAM ---");
    vdc_read0(16'd0);  expect0("stale-vram0", 16'hBEE0);
    vdc_read1(16'd0);  expect1("stale-vram1", 16'hCAF0);
    vdc_read0(16'd3);  expect0("stale-vram0-odd", 16'hBEE1);
    vdc_read1(16'd3);  expect1("stale-vram1-odd", 16'hCAF1);

    // ---- zero those words through the loader port only -----------------
    $display("--- clearing both VRAM windows through the loader port ---");
    vram_rd  <= 1'b0;
    vram1_rd <= 1'b0;
    for (k = 0; k < 8; k = k + 1) begin
        wa = k[15:0] * 3;
        ld_byte(VRAM0_CLEAR_BASE + {7'd0, wa, 1'b0},        8'h00);
        ld_byte(VRAM0_CLEAR_BASE + {7'd0, wa, 1'b0} + 23'd1, 8'h00);
        ld_byte(VRAM1_CLEAR_BASE + {7'd0, wa, 1'b0},        8'h00);
        ld_byte(VRAM1_CLEAR_BASE + {7'd0, wa, 1'b0} + 23'd1, 8'h00);
    end

    $display("--- the VDCs now read zero ---");
    vdc_read0(16'd0);  expect0("cleared-vram0", 16'h0000);
    vdc_read1(16'd0);  expect1("cleared-vram1", 16'h0000);
    vdc_read0(16'd3);  expect0("cleared-vram0-odd", 16'h0000);
    vdc_read1(16'd3);  expect1("cleared-vram1-odd", 16'h0000);
    vdc_read0(16'd21); expect0("cleared-vram0-far", 16'h0000);
    vdc_read1(16'd21); expect1("cleared-vram1-far", 16'h0000);

    if (errors == 0) $display("\n*** tb_vram_clear PASSED ***");
    else             $display("\n*** tb_vram_clear FAILED with %0d error(s) ***", errors);
    $finish;
end

initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule
