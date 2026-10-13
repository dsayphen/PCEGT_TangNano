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
`ifdef RECONFIG_INPUT_TEST
localparam RECONFIG_INPUT_ONLY_TEST = 1;
`else
localparam RECONFIG_INPUT_ONLY_TEST = 0;
`endif
`ifdef RECONFIG_PULSE_TEST
localparam RECONFIG_OUTPUT_TEST_MODE = 1;
localparam RECONFIG_PULSE_MS_TEST = 3000;
`else
localparam RECONFIG_OUTPUT_TEST_MODE = 0;
localparam RECONFIG_PULSE_MS_TEST = 3000;
`endif
localparam RECONFIG_PIN_TEST = 29;
`ifdef RECONFIG_TEST
localparam IOSYS_FREQ = 1000;
`else
localparam IOSYS_FREQ = 43_200_000;
`endif
localparam RECONFIG_TICKS_TEST = (IOSYS_FREQ / 1000) * RECONFIG_PULSE_MS_TEST;

reg clk = 0;
reg clk_mem = 0;
reg clk_sdram = 0;
reg resetn = 0;

always #11.574 clk = ~clk;              // 43.2 MHz
always #5.787 clk_mem = ~clk_mem;        // 86.4 MHz
always @(clk_mem) clk_sdram <= #5.787 clk_mem; // 180 degrees

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
reg  [15:0] vram_addr = 16'hffff;
reg  [15:0] vram_din = 16'd0;
wire [15:0] vram_dout;
reg         vram_rd = 1'b0;
reg         vram_we = 1'b0;
reg  [15:0] vram1_addr = 16'hffff;
reg  [15:0] vram1_din = 16'd0;
wire [15:0] vram1_dout;
reg         vram1_rd = 1'b0;
reg         vram1_we = 1'b0;
reg         clkref = 1'b0;
reg         refresh_window = 1'b0;

wire        osd_on;
wire [23:0] osd_rgb;
wire        osd_active;
wire        reload_pin;
wire        reload_pin_high;
wire        reload_pull_low;

`ifdef RECONFIG_TEST
`ifdef RECONFIG_INPUT_TEST
IBUF reload_ibuf (
    .I(reload_pin), .O(reload_pin_high)
);
`else
IOBUF reload_iobuf (
    .I(1'b0), .OEN(~reload_pull_low), .O(reload_pin_high), .IO(reload_pin)
);
`endif
`else
assign reload_pin = reload_pull_low ? 1'b0 : 1'bz;
assign reload_pin_high = reload_pin;
`endif

iosys #(
    .FREQ                (IOSYS_FREQ),
    .RECONFIG_ENABLE     (!RECONFIG_INPUT_ONLY_TEST),
    .RECONFIG_INPUT_ONLY (RECONFIG_INPUT_ONLY_TEST),
    .RECONFIG_PIN        (RECONFIG_PIN_TEST),
    .RECONFIG_OUTPUT_TEST (RECONFIG_OUTPUT_TEST_MODE),
    .RECONFIG_PULSE_MS   (RECONFIG_PULSE_MS_TEST),
    .FIRMWARE_FLASH_ADDR (24'h50_0000),
    .FIRMWARE_SIZE       (FIRMWARE_SIZE),
    .RV_BASE             (23'h40_0000)
) dut (
    .clk        (clk),
    .resetn     (resetn),
    .reconfig_pull_low (reload_pull_low),
    .reconfig_pin_high (reload_pin_high),

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

pce_sdram_ctrl_3ch #(.FREQ(86_400_000)) mem (
    .clk           (clk),
    .clk_mem       (clk_mem),
    .clk_sdram     (clk_sdram),
    .clkref        (clkref),
    .refresh_window(refresh_window),
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

    .vram_addr     (vram_addr),
    .vram_din      (vram_din),
    .vram_dout     (vram_dout),
    .vram_rd       (vram_rd),
    .vram_we       (vram_we),

    .vram1_addr    (vram1_addr),
    .vram1_din     (vram1_din),
    .vram1_dout    (vram1_dout),
    .vram1_rd      (vram1_rd),
    .vram1_we      (vram1_we),

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
    .clk  (clk_mem)
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
integer refreshes = 0;
reg [7:0] mark_log [0:15];
reg [7:0] cd_audio_log [0:7];
integer cd_audio_marks = 0;

always @(negedge clk) begin
    if (resetn && dut.cd_wr && !dut.cd_dm && cd_audio_marks < 8) begin
        cd_audio_log[cd_audio_marks] = dut.cd_data;
        cd_audio_marks = cd_audio_marks + 1;
    end
end

always @(negedge clk_mem)
    if (!O_sdram_cs_n && !O_sdram_ras_n &&
        !O_sdram_cas_n && O_sdram_wen_n)
        refreshes = refreshes + 1;

`ifndef RECONFIG_TEST
initial begin
    wait (dut.flash_loaded);
    repeat (10) @(posedge clk);
    check_eq(sd.mem[21'h100000], 32'h001f0137, "firmware word 0");
    check_eq(sd.mem[21'h100001], 32'h1f000513, "firmware word 1");
end
`endif

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

`ifdef RECONFIG_TEST
wire reload_pullup_source;
reg reload_pullup_enable = 1;
reg reload_external_low = 0;
pullup(reload_pullup_source);
tranif1(reload_pin, reload_pullup_source, reload_pullup_enable);
assign reload_pin = reload_external_low ? 1'b0 : 1'bz;

task reload_write;
    input [31:0] key;
    input [3:0] strobes;
    begin
        @(negedge clk);
        force dut.mem_addr = 32'h0200_00e8;
        force dut.mem_wdata = key;
        force dut.mem_wstrb = strobes;
        force dut.mem_valid = 1'b1;
        #1;
        check_eq(dut.mem_ready, 1, "reload register ready");
        @(posedge clk);
        #1;
        @(negedge clk);
        force dut.mem_valid = 1'b0;
    end
endtask

task check_reload;
    integer tick;
    begin
        force dut.mem_valid = 1'b0;
        force dut.flash_loaded = 1'b0;
        force dut.flash_pio_owned = 1'b0;
        force dut.flash_boot_cs_n = 1'b1;
        force dut.flash_pio_status = 32'd0;
        check_eq(reload_pin, 1, "reload pin idle released");
        reload_write(32'h52454346, 4'hf);
        check_eq(reload_pin, 1, "reload blocked during boot");
        force dut.flash_loaded = 1'b1;
        force dut.mem_addr = 32'h0200_00e0;
        force dut.mem_valid = 1'b1;
        force dut.mem_wstrb = 4'd0;
        #1;
        check_eq(dut.mem_rdata[9], !RECONFIG_INPUT_ONLY_TEST, "reload capability advertised");
        check_eq(dut.mem_rdata[10], RECONFIG_INPUT_ONLY_TEST, "input-only capability advertised");
        check_eq(dut.mem_rdata[11], RECONFIG_OUTPUT_TEST_MODE, "pulse-test capability advertised");
        force dut.mem_valid = 1'b0;
        reload_pullup_enable = 0;
        #1;
        if (reload_pin !== 1'bz)
            $fatal(1, "Idle Gowin IOBUF is not high impedance");
        reload_external_low = 1;
        repeat (3) @(posedge clk);
        force dut.mem_addr = 32'h0200_00e8;
        force dut.mem_valid = 1'b1;
        #1;
        check_eq(dut.mem_rdata[15:8], RECONFIG_PIN_TEST, "diagnostic GPIO number");
        check_eq(dut.mem_rdata[7:0], 0, "reload pin feedback external low");
        reload_external_low = 0;
        reload_pullup_enable = 1;
        repeat (3) @(posedge clk);
        #1;
        check_eq(dut.mem_rdata[7:0], 2, "reload pin feedback pulled high");
        force dut.mem_valid = 1'b0;
`ifdef RECONFIG_INPUT_TEST
        reload_write(32'h52454346, 4'hf);
        repeat (3) @(posedge clk);
        #1;
        check_eq(dut.reconfig_count, 0, "input-only rejects reload key");
        check_eq(dut.reconfig_pull_low, 0, "input-only output never enabled");
        check_eq(reload_pin, 1, "input-only pin stays pulled high");
        reload_pullup_enable = 0;
        #1;
        if (reload_pin !== 1'bz)
            $fatal(1, "Input-only GPIO26 has an unexpected driver");
        if (errors != 0)
            $fatal(1, "RECONFIG_INPUT_TEST FAILED: %0d errors", errors);
        $display("*** RECONFIG_INPUT_TEST PASSED ***");
        $finish;
`endif
        reload_write(32'd1, 4'hf);
        check_eq(reload_pin, 1, "invalid reload key rejected");
        reload_write(32'h52454346, 4'h1);
        check_eq(reload_pin, 1, "partial reload write rejected");
        force dut.flash_pio_owned = 1'b1;
        reload_write(32'h52454346, 4'hf);
        check_eq(reload_pin, 1, "reload blocked while flash owned");
        force dut.flash_pio_owned = 1'b0;
        force dut.flash_boot_cs_n = 1'b0;
        reload_write(32'h52454346, 4'hf);
        check_eq(reload_pin, 1, "reload blocked while flash selected");
        force dut.flash_boot_cs_n = 1'b1;
        force dut.flash_pio_status = 32'd1;
        reload_write(32'h52454346, 4'hf);
        check_eq(reload_pin, 1, "reload blocked while SPI busy");
        force dut.flash_pio_status = 32'd0;
        reload_write(32'h52454346, 4'hf);
        check_eq(reload_pin, 0, "reload pin asserted low");
        check_eq(dut.reconfig_count, RECONFIG_TICKS_TEST, "reload duration loaded");
        force dut.mem_valid = 1'b1;
        force dut.mem_wstrb = 4'd0;
        for (tick = 1; tick <= RECONFIG_TICKS_TEST; tick = tick + 1) begin
            @(posedge clk);
            #1;
            if (dut.reconfig_pull_low !== (tick < RECONFIG_TICKS_TEST))
                $fatal(1, "Reload duration mismatch at tick %0d", tick);
            if (tick == 3)
                check_eq(dut.mem_rdata[7:0], 1, "reload pin feedback during pulse");
        end
        check_eq(reload_pin, 1, "reload pin released after pulse");
        repeat (3) @(posedge clk);
        #1;
        check_eq(dut.mem_rdata[7:0], 2, "reload pin feedback after pulse");
        force dut.mem_valid = 1'b0;
        reload_write(32'h52454346, 4'hf);
        resetn = 0;
        #1;
        check_eq(reload_pin, 1, "reload pin released on reset");
        @(posedge clk);
        #1;
        check_eq(dut.reconfig_count, 0, "reload count cleared on reset");
        if (errors != 0)
            $fatal(1, "RECONFIG_TEST FAILED: %0d errors", errors);
        $display("*** RECONFIG_TEST PASSED ***");
        $finish;
    end
endtask
`endif

`ifdef AUDIO_MODE_RESET_TEST
task write_audio_mode;
    input [31:0] value;
    begin
        @(negedge clk);
        force dut.mem_valid = 1'b1;
        force dut.mem_addr = 32'h0200_0064;
        force dut.mem_wdata = value;
        force dut.mem_wstrb = 4'hf;
        @(posedge clk);
        #1;
        @(negedge clk);
        force dut.mem_valid = 1'b0;
    end
endtask

task check_audio_mode_reset;
    begin
        force dut.mem_valid = 1'b0;
        check_eq(dut.audio_hdmi, 0, "speaker default on FPGA startup");
        write_audio_mode(32'h0000755a);
        check_eq(dut.audio_hdmi, 1, "firmware selects HDMI");
        resetn = 0;
        repeat (8) @(posedge clk);
        #1;
        check_eq(dut.audio_hdmi, 1, "HDMI survives firmware reset");
        write_audio_mode(32'h0000655a);
        check_eq(dut.audio_hdmi, 1, "audio write ignored during reset");
        @(negedge clk);
        resetn = 1;
        repeat (4) @(posedge clk);
        #1;
        check_eq(dut.audio_hdmi, 1, "HDMI remains selected after reset");
        write_audio_mode(32'h0000655a);
        check_eq(dut.audio_hdmi, 0, "firmware can select speaker");
        resetn = 0;
        repeat (8) @(posedge clk);
        #1;
        check_eq(dut.audio_hdmi, 0, "speaker survives firmware reset");
        if (errors != 0)
            $fatal(1, "AUDIO_MODE_RESET_TEST FAILED: %0d errors", errors);
        $display("*** AUDIO_MODE_RESET_TEST PASSED ***");
        $finish;
    end
endtask
`endif

task check_cd_audio_feed;
    begin
        $display("--- CDDA word feed ---");
        @(negedge clk);
        force dut.mem_valid = 1'b1;
        force dut.mem_addr = 32'h0200_00b8;
        force dut.mem_wdata = 32'h44332211;
        force dut.mem_wstrb = 4'hf;
        @(posedge clk);
        #1;
        check_eq(dut.cd_audio_count, 4, "audio word accepted");
        @(negedge clk);
        force dut.mem_wdata = 32'h88776655;
        check_eq(dut.mem_ready, 1'b0, "second word stalled");
        wait (dut.mem_ready);
        @(posedge clk);
        #1;
        force dut.mem_valid = 1'b0;
        repeat (12) @(posedge clk);
        release dut.mem_valid;
        release dut.mem_addr;
        release dut.mem_wdata;
        release dut.mem_wstrb;
        check_eq(cd_audio_marks, 8, "audio byte count");
        check_eq(cd_audio_log[0], 8'h11, "audio byte 0");
        check_eq(cd_audio_log[1], 8'h22, "audio byte 1");
        check_eq(cd_audio_log[2], 8'h33, "audio byte 2");
        check_eq(cd_audio_log[3], 8'h44, "audio byte 3");
        check_eq(cd_audio_log[4], 8'h55, "audio byte 4");
        check_eq(cd_audio_log[5], 8'h66, "audio byte 5");
        check_eq(cd_audio_log[6], 8'h77, "audio byte 6");
        check_eq(cd_audio_log[7], 8'h88, "audio byte 7");
    end
endtask

`ifdef CD_AUDIO_TEST
initial begin
    wait (resetn);
    repeat (4) @(posedge clk);
    check_cd_audio_feed();
    if (errors == 0)
        $display("*** CD_AUDIO_TEST PASSED ***");
    else
        $display("*** CD_AUDIO_TEST FAILED with %0d error(s) ***", errors);
    $finish;
end
`endif

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
`ifdef DUMP_VCD
    $dumpfile("sim/tb_iosys.vcd");
    $dumpvars(0, tb_iosys);
`endif

    repeat (10) @(posedge clk);
    resetn = 1;

`ifdef AUDIO_MODE_RESET_TEST
    repeat (2) @(posedge clk);
    check_audio_mode_reset();
`endif

`ifdef RECONFIG_TEST
    repeat (2) @(posedge clk);
    check_reload();
`endif

    // wait for the two loads to have been announced
    wait (marks >= 6);
    wait (!loading);
    repeat (20) @(posedge clk);

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

    // ---- VDC0 bank-3 port ----------------------------------------------
    $display("--- VRAM0 port ---");
    write_vram(16'h0123, 16'hBEEF);
    read_vram(16'h0124, 16'h0000);
    read_vram(16'h0123, 16'hBEEF);
    check_eq(sd.mem[21'h1fc091], 32'hBEEF0000,
             "VRAM0 physical bank-3 word");
    sd.mem[21'h1fc100] = 32'h22221111;
    read_vram_timed(16'h0200, 16'h1111);
    read_vram_timed(16'h0201, 16'h2222);
    write_vram1(16'h0123, 16'hCAFE);
    read_vram1_timed(16'h0124, 16'h0000);
    read_vram1_timed(16'h0123, 16'hCAFE);
    check_eq(sd.mem[21'h17c091], 32'hCAFE0000,
             "VRAM1 physical bank-2 word");
    sd.mem[21'h1fc180] = 32'h00003333;
    sd.mem[21'h17c180] = 32'h00004444;
    read_both_vrams_timed(16'h0300, 16'h3333, 16'h4444);

    refresh_window = 1'b1;
    repeat (40) @(posedge clk);
    refresh_window = 1'b0;
    if (refreshes < 2) begin
        $display("FAIL refresh burst count = %0d", refreshes);
        errors = errors + 1;
    end else begin
        $display("ok   refresh burst count = %0d", refreshes);
    end

    check_cd_audio_feed();

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

task read_both_vrams_timed;
    input [15:0] a;
    input [15:0] want0;
    input [15:0] want1;
    begin
        @(negedge clk);
        vram_addr  <= a;
        vram1_addr <= a;
        vram_rd    <= 1'b1;
        vram1_rd   <= 1'b1;
        clkref     <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (4) @(posedge clk);
        if (vram_dout !== want0 || vram1_dout !== want1) begin
            $display("FAIL dual VRAM = %h/%h, expected %h/%h",
                     vram_dout, vram1_dout, want0, want1);
            errors = errors + 1;
        end else begin
            $display("ok   dual VRAM = %h/%h", vram_dout, vram1_dout);
        end
        vram_rd  <= 1'b0;
        vram1_rd <= 1'b0;
    end
endtask

task write_vram1;
    input [15:0] a;
    input [15:0] data;
    begin
        @(posedge clk);
        vram1_addr <= a;
        vram1_din  <= data;
        vram1_we   <= 1'b1;
        @(posedge clk);
        vram1_we   <= 1'b0;
        repeat (12) @(posedge clk);
    end
endtask

task read_vram1_timed;
    input [15:0] a;
    input [15:0] want;
    begin
        @(negedge clk);
        vram1_addr <= a;
        vram1_rd   <= 1'b1;
        clkref     <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (4) @(posedge clk);
        if (vram1_dout !== want) begin
            $display("FAIL timed vram1[%0h] = %h, expected %h",
                     a, vram1_dout, want);
            errors = errors + 1;
        end else begin
            $display("ok   timed vram1[%0h] = %h", a, vram1_dout);
        end
        vram1_rd <= 1'b0;
    end
endtask

task read_vram_timed;
    input [15:0] a;
    input [15:0] want;
    begin
        // Model a fastest-mode DCK_CE: the address changes with clkref and
        // must be returned before the fourth following 43.2 MHz edge.
        @(negedge clk);
        vram_addr <= a;
        vram_rd   <= 1'b1;
        clkref    <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (4) @(posedge clk);
        if (vram_dout !== want) begin
            $display("FAIL timed vram[%0h] = %h, expected %h",
                     a, vram_dout, want);
            errors = errors + 1;
        end else begin
            $display("ok   timed vram[%0h] = %h", a, vram_dout);
        end
        vram_rd <= 1'b0;
    end
endtask

task write_vram;
    input [15:0] a;
    input [15:0] data;
    begin
        @(posedge clk);
        vram_addr <= a;
        vram_din  <= data;
        vram_we   <= 1'b1;
        @(posedge clk);
        vram_we   <= 1'b0;
        repeat (12) @(posedge clk);
    end
endtask

task read_vram;
    input [15:0] a;
    input [15:0] want;
    begin
        @(negedge clk);
        vram_addr <= a;
        vram_rd   <= 1'b1;
        clkref    <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (12) @(posedge clk);
        if (vram_dout !== want) begin
            $display("FAIL vram[%0h] = %h, expected %h",
                     a, vram_dout, want);
            errors = errors + 1;
        end else begin
            $display("ok   vram[%0h] = %h", a, vram_dout);
        end
        vram_rd <= 1'b0;
    end
endtask

initial begin
    // The loader now clears the full 4 MiB HuCard area plus the 64 KiB VDC0
    // VRAM window byte-by-byte before every load (~4.26M cycles at 43.2 MHz,
    // i.e. ~99 ms), so the previous 40 ms budget was too tight to reach the
    // second load's markers even on a fully passing run.
    #220_000_000;                // 220 ms of simulated time
    $display("FAIL: timeout, markers seen = %0d", marks);
    $finish;
end

endmodule
