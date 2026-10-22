`timescale 1ns/1ps
// Whole SNES core + top-level SDRAM glue: a tiny 4 MiB LoROM copies data from
// the high 256 KiB (SDRAM bank 2) and from low ROM into WRAM and VRAM, with
// DMA and with CPU FastROM reads. Run after a cold boot, then after
// "Reset Game" (game_reset pulse while paused, then a pause of PAUSE_BASE+k
// mclk), and check every destination byte in the SDRAM model.
module tb_snes_reset_dma #(
    parameter PAUSE_BASE = 4000,
    parameter RESETS = 8,
    parameter CHECK_SDRAM_PROTOCOL = 0
);
reg fclk = 0;
always #5.787 fclk = ~fclk;
reg [1:0] div = 0;
always @(posedge fclk) div <= div + 2'd1;
wire mclk = div[1];

reg resetn = 0;
reg game_reset = 0;
reg game_pause = 0;

wire [31:0] dq;
wire [10:0] sa;
wire [1:0] sba;
wire [3:0] sdqm;
wire scs, sras, scas, swe, scke;

top_tang_nano20k_snes dut (
    .sys_clk(1'b0), .s1(1'b0), .s2(1'b0), .uart_rx(1'b1), .pad_data(1'b1), .sd_dat0(1'b1),
    .flash_spi_miso(1'b1),
    .IO_sdram_dq(dq), .O_sdram_addr(sa), .O_sdram_ba(sba), .O_sdram_dqm(sdqm),
    .O_sdram_cs_n(scs), .O_sdram_ras_n(sras), .O_sdram_cas_n(scas),
    .O_sdram_wen_n(swe), .O_sdram_cke(scke)
);
sdram_model #(.READ_HOLD_CYCLES(1), .CHECK_OPEN_ROWS(CHECK_SDRAM_PROTOCOL)) memory (
    .DQ(dq), .A(sa), .BA(sba), .DQM(sdqm), .nCS(scs), .nRAS(sras), .nCAS(scas),
    .nWE(swe), .CKE(scke), .CLK(~fclk), .clk(fclk)
);

function [7:0] rom_byte(input [21:0] a);
    rom_byte = (a[7:0] * 8'd37) ^ a[15:8] ^ (a[21:16] * 8'h5b) ^ 8'h11;
endfunction
function [22:0] rom_phys(input [21:0] a);
    rom_phys = a[21:18] == 4'hf ? {1'b0, a} + 23'h200000 : {1'b0, a};
endfunction
task put_byte(input [22:0] p, input [7:0] v);
    reg [31:0] w;
    begin
        w = memory.mem[p >> 2];
        w[8 * p[1:0] +: 8] = v;
        memory.mem[p >> 2] = w;
    end
endtask
function [7:0] get_byte(input [22:0] p);
    reg [31:0] w;
    begin
        w = memory.mem[p >> 2];
        get_byte = w[8 * p[1:0] +: 8];
    end
endfunction

localparam [22:0] WRAM_PHYS = 23'h3e0000;
localparam [22:0] VRAM_PHYS = 23'h7f0000;

reg [7:0] prog [0:255];
integer plen;
task emit(input [7:0] b);
    begin prog[plen] = b; plen = plen + 1; end
endtask
task emit3(input [7:0] op, input [15:0] w);
    begin emit(op); emit(w[7:0]); emit(w[15:8]); end
endtask
task lda(input [7:0] v);
    begin emit(8'ha9); emit(v); end
endtask
task dma_src(input [7:0] bank);
    begin
        emit3(8'h9c, 16'h4302);
        lda(8'h80); emit3(8'h8d, 16'h4303);
        lda(bank); emit3(8'h8d, 16'h4304);
        emit3(8'h9c, 16'h4305);
        lda(8'h01); emit3(8'h8d, 16'h4306);
        emit3(8'h8d, 16'h420b);              // A = 1: start channel 0
    end
endtask

integer i;
initial begin
    plen = 0;
    emit(8'h78); emit(8'h18); emit(8'hfb); emit(8'he2); emit(8'h30);
    lda(8'h01); emit3(8'h8d, 16'h420d);       // FastROM
    emit3(8'h9c, 16'h2181); lda(8'h20); emit3(8'h8d, 16'h2182); emit3(8'h9c, 16'h2183);
    emit3(8'h9c, 16'h4300); lda(8'h80); emit3(8'h8d, 16'h4301);
    dma_src(8'hf8);                           // ROM 3C0000 -> WRAM 2000
    dma_src(8'h01);                           // ROM 008000 -> WRAM 2100
    lda(8'h80); emit3(8'h8d, 16'h2115);
    emit3(8'h9c, 16'h2116); emit3(8'h9c, 16'h2117);
    lda(8'h01); emit3(8'h8d, 16'h4300); lda(8'h18); emit3(8'h8d, 16'h4301);
    dma_src(8'hf8);                           // ROM 3C0000 -> VRAM 0000
    dma_src(8'h01);                           // ROM 008000 -> VRAM 0080
    emit(8'ha2); emit(8'h00);                 // LDX #0
    emit(8'hbf); emit(8'h00); emit(8'h81); emit(8'hf8);   // LDA $F88100,X
    emit(8'h9f); emit(8'h00); emit(8'h30); emit(8'h7e);   // STA $7E3000,X
    emit(8'he8); emit(8'hd0); emit(8'hf5);
    emit(8'hbf); emit(8'h00); emit(8'h81); emit(8'h01);   // LDA $018100,X
    emit(8'h9f); emit(8'h00); emit(8'h31); emit(8'h7e);   // STA $7E3100,X
    emit(8'he8); emit(8'hd0); emit(8'hf5);
    lda(8'ha5);
    emit(8'h8f); emit(8'h00); emit(8'h00); emit(8'h7e);   // STA $7E0000
    emit(8'h80); emit(8'hfe);
end

task load_rom;
    begin
        for (i = 0; i < 'h400; i = i + 1) begin
            put_byte(rom_phys(22'h3c0000 + i), rom_byte(22'h3c0000 + i));
            put_byte(rom_phys(22'h008000 + i), rom_byte(22'h008000 + i));
        end
        for (i = 0; i < 'h8000; i = i + 1)
            put_byte(i, 8'hea);
        for (i = 0; i < plen; i = i + 1)
            put_byte(i, prog[i]);
        put_byte(23'h7ffc, 8'h00);
        put_byte(23'h7ffd, 8'h80);
    end
endtask

task clear_destinations;
    begin
        put_byte(WRAM_PHYS, 8'h00);
        for (i = 0; i < 'h200; i = i + 1) begin
            put_byte(WRAM_PHYS + 'h2000 + i, 8'hee);
            put_byte(WRAM_PHYS + 'h3000 + i, 8'hee);
            put_byte(VRAM_PHYS + i, 8'hee);
        end
    end
endtask

integer errors_total = 0;
task check(input integer run);
    integer e_wh, e_wl, e_vh, e_vl, e_ch, e_cl;
    begin
        e_wh = 0; e_wl = 0; e_vh = 0; e_vl = 0; e_ch = 0; e_cl = 0;
        for (i = 0; i < 256; i = i + 1) begin
            if (get_byte(WRAM_PHYS + 'h2000 + i) !== rom_byte(22'h3c0000 + i)) begin
                if (e_wh < 4) $display("  DMA hi->WRAM [%0d] got %h exp %h", i,
                    get_byte(WRAM_PHYS + 'h2000 + i), rom_byte(22'h3c0000 + i));
                e_wh = e_wh + 1;
            end
            if (get_byte(WRAM_PHYS + 'h2100 + i) !== rom_byte(22'h008000 + i)) e_wl = e_wl + 1;
            if (get_byte(WRAM_PHYS + 'h3000 + i) !== rom_byte(22'h3c0100 + i)) begin
                if (e_ch < 4) $display("  CPU hi->WRAM [%0d] got %h exp %h", i,
                    get_byte(WRAM_PHYS + 'h3000 + i), rom_byte(22'h3c0100 + i));
                e_ch = e_ch + 1;
            end
            if (get_byte(WRAM_PHYS + 'h3100 + i) !== rom_byte(22'h008100 + i)) e_cl = e_cl + 1;
        end
        e_vh = vram_err;
        e_vl = vram_k == 512 ? 0 : 1;
        $display("run %0d: errors DMA hi->WRAM %0d lo->WRAM %0d ->VRAM latch %0d (count %0d) CPU hi %0d CPU lo %0d",
                 run, e_wh, e_wl, e_vh, vram_k, e_ch, e_cl);
        vram_err = 0; vram_k = 0;
        errors_total = errors_total + e_wh + e_wl + e_vh + e_vl + e_ch + e_cl;
    end
endtask

task wait_marker(input integer run);
    integer n;
    begin
        n = 0;
        while (get_byte(WRAM_PHYS) !== 8'ha5 && n < 400000) begin
            @(posedge mclk); n = n + 1;
        end
        if (n >= 400000) begin
            $display("run %0d: program did not finish", run);
            errors_total = errors_total + 1000;
        end
        repeat (200) @(posedge mclk);
    end
endtask

// DSP-like ARAM reads on SDRAM port 1 (the SMP/DSP are not simulated).
reg [15:0] aram_a = 0;
reg aram_ce_n = 1;
reg [2:0] aram_div = 0;
always @(posedge mclk) begin
    aram_div <= aram_div == 3'd5 ? 3'd0 : aram_div + 3'd1;
    if (aram_div == 3'd5 && dut.enable) begin
        aram_a <= aram_a + 16'd77;
        aram_ce_n <= 0;
    end else if (aram_div == 3'd2)
        aram_ce_n <= 1;
end

// The stub PPU does not write VRAM: check the bytes the real PPU would latch
// at SYSCLKF for $2118/$2119 instead.
integer vram_k = 0, vram_err = 0;
always @(posedge mclk)
    if (dut.enable && dut.core_resetn && dut.u_snes.SNES.INT_SYSCLKF_CE &&
        !dut.u_snes.SNES.INT_PAWR_N &&
        (dut.u_snes.SNES.INT_PA == 8'h18 || dut.u_snes.SNES.INT_PA == 8'h19)) begin
        if (dut.u_snes.SNES.PPU_DI !== (vram_k < 256 ? rom_byte(22'h3c0000 + vram_k)
                                                      : rom_byte(22'h008000 + vram_k - 256))) begin
            if (vram_err < 4) $display("  DMA ->VRAM latch [%0d] got %h exp %h", vram_k,
                dut.u_snes.SNES.PPU_DI, vram_k < 256 ? rom_byte(22'h3c0000 + vram_k)
                                                     : rom_byte(22'h008000 + vram_k - 256));
            vram_err = vram_err + 1;
        end
        vram_k = vram_k + 1;
    end

// Phase of the CPU/DMA clock versus the dot clock that drives the SDRAM slots.
reg [1:0] dma_dot_phase = 0;
always @(posedge mclk)
    if (dut.u_snes.SNES.CPU.DMA_ACTIVEr && dut.u_snes.SNES.CPU.DOT_CLK_CE && dut.core_resetn)
        dma_dot_phase <= dut.u_snes.SNES.CPU.DMA_CLK_CNT[1:0];

integer run;
initial begin
    force dut.mclk = mclk;
    force dut.fclk = fclk;
    force dut.sys_resetn = resetn;
    force dut.hdmi_locked = 1'b1;
    force dut.loading = 1'b0;
    force dut.image_valid = 1'b1;
    force dut.loaded = 1'b1;
    force dut.rom_hi_en = 1'b1;
    force dut.rom_type = 8'h00;
    force dut.rom_mask = 24'h3fffff;
    force dut.ram_mask = 24'h0;
    force dut.ld_wr = 1'b0;
    force dut.ld_data = 8'h0;
    force dut.game_reset = game_reset;
    force dut.game_pause = game_pause;
    force dut.button_reset = 1'b0;
    force dut.pause_snes_for_frame_sync = 1'b0;
    force dut.rv_valid = 1'b0;
    force dut.rv_addr = 23'h0;
    force dut.rv_wdata = 32'h0;
    force dut.rv_wstrb = 4'h0;
    force dut.snes_joy1_di = 2'b00;
    force dut.snes_joy2_di = 2'b00;
    force dut.osd_active = 1'b0;
    force dut.pad_buttons = 12'h0;
    force dut.ARAM_ADDR = aram_a;
    force dut.ARAM_CE_N = aram_ce_n;
    force dut.ARAM_OE_N = 1'b0;
    force dut.ARAM_WE_N = 1'b1;
    force dut.ARAM_D = 8'h00;

    load_rom;
    clear_destinations;
    game_pause = 1;
    repeat (8) @(posedge mclk);
    resetn = 1;
    wait (dut.sdram_busy === 1'b0);
    @(posedge mclk);
    game_pause = 0;                    // cold boot: the core starts at once
    wait_marker(0);
    $display("run 0 (cold boot): DMA/dot phase %0d", dma_dot_phase);
    check(0);

    for (run = 1; run <= RESETS; run = run + 1) begin
        game_pause = 1;
        repeat (100) @(posedge mclk);
        clear_destinations;
        @(posedge mclk) game_reset <= 1;
        @(posedge mclk) game_reset <= 0;
        repeat (PAUSE_BASE + run) @(posedge mclk);
        game_pause = 0;
        wait_marker(run);
        $display("run %0d (Reset Game, pause %0d mclk): DMA/dot phase %0d",
                 run, PAUSE_BASE + run, dma_dot_phase);
        check(run);
    end
    if (errors_total) $display("FAIL: %0d errors", errors_total);
    else $display("PASS");
    $finish;
end
endmodule
