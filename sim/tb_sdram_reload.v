//
// Reproduces the "reload a ROM from the menu" scenario at the SDRAM
// controller level, exactly as it happens on real hardware:
//   - pce_sdram_ctrl_3ch's `resetn` is tied to sys_resetn only and is NEVER
//     pulsed again once the board is up (see rtl/top_tang_nano20k.v).
//   - `ld_active` (iosys' `loading`) goes high for the whole ROM transfer,
//     which also holds VDC0/VDC1/CPU in reset (`core_reset`) via
//     rst_trigger, but does NOT reset this module.
//   - VDC0 can have a genuinely in-flight VRAM0 request the instant
//     `ld_active` rises (worst case: reload requested mid-frame).
//
// This test streams VRAM0 sprite tile fetches (like tb_sprite_stream),
// injects a `ld_active` pulse while a request may still be in flight,
// simulates the loader/PicoRV32 channels being busy during the "reload"
// window (exactly what really happens: iosys keeps streaming ROM bytes and
// running firmware), then drops `ld_active` and resumes the VRAM0 stream -
// all without ever touching `resetn`. If the scheduler's internal state
// (active[]/we_latch/oe_latch/vram_ack) ever desyncs from vram_req across
// that boundary, the resumed stream will read back wrong words.
//
`timescale 1ns/1ps

module tb_sdram_reload;

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

reg         rv_valid = 1'b0;
wire        rv_ready;
reg  [22:0] rv_addr  = 23'd0;
wire [31:0] rv_rdata;

reg  [16:0] adram_addr = 17'd0;
reg  [3:0]  adram_din = 4'd0;
wire [3:0] adram_dout;
reg         adram_we = 0, adram_rd = 0, adram_clken = 0;

reg         ld_wr   = 1'b0;
reg  [22:0] ld_addr = 23'd0;
reg  [7:0]  ld_data = 8'd0;
wire        ld_busy;
reg         ld_active = 1'b0;

reg         refresh_window = 1'b0;
reg         clkref = 1'b0;

`ifdef ADPCM_TEST
reg [2:0] adpcm_slot = 0;
always @(negedge clk) begin
    adpcm_slot <= adpcm_slot + 1'b1;
    clkref <= (adpcm_slot == 3'd0);
end
`endif

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

    .ld_wr         (ld_wr),
    .ld_addr       (ld_addr),
    .ld_data       (ld_data),
    .ld_busy       (ld_busy),
    .ld_idle       (),
    .ld_active     (ld_active),

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

    .rv_valid      (rv_valid),
    .rv_ready      (rv_ready),
    .rv_addr       (rv_addr),
    .rv_wdata      (32'd0),
    .rv_wstrb      (4'd0),
    .rv_rdata      (rv_rdata),

    .adram_addr    (adram_addr),
    .adram_din     (adram_din),
    .adram_dout    (adram_dout),
    .adram_we      (adram_we),
    .adram_rd      (adram_rd),
    .adram_clken   (adram_clken),

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
// Preload NUM_TILES synthetic sprite tiles at VRAM0, and a couple of test
// words at VRAM1, same scheme as tb_sprite_stream.
// ===========================================================================
localparam NUM_TILES = 16;
integer t, w;
reg [15:0] expect_word [0:NUM_TILES*4-1];
reg [15:0] expect_word1 [0:NUM_TILES*4-1];

function [20:0] phys_word_addr;
    input [15:0] a;
    begin
        phys_word_addr = 21'h1FC000 + {6'd0, a[14:1]};
    end
endfunction

function [20:0] phys_word_addr1;
    input [15:0] a;
    begin
        // VRAM1/VDC1 RAS uses BA=2'b10 with row prefix 5'b11111, i.e. a
        // fixed 7-bit prefix of 7'b1011111 (0x5F) ahead of vram1_addr[14:1]
        // in the sdram_model's {BA,row,col} address space (0x5F << 14).
        phys_word_addr1 = 21'h17C000 + {6'd0, a[14:1]};
    end
endfunction

initial begin
    for (t = 0; t < NUM_TILES; t = t + 1) begin
        for (w = 0; w < 4; w = w + 1) begin
            expect_word[t*4+w]  = {t[7:0], w[3:0], 4'hA};
            expect_word1[t*4+w] = {t[7:0], w[3:0], 4'h5};
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
            a = p * 64;
            word32 = sd.mem[phys_word_addr(a)];
            if (a[0]) word32[31:16] = expect_word[p];
            else      word32[15:0] = expect_word[p];
            sd.mem[phys_word_addr(a)] = word32;

            word32 = sd.mem[phys_word_addr1(a)];
            if (a[0]) word32[31:16] = expect_word1[p];
            else      word32[15:0] = expect_word1[p];
            sd.mem[phys_word_addr1(a)] = word32;
        end
    end
endtask

task write_adpcm_nibble;
    input [16:0] addr;
    input [3:0] value;
    begin
        @(negedge clk);
        adram_addr = addr;
        adram_din = value;
        adram_we = 1'b1;
        adram_clken = 1'b1;
        @(negedge clk);
        adram_clken = 1'b0;
        adram_we = 1'b0;
    end
endtask

task check_adpcm_ram;
    integer sample;
    reg [31:0] stored_word;
    reg [7:0] expected_byte;
    begin
        $display("--- ADPCM SDRAM ---");
        write_adpcm_nibble(17'd0, 4'hA);
        write_adpcm_nibble(17'd1, 4'h5);
        write_adpcm_nibble(17'd2, 4'hC);
        write_adpcm_nibble(17'd3, 4'hD);
        repeat (80) @(posedge clk);
        $display("ADPCM bridge: pending=%b queued=%b rv_state=%d rv_addr=%h rv_ds=%h rv_we=%b word=%h",
             mem.adram_wr_pending, mem.adram_wr_queued, mem.rv_state,
             mem.rv_mem_addr, mem.rv_mem_ds, mem.rv_mem_we, sd.mem[21'h168000]);
        if (sd.mem[21'h168000][15:0] !== 16'hCDA5) begin
            $display("FAIL ADPCM bytes = %h, expected CDA5", sd.mem[21'h168000][15:0]);
            errors = errors + 1;
        end
        @(negedge clk);
        adram_addr = 17'd0;
        adram_rd = 1'b1;
        repeat (80) @(posedge clk);
        if (adram_dout !== 4'hA) begin
            $display("FAIL ADPCM high nibble = %h", adram_dout);
            errors = errors + 1;
        end
        @(negedge clk);
        adram_addr = 17'd1;
        #1;
        if (adram_dout !== 4'h5) begin
            $display("FAIL ADPCM low nibble = %h", adram_dout);
            errors = errors + 1;
        end
        adram_addr = 17'd2;
        #1;
        if (adram_dout !== 4'hC) begin
            $display("FAIL ADPCM next high nibble = %h", adram_dout);
            errors = errors + 1;
        end
        adram_addr = 17'd3;
        #1;
        if (adram_dout !== 4'hD) begin
            $display("FAIL ADPCM next low nibble = %h", adram_dout);
            errors = errors + 1;
        end
        adram_rd = 1'b0;

        for (sample = 2; sample < 34; sample = sample + 1) begin
            write_adpcm_nibble(sample * 2, sample[3:0]);
            write_adpcm_nibble(sample * 2 + 1, ~sample[3:0]);
            repeat (16) @(posedge clk);
        end
        repeat (120) @(posedge clk);
        for (sample = 2; sample < 34; sample = sample + 1) begin
            stored_word = sd.mem[21'h168000 + (sample / 4)];
            expected_byte = {sample[3:0], ~sample[3:0]};
            if (((stored_word >> ((sample % 4) * 8)) & 8'hff) !== expected_byte) begin
                $display("FAIL ADPCM burst byte %0d = %h, expected %h",
                         sample, (stored_word >> ((sample % 4) * 8)) & 8'hff,
                         expected_byte);
                errors = errors + 1;
            end
        end
    end
endtask

// ===========================================================================
// Simulated ROM/firmware traffic that keeps running throughout a reload,
// exactly like iosys really behaves: the loader channel (host_kind=LOADER)
// keeps writing bytes, and PicoRV32 keeps issuing rv_valid transactions the
// whole time `ld_active` is high.
// ===========================================================================
initial begin
    forever begin
        @(posedge clk);
        if (ld_active && !ld_wr && !ld_busy && ($random % 3 == 0)) begin
            ld_wr   <= 1'b1;
            ld_addr <= {$random} % 23'h1000;
            ld_data <= $random;
        end else begin
            ld_wr <= 1'b0;
        end
        if (ld_active && !rv_valid && ($random % 4 == 0)) begin
            rv_valid <= 1'b1;
            rv_addr  <= {$random} % 23'h100;
        end
        if (rv_valid && rv_ready)
            rv_valid <= 1'b0;
    end
end

task stream_all_tiles;
    input [255:0] label;
    input use_vram1;
    begin
        for (p = 0; p < NUM_TILES*4; p = p + 1) begin
            @(negedge clk);
            if (use_vram1) begin
                vram1_addr <= p * 64;
                vram1_rd   <= 1'b1;
            end else begin
                vram_addr <= p * 64;
                vram_rd   <= 1'b1;
            end
            clkref <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            clkref <= 1'b0;
            repeat (5) @(posedge clk);
            if (use_vram1) begin
                if (vram1_dout !== expect_word1[p]) begin
                    $display("FAIL %0s: VRAM1 tile word %0d (addr=%h) = %h, expected %h",
                              label, p, p*64, vram1_dout, expect_word1[p]);
                    errors = errors + 1;
                end
            end else begin
                if (vram_dout !== expect_word[p]) begin
                    $display("FAIL %0s: VRAM0 tile word %0d (addr=%h) = %h, expected %h",
                              label, p, p*64, vram_dout, expect_word[p]);
                    errors = errors + 1;
                end
            end
        end
        vram_rd  <= 1'b0;
        vram1_rd <= 1'b0;
        if (errors == 0)
            $display("ok   %0s: all %0d words correct", label, NUM_TILES*4);
    end
endtask

initial begin
    $dumpfile("sim/tb_sdram_reload.vcd");
    $dumpvars(0, tb_sdram_reload);

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (sdram_init_done);
    repeat (10) @(posedge clk);

    check_adpcm_ram;
`ifdef ADPCM_TEST
    if (errors == 0)
        $display("*** ADPCM_TEST PASSED ***");
    else
        $display("*** ADPCM_TEST FAILED with %0d error(s) ***", errors);
    $finish;
`endif

    preload_all;
    repeat (5) @(posedge clk);

    $display("--- first load: streaming VRAM0+VRAM1 before any reload ---");
    stream_all_tiles("first-load-vram0", 1'b0);
    stream_all_tiles("first-load-vram1", 1'b1);

    // -----------------------------------------------------------------
    // Kick off a reload right in the middle of a VRAM0 fetch, so a real
    // request may still be in flight in the scheduler when ld_active
    // rises - the worst case for req/ack desync. resetn is NEVER touched,
    // exactly like on real hardware.
    // -----------------------------------------------------------------
    $display("--- injecting reload mid-fetch (ld_active pulse, resetn untouched) ---");
    fork
        begin
            @(negedge clk);
            vram_addr <= 16'h0100;
            vram_rd   <= 1'b1;
            clkref    <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            clkref <= 1'b0;
        end
        begin
            repeat (2) @(posedge clk); // land inside the in-flight window
            ld_active <= 1'b1;
        end
    join

    // Loading + firmware/loader traffic runs for a while, just like a real
    // ROM transfer, with VDC0/VDC1 held in core_reset (no vram_rd/vram1_rd
    // issued) the whole time - matches real hardware behaviour.
    vram_rd  <= 1'b0;
    vram1_rd <= 1'b0;
    repeat (400) @(posedge clk);

    // core_reset drops a while after ld_active does on real hardware; give
    // some margin here too before the "new game" starts issuing requests.
    ld_active <= 1'b0;
    repeat (200) @(posedge clk);

    $display("--- after reload: streaming VRAM0+VRAM1 again (resetn was never pulsed) ---");
    preload_all; // "new game" writes the same known pattern back into VRAM
    repeat (5) @(posedge clk);
    stream_all_tiles("post-reload-vram0", 1'b0);
    stream_all_tiles("post-reload-vram1", 1'b1);

    if (errors == 0)
        $display("\n*** tb_sdram_reload PASSED ***");
    else
        $display("\n*** tb_sdram_reload FAILED with %0d error(s) ***", errors);
    $finish;
end

endmodule
