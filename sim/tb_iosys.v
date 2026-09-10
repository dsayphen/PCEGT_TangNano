//
// Integration test for the PicoRV32 IO subsystem and the SDRAM scheduler.
//
// Exercised here:
//   * firmware fetch from SPI flash into the softcore's SDRAM window
//   * the softcore executing out of SDRAM (every instruction fetch is an
//     SDRAM read through pce_sdram_ctrl)
//   * 32 bit reads, 32 bit writes and byte writes on the new rv port
//   * the ROM streaming registers: byte ordering, write address, restart on a
//     second load, back pressure, and the rom_sz / rom_offset derivation
//   * `loading` staying high until the last byte has reached the memory array
//   * the HuCard read port reading back what was streamed
//
`timescale 1ns/1ps

module tb_iosys;

localparam FIRMWARE_SIZE = 4096;

reg clk = 0;
reg clk_sdram = 0;
reg resetn = 0;

always #11.574 clk = ~clk;              // 43.2 MHz
always @(clk) clk_sdram <= #11.574 clk; // 180 degrees

// ---- device pins ----------------------------------------------------------
wire [31:0] IO_sdram_dq;
wire [10:0] O_sdram_addr;
wire [1:0]  O_sdram_ba;
wire        O_sdram_cs_n, O_sdram_wen_n, O_sdram_ras_n, O_sdram_cas_n;
wire        O_sdram_clk, O_sdram_cke;
wire [3:0]  O_sdram_dqm;

wire flash_cs_n, flash_mosi, flash_clk, flash_miso, flash_wp_n, flash_hold_n;

// ---- interconnect ---------------------------------------------------------
wire        ld_wr;
wire [22:0] ld_addr;
wire [7:0]  ld_data;
wire        ld_busy, ld_idle;
wire        loading, image_valid;
wire [7:0]  rom_sz;
wire [22:0] rom_offset;

wire        rv_valid, rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata, rv_rdata;
wire [3:0]  rv_wstrb;

reg         rom_rd = 0;
reg  [21:0] rom_a  = 22'h3FFFFF;
wire [7:0]  rom_do;
wire        rom_rdy;
wire        sdram_init_done;

wire        osd_on;
wire [23:0] osd_rgb;
wire        osd_active;

iosys #(
    .FREQ                (43_200_000),
    .FIRMWARE_FLASH_ADDR (24'h50_0000),
    .FIRMWARE_SIZE       (FIRMWARE_SIZE),
    .RV_BASE             (23'h40_0000)
) dut (
    .clk        (clk),
    .resetn     (resetn),

    .clk_pix    (clk),
    .pix_resetn (resetn),
    .osd_x      (11'd0),
    .osd_y      (10'd0),
    .osd_de     (1'b0),
    .osd_on     (osd_on),
    .osd_rgb    (osd_rgb),
    .osd_active (osd_active),

    .joy1       (12'h0a5),

    .ld_wr      (ld_wr),
    .ld_addr    (ld_addr),
    .ld_data    (ld_data),
    .ld_busy    (ld_busy),
    .ld_idle    (ld_idle),
    .loading    (loading),
    .image_valid(image_valid),
    .rom_sz     (rom_sz),
    .rom_offset (rom_offset),

    .rv_valid   (rv_valid),
    .rv_ready   (rv_ready),
    .rv_addr    (rv_addr),
    .rv_wdata   (rv_wdata),
    .rv_wstrb   (rv_wstrb),
    .rv_rdata   (rv_rdata),
    .ram_busy   (~sdram_init_done),

    .flash_spi_cs_n   (flash_cs_n),
    .flash_spi_miso   (flash_miso),
    .flash_spi_mosi   (flash_mosi),
    .flash_spi_clk    (flash_clk),
    .flash_spi_wp_n   (flash_wp_n),
    .flash_spi_hold_n (flash_hold_n),

    .uart_rx    (1'b1),
    .uart_tx    (),

    .sd_clk     (),
    .sd_mosi    (),
    .sd_miso    (1'b1),
    .sd_cs_n    ()
);

pce_sdram_ctrl #(.FREQ(43_200_000)) mem (
    .clk           (clk),
    .clk_sdram     (clk_sdram),
    .resetn        (resetn),

    .O_sdram_clk   (O_sdram_clk),
    .O_sdram_cke   (O_sdram_cke),
    .O_sdram_cs_n  (O_sdram_cs_n),
    .O_sdram_cas_n (O_sdram_cas_n),
    .O_sdram_ras_n (O_sdram_ras_n),
    .O_sdram_wen_n (O_sdram_wen_n),
    .IO_sdram_dq   (IO_sdram_dq),
    .O_sdram_addr  (O_sdram_addr),
    .O_sdram_ba    (O_sdram_ba),
    .O_sdram_dqm   (O_sdram_dqm),

    .ld_wr         (ld_wr),
    .ld_addr       (ld_addr),
    .ld_data       (ld_data),
    .ld_busy       (ld_busy),
    .ld_idle       (ld_idle),
    .ld_active     (loading),

    .rom_rd        (rom_rd),
    .rom_a         (rom_a),
    .rom_offset    (rom_offset),
    .rom_do        (rom_do),
    .rom_rdy       (rom_rdy),

    .rv_valid      (rv_valid),
    .rv_ready      (rv_ready),
    .rv_addr       (rv_addr),
    .rv_wdata      (rv_wdata),
    .rv_wstrb      (rv_wstrb),
    .rv_rdata      (rv_rdata),

    .init_done     (sdram_init_done)
);

sdram_model sd (
    .DQ   (IO_sdram_dq),
    .A    (O_sdram_addr),
    .BA   (O_sdram_ba),
    .nCS  (O_sdram_cs_n),
    .nWE  (O_sdram_wen_n),
    .nRAS (O_sdram_ras_n),
    .nCAS (O_sdram_cas_n),
    .CLK  (O_sdram_clk),
    .CKE  (O_sdram_cke),
    .DQM  (O_sdram_dqm),
    .clk  (clk)
);

spiflash_model #(
    .MEM_BYTES (65536),
    .BASE_ADDR (24'h50_0000),
    .HEXFILE   ("sim/prog.hex")
) flash (
    .ncs  (flash_cs_n),
    .sck  (flash_clk),
    .mosi (flash_mosi),
    .miso (flash_miso)
);

// ===========================================================================
// Scoreboard
// ===========================================================================
integer errors = 0;
integer marks  = 0;
reg [7:0] mark_log [0:15];

initial begin
    wait (dut.flash_loaded);
    repeat (10) @(posedge clk);
    check_eq(sd.mem[21'h100000], 32'h00200137, "firmware word 0");
    check_eq(sd.mem[21'h100001], 32'h1f000513, "firmware word 1");
end

task check_eq;
    input [63:0] got;
    input [63:0] exp;
    input [255:0] name;
    begin
        if (got !== exp) begin
            $display("FAIL %0s: got %h expected %h", name, got, exp);
            errors = errors + 1;
        end else begin
            $display("ok   %0s = %h", name, got);
        end
    end
endtask

// snoop the OSD character register writes the program uses as markers
always @(posedge clk) begin
    if (resetn && dut.textdisp_sel && dut.mem_wstrb != 4'b0 && dut.mem_ready) begin
        mark_log[marks[3:0]] = dut.mem_wdata[7:0];
        marks = marks + 1;
        $display("[%0t] marker '%0s' (%0d)", $time, dut.mem_wdata[7:0], marks);
        if (dut.mem_wdata[7:0] == "E") begin
            $display("FAIL: firmware self test reported an error");
            errors = errors + 1;
        end
    end
end

// `loading` must never fall while bytes are still being pushed
reg loading_d;
always @(posedge clk) begin
    loading_d <= loading;
    if (loading_d && !loading && dut.rl_cnt != 0) begin
        $display("FAIL: loading fell with %0d bytes still buffered", dut.rl_cnt);
        errors = errors + 1;
    end
end

// ===========================================================================
integer i;
reg [7:0] b;

initial begin
    $dumpfile("sim/tb_iosys.vcd");
    $dumpvars(0, tb_iosys);

    repeat (10) @(posedge clk);
    resetn = 1;

    // wait for the two loads to have been announced
    wait (marks >= 6);
    repeat (200) @(posedge clk);

    $display("--- after both loads ---");
    check_eq(marks, 6, "marker count");
    check_eq(loading, 1'b0, "loading deasserted");
    check_eq(image_valid, 1'b1, "image_valid");
    check_eq(rom_sz, 8'h04, "rom_sz (0x40000 >> 16)");
    check_eq(rom_offset, 23'd0, "rom_offset (no copier header)");

    // the second image: 8 words of 0xA0A0A0A0 + i at byte address 0
    for (i = 0; i < 8; i = i + 1)
        check_eq(sd.mem[i], 32'hA0A0A0A0 + i, "second image word");

    // bytes 32..255 must still hold the tail of the first image, which proves
    // the write pointer restarted at 0 for the second load
    check_eq(sd.mem[8], 32'h23222120, "first image survives past the second");
    check_eq(sd.mem[63], 32'hFFFEFDFC, "last word of the first image");

    // ---- HuCard read port ------------------------------------------------
    $display("--- HuCard read port ---");
    read_rom(22'd0,  8'hA0);
    read_rom(22'd1,  8'hA0);
    read_rom(22'd4,  8'hA1);
    read_rom(22'd33, 8'h21);

    if (errors == 0)
        $display("\n*** tb_iosys PASSED ***");
    else
        $display("\n*** tb_iosys FAILED with %0d error(s) ***", errors);
    $finish;
end

task read_rom;
    input [21:0] a;
    input [7:0]  want;
    begin
        @(posedge clk);
        rom_a  <= a;
        rom_rd <= 1'b1;
        repeat (3) @(posedge clk);
        while (!rom_rdy) @(posedge clk);
        @(posedge clk);
        if (rom_do !== want) begin
            $display("FAIL rom[%0d] = %h, expected %h", a, rom_do, want);
            errors = errors + 1;
        end else begin
            $display("ok   rom[%0d] = %h", a, rom_do);
        end
        rom_rd <= 1'b0;
    end
endtask

initial begin
    #40_000_000;                 // 40 ms of simulated time
    $display("FAIL: timeout, markers seen = %0d", marks);
    $finish;
end

endmodule
