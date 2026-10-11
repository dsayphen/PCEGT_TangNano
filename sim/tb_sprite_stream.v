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

module tb_sprite_stream #(
    parameter FIXED_READ_CAPTURE = 1,
    parameter RV_READ_WRITE_GUARD = FIXED_READ_CAPTURE,
    parameter READ_HOLD_CYCLES = 3,
    parameter [22:0] LOADER_BASE = 23'h020000,
    parameter [1:0] VDC1_BANK = 2'd2,
    parameter [21:0] ROM_BASE = 22'd0
);

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
reg         vram_we   = 1'b0;
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
wire [63:0] rv_capture_dbg;
wire [127:0] rv_bus_dbg;
reg rom_test_rd = 1'b0;
reg [21:0] rom_test_addr = ROM_BASE;
wire [7:0] rom_test_data;
wire rom_test_ready;
reg rom_test_busy_seen = 1'b0;
integer rom_test_replies = 0;
integer rv_wait_cycles = 0;
integer rv_max_wait_cycles = 0;
integer rv_write_replies = 0;
reg [3:0] rv_test_wstrb = 4'd0;
reg [31:0] rv_test_wdata = 32'd0;
reg loader_write = 0;
reg [22:0] loader_addr = LOADER_BASE;
reg [7:0] loader_data = 0;
wire loader_busy;
wire loader_idle;
integer loader_sent = 0;
integer loader_check;
integer loader_drain_wait;

reg         refresh_window = 1'b0;
reg         clkref = 1'b0;

wire        sdram_init_done;

pce_sdram_ctrl_3ch #(
    .FREQ(86_400_000),
    .SGX_REFRESH_GUARD(1),
    .FIXED_READ_CAPTURE(FIXED_READ_CAPTURE),
    .RV_READ_WRITE_GUARD(RV_READ_WRITE_GUARD),
    .VDC1_BANK(VDC1_BANK)
) mem (
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

    .ld_wr         (loader_write),
    .ld_addr       (loader_addr),
    .ld_data       (loader_data),
    .ld_busy       (loader_busy),
    .ld_idle       (loader_idle),
    .ld_active     (1'b0),

    .rom_rd        (rom_test_rd),
    .rom_a         (rom_test_addr),
    .rom_offset    (23'd0),
    .rom_do        (rom_test_data),
    .rom_rdy       (rom_test_ready),

    .vram_addr     (vram_addr),
    .vram_din      (16'h03c0),
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
    .rv_wdata      (rv_test_wdata),
    .rv_wstrb      (rv_test_wstrb),
    .rv_rdata      (rv_rdata),
    .rv_capture_dbg(rv_capture_dbg),
    .rv_bus_dbg(rv_bus_dbg),

    .init_done     (sdram_init_done)
);

sdram_model #(.READ_HOLD_CYCLES(READ_HOLD_CYCLES)) sd (
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
reg [15:0] expect_word1 [0:NUM_TILES*4-1];

function [20:0] phys_word_addr;
    input [15:0] a;
    begin
        phys_word_addr = 21'h1FC000 + {6'd0, a[14:1]};
    end
endfunction

// Same fixed row/column pattern as VRAM0 in the selected VDC1 bank.
function [20:0] phys_word_addr1;
    input [15:0] a;
    begin
        phys_word_addr1 = {VDC1_BANK, 19'h7C000} + {6'd0, a[14:1]};
    end
endfunction

initial begin
    for (t = 0; t < NUM_TILES; t = t + 1) begin
        for (w = 0; w < 4; w = w + 1) begin
            // Spread tiles 64 words apart (bit 5:4 already used by SG
            // select in the real HUC6270 address formula), and give each
            // word a distinctive, easily recognisable pattern.
            expect_word[t*4+w] = {t[7:0], w[3:0], 4'hA};
            // Distinct pattern (nibble 5'hB instead of 5'hA) so a VRAM0/
            // VRAM1 cross-talk bug (e.g. one channel's data landing in the
            // other's output) is unambiguous in the failure message.
            expect_word1[t*4+w] = {t[7:0], w[3:0], 4'hB};
        end
    end
end

integer errors = 0;
integer p;
reg [15:0] a;
reg [31:0] word32;
integer urgent_refreshes = 0;
integer normal_refreshes = 0;
time last_urgent_refresh = 0;

always @(posedge clk_mem) begin
    if (mem.memory.cycle == 3'd1 && mem.memory.refresh_now) begin
        if (mem.memory.refresh_urgent) begin
            urgent_refreshes = urgent_refreshes + 1;
            last_urgent_refresh = $time;
        end else
            normal_refreshes = normal_refreshes + 1;
    end
end

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

task preload_all1;
    begin
        for (p = 0; p < NUM_TILES*4; p = p + 1) begin
            a = p * 64;
            word32 = sd.mem[phys_word_addr1(a)];
            if (a[0])
                word32[31:16] = expect_word1[p];
            else
                word32[15:0] = expect_word1[p];
            sd.mem[phys_word_addr1(a)] = word32;
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
integer capture_rv_replies = 0;
integer capture_mem_edges = 0;
integer last_rv_read_edge = -100;
integer channel1_cas_edge = 0;
integer vram_cas_edge = 0;
always @(negedge clk_mem) begin
    if ($test$plusargs("write_turnaround") && !O_sdram_cs_n) begin
        if ({O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} == 3'b101 && O_sdram_ba == 2'd2)
            last_rv_read_edge = capture_mem_edges;
        if ({O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} == 3'b100 &&
            O_sdram_ba == 2'd3 && capture_mem_edges - last_rv_read_edge < 3)
            $fatal(1, "RV READ followed by bank-3 WRITE after %0d clocks",
                   capture_mem_edges - last_rv_read_edge);
    end
end
reg checking_vdc1_writes = 1'b0;
always @(posedge clk_mem) begin
    if ($test$plusargs("write_turnaround") && mem.memory.active[2] &&
        ((FIXED_READ_CAPTURE != 0) ? mem.memory.vram_capture_delay == 1 :
                        mem.memory.cycle == 7) && mem.memory.we_latch[2]) begin
        if (((sd.mem[mem.memory.addr_latch[2] >> 2] >>
            (mem.memory.addr_latch[2][1] ? 16 : 0)) & 32'hffff) !== 32'h03c0)
            $fatal(1, "VDC0 write lost during RV turnaround");
    end
end

always @(posedge clk_mem) begin
    capture_mem_edges = capture_mem_edges + 1;
    if ($test$plusargs("capture_test")) begin
        if (mem.memory.cycle == 3 && mem.memory.active[1])
            channel1_cas_edge = capture_mem_edges;
        if (mem.memory.cycle == 4 && mem.memory.active[2])
            vram_cas_edge = capture_mem_edges;
        if (mem.memory.active[1] && ((FIXED_READ_CAPTURE != 0) ?
            mem.memory.channel1_capture_delay == 1 : mem.memory.cycle == 6) &&
            capture_mem_edges - channel1_cas_edge != 3) begin
            $display("FAIL channel1 CAS latency=%0d", capture_mem_edges - channel1_cas_edge);
            errors = errors + 1;
        end
        if (mem.memory.active[2] && ((FIXED_READ_CAPTURE != 0) ?
            mem.memory.vram_capture_delay == 1 : mem.memory.cycle == 7) &&
            capture_mem_edges - vram_cas_edge != 3) begin
            $display("FAIL VDC0 CAS latency=%0d", capture_mem_edges - vram_cas_edge);
            errors = errors + 1;
        end
    end
end

always @(negedge clk) begin
    if ($test$plusargs("capture_test") && rv_ready) begin
        capture_rv_replies = capture_rv_replies + 1;
        if (rv_test_wstrb != 0) begin
            rv_write_replies = rv_write_replies + 1;
            if (sd.mem[rv_addr >> 2] !== rv_test_wdata) begin
                $display("FAIL RV write addr=%h data=%h expected=%h", rv_addr,
                         sd.mem[rv_addr >> 2], rv_test_wdata);
                errors = errors + 1;
            end
        end else begin
            if (rv_rdata !== sd.mem[rv_addr >> 2]) begin
                $display("FAIL RV addr=%h data=%h expected=%h", rv_addr,
                         rv_rdata, sd.mem[rv_addr >> 2]);
                errors = errors + 1;
            end
            if (rv_capture_dbg !== {9'd0, rv_addr[22:2], 2'b00, rv_rdata}) begin
                $display("FAIL RV capture alignment addr=%h capture=%h data=%h",
                         rv_addr, rv_capture_dbg, rv_rdata);
                errors = errors + 1;
            end
            if (rv_bus_dbg[31:0] !== rv_rdata)
                $fatal(1, "Bus trace does not match RV capture");
        end
    end
end

always @(posedge clk_mem) begin
    if ($test$plusargs("capture_test") && !$test$plusargs("write_turnaround") && mem.memory.active[2] &&
        ((FIXED_READ_CAPTURE != 0) ? mem.memory.vram_capture_delay == 1 :
                                    mem.memory.cycle == 7)) begin
        #1;
        if (vram_dout !== expect_word[mem.memory.addr_latch[2][14:7]]) begin
            $display("FAIL VDC0 capture data=%h", vram_dout);
            errors = errors + 1;
        end
    end
end

always @(posedge clk_mem) begin
    if ($test$plusargs("capture_test") && !checking_vdc1_writes && mem.memory.active[1] &&
        mem.memory.channel1_port == 2 &&
        ((FIXED_READ_CAPTURE != 0) ? mem.memory.channel1_capture_delay == 1 :
                                    mem.memory.cycle == 6)) begin
        #1;
        if (vram1_dout !== expect_word1[mem.memory.addr_latch[1][14:7]]) begin
            $display("FAIL VDC1 capture data=%h", vram1_dout);
            errors = errors + 1;
        end
    end
end

initial begin
    forever begin
        @(posedge clk);
        if (bg_run && bg_rv && !rv_valid && ($random % 5 == 0)) begin
            rv_valid <= 1'b1;
            rv_addr  <= ($test$plusargs("transition_test") ? 23'h400000 : 23'd0) +
                        ({$random} % 23'h100);
            if ($test$plusargs("transition_test")) begin
                rv_test_wstrb <= ($random % 3 == 0) ? 4'b1111 : 4'd0;
                rv_test_wdata <= $random;
            end
        end
        if (rv_valid && rv_ready)
            rv_valid <= 1'b0;
    end
end

always @(negedge clk) begin
    if ($test$plusargs("transition_test") && bg_run) begin
        if (rv_valid && !rv_ready)
            rv_wait_cycles = rv_wait_cycles + 1;
        else
            rv_wait_cycles = 0;
        if (rv_wait_cycles > rv_max_wait_cycles)
            rv_max_wait_cycles = rv_wait_cycles;
        if (rv_wait_cycles > 20000)
            $fatal(1, "RV stalled: state=%d req=%b ack=%b cycle=%d owner=%d",
                   mem.rv_state, mem.rv_mem_req, mem.rv_mem_ack_sync[1],
                   mem.memory.cycle, mem.memory.channel1_port);
        rom_test_rd <= 1'b1;
        if (!rom_test_ready)
            rom_test_busy_seen <= 1'b1;
        if (rom_test_ready && rom_test_busy_seen) begin
            rom_test_busy_seen <= 1'b0;
            rom_test_replies = rom_test_replies + 1;
            if (rom_test_data !== (8'h60 + rom_test_addr[7:0])) begin
                $display("FAIL ROM addr=%h data=%h", rom_test_addr, rom_test_data);
                errors = errors + 1;
            end
            rom_test_addr <= ROM_BASE | ((rom_test_addr + 22'd4) & 22'h0000fc);
        end
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
            repeat (5) @(posedge clk);
            if (vram_dout !== expect_word[p]) begin
                if (errors == 0)
                    $display("refresh at first failure: urgent=%0d normal=%0d since_urgent=%0t", urgent_refreshes, normal_refreshes, $time - last_urgent_refresh);
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

// ===========================================================================
// SGX scenario: VDC0 and VDC1 both stream tiles concurrently at full dot
// clock rate, exactly as they do on real hardware once SGX_SUPPORT is
// active (both HUC6270 instances are clocked by the same VDC_CLKEN/clkref
// from the shared VCE, see rtl/pce_top_extram.vhd). No existing testbench
// before this one ever drove vram1_addr/vram1_rd while vram_addr/vram_rd
// were also live, so genuine VDC0+VDC1 concurrency was previously untested.
// ===========================================================================
task stream_both_vdcs;
    input [255:0] label;
    begin
        errcount_before = errors;
    // RAM_A and RAM_RD are driven by the same combinational process in
    // the real HUC6270 (see rtl/huc6270.vhd, the unclocked
    // process(SLOT, BG_RAM_ADDR, SPR_RAM_ADDR, ...) block): they always
    // change atomically together. Asserting *_rd here before setting
    // the first address would (unrealistically) present a stale
    // leftover address for one instant - match real hardware instead.
    @(negedge clk);
    vram_addr  <= 16'd0;
    vram1_addr <= 16'd0;
    vram_rd    <= 1'b1;
    vram1_rd   <= 1'b1;
    for (p = 0; p < NUM_TILES*4; p = p + 1) begin
        @(negedge clk);
        vram_addr  <= p * 64;
        vram1_addr <= p * 64;
        clkref     <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            clkref <= 1'b0;
            repeat (5) @(posedge clk);
            if (vram_dout !== expect_word[p]) begin
                $display("FAIL %0s: VDC0 tile word %0d (vram_addr=%h) = %h, expected %h",
                          label, p, p*64, vram_dout, expect_word[p]);
                errors = errors + 1;
            end
            if (vram1_dout !== expect_word1[p]) begin
                $display("FAIL %0s: VDC1 tile word %0d (vram1_addr=%h) = %h, expected %h",
                          label, p, p*64, vram1_dout, expect_word1[p]);
                errors = errors + 1;
            end
        end
        vram_rd  <= 1'b0;
        vram1_rd <= 1'b0;
        if (errors == errcount_before)
            $display("ok   %0s: all %0d VDC0+VDC1 words correct", label, NUM_TILES*4*2);
    end
endtask

task stream_blanked_lines;
    integer line_index;
    integer dot_index;
    integer word_index;
    integer errors_before;
    integer urgent_before;
    integer normal_before;
    begin
        errors_before = errors;
        urgent_before = urgent_refreshes;
        normal_before = normal_refreshes;
        for (line_index = 0; line_index < 3; line_index = line_index + 1) begin
            for (dot_index = 0; dot_index < 455; dot_index = dot_index + 1) begin
                @(negedge clk);
                word_index = (line_index * 360 + dot_index) % (NUM_TILES * 4);
                vram_rd <= dot_index < 360;
                vram_addr <= word_index * 64;
                if ($test$plusargs("blanked_both")) begin
                    vram1_rd <= dot_index < 360;
                    vram1_addr <= word_index * 64;
                end
                clkref <= 1'b1;
                @(posedge clk);
                @(negedge clk);
                clkref <= 1'b0;
                repeat (5) @(posedge clk);
                if (dot_index < 360 && vram_dout !== expect_word[word_index])
                    errors = errors + 1;
                if ($test$plusargs("blanked_both") && dot_index < 360 &&
                    vram1_dout !== expect_word1[word_index])
                    errors = errors + 1;
            end
        end
        $display("blanked: errors=%0d urgent=%0d normal=%0d debt_max=%0d",
                 errors - errors_before, urgent_refreshes - urgent_before,
                 normal_refreshes - normal_before, mem.memory.refresh_gap_max);
        vram_rd <= 1'b0;
        vram1_rd <= 1'b0;
    end
endtask

task stream_vce_transitions;
    integer line_index;
    integer line_cycle;
    integer clock_count;
    integer clock_divisor;
    integer dot_index;
    reg dot_pulse;
    begin
        clock_count = 0;
        dot_index = 0;
        for (line_index = 0; line_index < 18; line_index = line_index + 1) begin
            case (line_index % 6)
                0, 3: clock_divisor = 8;
                1, 5: clock_divisor = 6;
                default: clock_divisor = 4;
            endcase
            for (line_cycle = 0; line_cycle < 2730; line_cycle = line_cycle + 1) begin
                @(posedge clk);
                dot_pulse = 1'b0;
                if (clock_count == clock_divisor - 1 &&
                    (clock_divisor == 6 || line_cycle < 2727)) begin
                    clock_count = 0;
                    dot_pulse = 1'b1;
                end else
                    clock_count = (clock_count + 1) % 8;
                if (line_cycle == 2729) begin
                    clock_count = 0;
                    dot_pulse = 1'b1;
                end
                clkref <= dot_pulse;
                if (dot_pulse) begin
                    vram_addr <= $test$plusargs("vm01") && dot_index % 2 == 0 ?
                                 0 : (dot_index % 160) * 64;
                    vram1_addr <= (dot_index % 160) * 64;
                    vram_we <= $test$plusargs("write_turnaround") && line_cycle < 2200 && dot_index % 2 != 0;
                    vram_rd <= !$test$plusargs("write_turnaround") && line_cycle < 2200 &&
                               (!$test$plusargs("vm01") || dot_index % 2 != 0);
                    vram1_rd <= line_cycle < 2200 && dot_index % 2 == 0;
                    dot_index = dot_index + 1;
                end
            end
        end
        @(negedge clk);
        clkref = 1'b0;
        vram_rd = 1'b0;
        vram_we = 1'b0;
        vram1_rd = 1'b0;
        repeat (100) @(negedge clk);
        bg_run = 1'b0;
        if (rom_test_replies == 0 || capture_rv_replies == 0 || rv_write_replies == 0)
            $fatal(1, "No progress ROM=%0d RV=%0d", rom_test_replies, capture_rv_replies);
        $display("VCE transitions: lines=18 ROM=%0d RV=%0d writes=%0d max_wait_sys=%0d errors=%0d",
                 rom_test_replies, capture_rv_replies, rv_write_replies,
                 rv_max_wait_cycles, errors);
    end
endtask

always @(posedge clk) begin
    if ($test$plusargs("loader_test")) begin
        loader_write <= 0;
        if (bg_run && !loader_busy && !loader_write && loader_sent < 1024) begin
            loader_write <= 1;
            loader_addr <= LOADER_BASE + loader_sent;
            loader_data <= loader_sent[7:0];
            loader_sent = loader_sent + 1;
        end
    end
end

task check_vdc1_writes;
    integer write_index;
    reg [15:0] write_value;
    reg [31:0] stored_word;
    begin
        checking_vdc1_writes = 1'b1;
        for (write_index = 0; write_index < 4; write_index = write_index + 1) begin
            write_value = 16'hb120 + write_index;
            @(negedge clk);
            vram1_addr = 16'h7ff0 + write_index;
            vram1_din = write_value;
            vram1_we = 1'b1;
            clkref = 1'b1;
            @(negedge clk);
            clkref = 1'b0;
            repeat (12) @(negedge clk);
            stored_word = sd.mem[phys_word_addr1(vram1_addr)];
            if ((vram1_addr[0] ? stored_word[31:16] : stored_word[15:0]) !== write_value)
                $fatal(1, "VDC1 write mismatch bank=%0d addr=%h data=%h",
                       VDC1_BANK, vram1_addr, stored_word);
            vram1_we = 1'b0;
            vram1_rd = 1'b1;
            clkref = 1'b1;
            @(negedge clk);
            clkref = 1'b0;
            repeat (12) @(negedge clk);
            if (vram1_dout !== write_value)
                $fatal(1, "VDC1 readback mismatch addr=%h data=%h",
                       vram1_addr, vram1_dout);
            vram1_rd = 1'b0;
            repeat (4) @(negedge clk);
        end
        checking_vdc1_writes = 1'b0;
        $display("PASS VDC1 bank %0d writes/readback", VDC1_BANK);
    end
endtask

task stream_capture_test;
    input integer dot_sys_cycles;
    integer dot_index;
    integer replies_before;
    begin
        replies_before = capture_rv_replies;
        for (dot_index = 0; dot_index < 160; dot_index = dot_index + 1) begin
            @(negedge clk);
            vram_addr <= dot_index * 64;
            vram1_addr <= dot_index * 64;
            vram_rd <= 1'b1;
            vram1_rd <= dot_index % 2 == 0;
            clkref <= 1'b1;
            @(negedge clk);
            clkref <= 1'b0;
            repeat (dot_sys_cycles - 2) @(negedge clk);
        end
        if (capture_rv_replies == replies_before) begin
            $display("FAIL RV made no progress at period=%0d", dot_sys_cycles * 2);
            errors = errors + 1;
        end
        $display("capture period=%0d RV replies=%0d errors=%0d", dot_sys_cycles * 2,
                 capture_rv_replies - replies_before, errors);
    end
endtask

initial begin
    if (!$test$plusargs("capture_test")) begin
        $dumpfile("sim/tb_sprite_stream.vcd");
        $dumpvars(0, tb_sprite_stream);
    end

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (sdram_init_done);
    repeat (10) @(posedge clk);

    preload_all;
    repeat (5) @(posedge clk);

    if ($test$plusargs("capture_test")) begin
        preload_all1;
        check_vdc1_writes;
        for (t = 0; t < 64; t = t + 1)
            sd.mem[t] = 32'ha5c00000 + t;
        force mem.memory.need_refresh = 1'b0;
        bg_run = 1'b1;
        bg_rv = 1'b1;
        if ($test$plusargs("transition_test")) begin
            release mem.memory.need_refresh;
            for (t = 0; t < 64; t = t + 1) begin
                sd.mem[21'h100000 + t] = 32'ha5c00000 + t;
                sd.mem[(ROM_BASE >> 2) + t] = 32'h00000060 + t * 4;
            end
            stream_vce_transitions;
            if ($test$plusargs("loader_test")) begin
                loader_drain_wait = 0;
                while (!loader_idle && loader_drain_wait < 20000) begin
                    @(negedge clk);
                    loader_drain_wait = loader_drain_wait + 1;
                end
                if (!loader_idle || loader_sent != 1024)
                    $fatal(1, "Loader stalled bytes=%0d host_busy=%b cas_done=%b",
                           loader_sent, mem.host_busy, mem.memory.host_cas_done);
                for (loader_check = 0; loader_check < loader_sent; loader_check = loader_check + 1) begin
                    if (((sd.mem[(LOADER_BASE + loader_check) >> 2] >>
                        ((loader_check % 4) * 8)) & 32'hff) !== (loader_check & 255))
                        $fatal(1, "Loader byte mismatch at %0d", loader_check);
                end
                $display("PASS loader: %0d bytes verified", loader_sent);
            end
        end else begin
            stream_capture_test(4);
            stream_capture_test(6);
            stream_capture_test(8);
        end
        if (errors != 0)
            $fatal(1, "FAIL capture_test: %0d errors", errors);
        $display("PASS capture_test");
        $finish;
    end

    if ($test$plusargs("blanked")) begin
        if ($test$plusargs("blanked_both")) begin
            preload_all1;
            bg_run = 1'b1;
            bg_rv = 1'b1;
        end
        stream_blanked_lines;
        $finish;
    end

    if ($test$plusargs("no_urgent"))
        force mem.memory.refresh_urgent = 1'b0;

    $display("--- streaming %0d tiles, VRAM0 only, quiet bus ---", NUM_TILES);
    stream_all_tiles("quiet");

    if ($test$plusargs("no_urgent")) begin
        if (errors == 0 && urgent_refreshes == 0)
            $display("PASS no_urgent: 160 words, no refresh preemption");
        else
            $display("FAIL no_urgent: errors=%0d urgent=%0d", errors, urgent_refreshes);
        $finish;
    end

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

    preload_all1;
    repeat (30) @(posedge clk);

    $display("--- streaming %0d tiles on VDC0+VDC1 concurrently, quiet bus ---", NUM_TILES);
    stream_both_vdcs("both-quiet");

    $display("--- streaming %0d tiles on VDC0+VDC1 concurrently, with refresh + channel-1 contention ---", NUM_TILES);
    bg_run = 1'b1; bg_ref = 1'b1; bg_rv = 1'b1;
    stream_both_vdcs("both-contended");
    bg_run = 1'b0;

    if (errors == 0)
        $display("\n*** tb_sprite_stream PASSED ***");
    else
        $display("\n*** tb_sprite_stream FAILED with %0d error(s) ***", errors);
    $finish;
end

endmodule
