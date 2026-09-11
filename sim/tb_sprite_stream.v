//
// Stress test that reproduces the tightest VRAM0 access pattern the real
// HUC6270 uses when fetching sprite tile planes (SG0..SG3): RAM_RD stays
// asserted continuously (it is a level, not a pulse - see the combinational
// process around RAM_RD in rtl/huc6270.vhd) while RAM_A changes with every
// dot clock tick (clkref), the fastest case being one address per 4
// `clk` (43.2 MHz) cycles - see DOTCLOCK(1)='1' in rtl/huc6260.vhd.
//
// tb_iosys.v already checks two isolated back-to-back reads with a gap where
// vram_rd drops between them. This test instead holds vram_rd permanently
// high and streams dozens of tile fetches back-to-back (as a full sprite
// line would, up to 16 sprites x 4 words), with background refresh windows
// and PicoRV32/VDC1 channel-1 contention interleaved, to check whether the
// scheduler ever returns stale or corrupted data under sustained load.
//
// Caveat: sim/sdram_model.v is deliberately forgiving about SDRAM AC timing
// (see its header) - this test can catch logical/scheduling bugs but not a
// real chip's electrical timing violations.
//
`timescale 1ns/1ps

module tb_sprite_stream;

reg clk = 0;
reg clk_mem = 0;
reg clk_sdram = 0;
reg resetn = 0;

always #11.574 clk = ~clk;                     // 43.2 MHz
always #5.787 clk_mem = ~clk_mem;              // 86.4 MHz
always @(clk_mem) clk_sdram <= #5.787 clk_mem; // 180 degrees

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
reg         vram1_we   = 1'b0;
reg  [15:0] vram1_din  = 16'd0;
wire [15:0] vram1_dout;

reg         rv_valid = 1'b0;
wire        rv_ready;
reg  [22:0] rv_addr  = 23'd0;
wire [31:0] rv_rdata;

reg         refresh_window = 1'b0;
reg         clkref = 1'b0;

wire        sdram_init_done;

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

    .ld_wr         (1'b0),
    .ld_addr       (23'd0),
    .ld_data       (8'd0),
    .ld_busy       (),
    .ld_idle       (),
    .ld_active     (1'b0),

    .rom_rd        (1'b0),
    .rom_a         (22'd0),
    .rom_offset    (23'd0),
    .rom_do        (),
    .rom_rdy       (),

    .vram_addr     (vram_addr),
    .vram_din      (16'd0),
    .vram_dout     (vram_dout),
    .vram_rd       (vram_rd),
    .vram_we       (1'b0),

    .vram1_addr    (vram1_addr),
    .vram1_din     (vram1_din),
    .vram1_dout    (vram1_dout),
    .vram1_rd      (vram1_rd),
    .vram1_we      (vram1_we),

    .rv_valid      (rv_valid),
    .rv_ready      (rv_ready),
    .rv_addr       (rv_addr),
    .rv_wdata      (32'd0),
    .rv_wstrb      (4'd0),
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

// ===========================================================================
// Preload NUM_TILES synthetic sprite tiles, 4 words each (SG0..SG3), at
// well separated VRAM0 addresses so consecutive tiles land in different
// SDRAM rows (addr[14:9] changes), exactly like real sprite pattern data
// scattered across VRAM.
// ===========================================================================
localparam NUM_TILES = 40;
integer t, w;
reg [15:0] expect_word [0:NUM_TILES*4-1];

function [20:0] phys_word_addr;
    input [15:0] a;
    begin
        phys_word_addr = 21'h1FC000 + {6'd0, a[14:1]};
    end
endfunction

initial begin
    for (t = 0; t < NUM_TILES; t = t + 1) begin
        for (w = 0; w < 4; w = w + 1) begin
            // Spread tiles 64 words apart (bit 5:4 already used by SG
            // select in the real HUC6270 address formula), and give each
            // word a distinctive, easily recognisable pattern.
            expect_word[t*4+w] = {t[7:0], w[3:0], 4'hA};
        end
    end
end

integer errors = 0;
integer p;
reg [15:0] a;
reg [31:0] word32;

task preload_all;
    begin
        for (p = 0; p < NUM_TILES*4; p = p + 1) begin
            a = p * 64; // 64-word stride between fetch slots
            word32 = sd.mem[phys_word_addr(a)];
            if (a[0])
                word32[31:16] = expect_word[p];
            else
                word32[15:0] = expect_word[p];
            sd.mem[phys_word_addr(a)] = word32;
        end
    end
endtask

// ===========================================================================
// Background contention: occasional refresh windows and channel-1 (PicoRV32)
// traffic running concurrently with the VRAM0 sprite stream, exactly the
// kind of thing that competes with VDC0 for the scheduler's 8-phase slots.
// ===========================================================================
reg bg_run = 1'b0;
reg bg_rv  = 1'b0;
reg bg_ref = 1'b0;

initial begin
    forever begin
        @(posedge clk);
        if (bg_run && bg_rv && !rv_valid && ($random % 5 == 0)) begin
            rv_valid <= 1'b1;
            rv_addr  <= {$random} % 23'h100;
        end
        if (rv_valid && rv_ready)
            rv_valid <= 1'b0;
    end
end

initial begin
    forever begin
        repeat (37) @(posedge clk);
        if (bg_run && bg_ref) begin
            refresh_window <= 1'b1;
            repeat (6) @(posedge clk);
            refresh_window <= 1'b0;
        end
    end
end

// ===========================================================================
// Drive the fastest-mode SG0..SG3 style stream: vram_rd stays high for the
// whole run, vram_addr changes on a clkref pulse every 4 `clk` cycles.
// ===========================================================================
integer errcount_before;

task stream_all_tiles;
    input [255:0] label;
    begin
        errcount_before = errors;
        vram_rd <= 1'b1;
        for (p = 0; p < NUM_TILES*4; p = p + 1) begin
            @(negedge clk);
            vram_addr <= p * 64;
            clkref    <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            clkref <= 1'b0;
            repeat (4) @(posedge clk); // matches tb_iosys's read_vram_timed window
            if (vram_dout !== expect_word[p]) begin
                $display("FAIL %0s: tile word %0d (vram_addr=%h) = %h, expected %h",
                          label, p, p*64, vram_dout, expect_word[p]);
                errors = errors + 1;
            end
        end
        vram_rd <= 1'b0;
        if (errors == errcount_before)
            $display("ok   %0s: all %0d VRAM0 words correct", label, NUM_TILES*4);
    end
endtask

initial begin
    $dumpfile("sim/tb_sprite_stream.vcd");
    $dumpvars(0, tb_sprite_stream);

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (sdram_init_done);
    repeat (10) @(posedge clk);

    preload_all;
    repeat (5) @(posedge clk);

    $display("--- streaming %0d tiles, VRAM0 only, quiet bus ---", NUM_TILES);
    stream_all_tiles("quiet");

    $display("--- streaming %0d tiles, refresh_window contention only ---", NUM_TILES);
    bg_run = 1'b1; bg_ref = 1'b1; bg_rv = 1'b0;
    stream_all_tiles("refresh-only");
    bg_run = 1'b0;

    $display("--- streaming %0d tiles, channel-1 (PicoRV32) contention only ---", NUM_TILES);
    bg_run = 1'b1; bg_ref = 1'b0; bg_rv = 1'b1;
    stream_all_tiles("rv-only");
    bg_run = 1'b0;

    $display("--- streaming %0d tiles, with refresh + channel-1 contention ---", NUM_TILES);
    bg_run = 1'b1; bg_ref = 1'b1; bg_rv = 1'b1;
    stream_all_tiles("contended");
    bg_run = 1'b0;

    if (errors == 0)
        $display("\n*** tb_sprite_stream PASSED ***");
    else
        $display("\n*** tb_sprite_stream FAILED with %0d error(s) ***", errors);
    $finish;
end

endmodule
