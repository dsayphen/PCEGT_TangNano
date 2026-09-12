//
// Reproduces the "sprites shifted after reloading a game" bug at the
// pce_sdram_ctrl_3ch VDC bridge level.
//
// The VDC's RAM_RD output (rtl/huc6270.vhd, the combinational SLOT decoder)
// is a *level*, not a pulse: it defaults to '1' and only drops to '0' on
// write slots and the `others` slot. Crucially it is NOT gated by RST_N, so
// it keeps sitting high while the core is held in core_reset during a ROM
// reload.
//
// The bridge therefore detects a new VDC access either on a rising edge of
// vram_rd, or on `vram_addr != vram_addr_seen`. Since vram_rd never falls,
// only the address compare is left - and `vram_addr_seen` is reset solely by
// `resetn`, which on real hardware is asserted once at power-up and never
// again (rtl/top_tang_nano20k.v ties it to sys_resetn).
//
// First load:  vram_addr_seen == 16'hffff (bit 15 set, and the bridge ignores
//              addresses with bit 15 set) so it can never alias a real
//              address -> the first access of the new game always fires.
// Reload:      vram_addr_seen still holds a stale address from the *previous*
//              game. If the restarted VDC's first access targets that same
//              address, NO request is issued and the VDC latches whatever
//              vram_dout still held -> stale data.
//
// This test drives vram_rd exactly like the real RAM_RD (held high across the
// whole reload, never pulsed) and checks that an access to the stale address
// after the reload still fetches the *current* memory contents.
//
`timescale 1ns/1ps

module tb_vdc_stale_addr;

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
wire [15:0] vram1_dout;

reg         ld_active = 1'b0;
reg         vdc_reset = 1'b1;
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
    .ld_active     (ld_active),
    .vdc_reset     (vdc_reset),

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
    .vram1_din     (16'd0),
    .vram1_dout    (vram1_dout),
    .vram1_rd      (vram1_rd),
    .vram1_we      (1'b0),

    .rv_valid      (1'b0),
    .rv_ready      (),
    .rv_addr       (23'd0),
    .rv_wdata      (32'd0),
    .rv_wstrb      (4'd0),
    .rv_rdata      (),

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

function [20:0] phys_word_addr;
    input [15:0] a;
    begin
        phys_word_addr = 21'h1FC000 + {6'd0, a[14:1]};
    end
endfunction

function [20:0] phys_word_addr1;
    input [15:0] a;
    begin
        phys_word_addr1 = 21'h17C000 + {6'd0, a[14:1]};
    end
endfunction

task poke_vram0;
    input [15:0] a;
    input [15:0] v;
    reg [31:0] word32;
    begin
        word32 = sd.mem[phys_word_addr(a)];
        if (a[0]) word32[31:16] = v;
        else      word32[15:0]  = v;
        sd.mem[phys_word_addr(a)] = word32;
    end
endtask

task poke_vram1;
    input [15:0] a;
    input [15:0] v;
    reg [31:0] word32;
    begin
        word32 = sd.mem[phys_word_addr1(a)];
        if (a[0]) word32[31:16] = v;
        else      word32[15:0]  = v;
        sd.mem[phys_word_addr1(a)] = word32;
    end
endtask

integer errors = 0;

// One VDC memory slot: present the address, pulse clkref (the VDC's dot
// clock), let the scheduler run, then sample. vram_rd is deliberately NOT
// touched here - the caller owns it, so it can be held high forever like the
// real RAM_RD.
task vdc_slot0;
    input [15:0] a;
    begin
        @(negedge clk);
        vram_addr <= a;
        clkref    <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (4) @(posedge clk);
    end
endtask

task vdc_slot1;
    input [15:0] a;
    begin
        @(negedge clk);
        vram1_addr <= a;
        clkref     <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        clkref <= 1'b0;
        repeat (4) @(posedge clk);
    end
endtask

task check0;
    input [255:0] label;
    input [15:0] expected;
    begin
        if (vram_dout !== expected) begin
            $display("FAIL %0s: VRAM0 read = %h, expected %h", label, vram_dout, expected);
            errors = errors + 1;
        end else begin
            $display("ok   %0s: VRAM0 read = %h", label, vram_dout);
        end
    end
endtask

task check1;
    input [255:0] label;
    input [15:0] expected;
    begin
        if (vram1_dout !== expected) begin
            $display("FAIL %0s: VRAM1 read = %h, expected %h", label, vram1_dout, expected);
            errors = errors + 1;
        end else begin
            $display("ok   %0s: VRAM1 read = %h", label, vram1_dout);
        end
    end
endtask

// The address the restarted VDC lands on again after the reload. On real
// hardware this is simply whatever slot the VDC settles on while it is held
// in core_reset, which it then re-fetches as its first real access.
localparam [15:0] STALE_A = 16'h0100;
localparam [15:0] OTHER_A = 16'h0200;

initial begin
    $dumpfile("sim/tb_vdc_stale_addr.vcd");
    $dumpvars(0, tb_vdc_stale_addr);

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (sdram_init_done);
    repeat (10) @(posedge clk);

    // ---- "game 1" contents ----
    poke_vram0(OTHER_A, 16'hA001);
    poke_vram0(STALE_A, 16'hA002);
    poke_vram1(OTHER_A, 16'hB001);
    poke_vram1(STALE_A, 16'hB002);
    repeat (5) @(posedge clk);

    $display("--- game 1: VDC fetches, RAM_RD held high like the real core ---");
    vdc_reset <= 1'b0;          // core comes out of reset
    repeat (10) @(posedge clk);
    vram_rd  <= 1'b1;
    vram1_rd <= 1'b1;
    vdc_slot0(16'h0000); // warm-up slot: prime the read pipeline
    vdc_slot1(16'h0000);
    vdc_slot0(OTHER_A);  check0("game1-other", 16'hA001);
    vdc_slot0(STALE_A);  check0("game1-stale", 16'hA002);
    vdc_slot1(OTHER_A);  check1("game1-other", 16'hB001);
    vdc_slot1(STALE_A);  check1("game1-stale", 16'hB002);

    // -----------------------------------------------------------------
    // Reload. core_reset holds the VDC, but RAM_RD is combinational and
    // NOT reset-gated, so vram_rd/vram1_rd stay HIGH throughout, parked on
    // the address the slot decoder settles on. resetn is never touched.
    // -----------------------------------------------------------------
    $display("--- reload: ld_active high, vram_rd stays high (as RAM_RD does) ---");
    ld_active <= 1'b1;
    vdc_reset <= 1'b1;          // rst_trigger asserts core_reset
    repeat (400) @(posedge clk);

    // The new game writes different VRAM contents at the same addresses.
    poke_vram0(STALE_A, 16'hC0DE);
    poke_vram1(STALE_A, 16'hD00D);

    ld_active <= 1'b0;
    // core_reset lingers well past ld_active on real hardware (rst_cnt runs
    // for another 64k clocks), with RAM_RD still parked high.
    repeat (200) @(posedge clk);
    vdc_reset <= 1'b0;
    repeat (10) @(posedge clk);

    // -----------------------------------------------------------------
    // "Game 2" starts. Its first access targets the very address the bridge
    // last saw before the reload. vram_rd never fell, so there is no rising
    // edge either: the only thing that can trigger a fetch is the address
    // compare against the stale vram_addr_seen.
    // -----------------------------------------------------------------
    $display("--- game 2: first fetch hits the stale address ---");
    vdc_slot0(STALE_A);  check0("reload-stale", 16'hC0DE);
    vdc_slot1(STALE_A);  check1("reload-stale", 16'hD00D);

    if (errors == 0)
        $display("\n*** tb_vdc_stale_addr PASSED ***");
    else
        $display("\n*** tb_vdc_stale_addr FAILED with %0d error(s) ***", errors);
    $finish;
end

initial begin
    #6_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule
