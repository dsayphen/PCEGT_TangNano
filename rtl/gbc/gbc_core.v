//////////////////////////////////////////////////////////////////////////////////
// gbc_core - Game Boy / Game Boy Color core for the PCEGT Tang Nano 20K project
//
// Glue logic re-written from GBCandy Nano src/gbc_top.v
//   GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
//   Copyright (c) 2025-2026 Yulin Kuang  (GPL-3.0)
// which itself builds on VerilogBoy
//   Copyright (C) 2019 Wenting Zhang <zephray@outlook.com>  (GPL-3.0 or later)
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See rtl/gbc/LICENSE.
//
// Single clock domain (clk = 21.6 MHz). The GB clocks are clock enables:
//   ce_fast = 8.388608 MHz (double speed CPU T-cycle), ce_slow = 4.194304 MHz.
// Cartridge ROM / cart RAM / WRAM live in the external byte memory (SDRAM
// port B, see README.md for the protocol); every access goes through a
// single-outstanding memory interface unit (MIU). When the CPU needs external
// data that is not back yet, its clock enable is held (stall) and the lost
// enables are paid back afterwards ("owe" counter) so the average CPU speed
// stays correct.
//
// audio_l / audio_r are UNSIGNED: {1'b0, mix[8:0], 6'b0}, same format as the
// VerilogBoy `boy` sound outputs (rtl/gb/verilogboy/sound.v).
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ns
`default_nettype wire

module gbc_core #(
    parameter MEM_LAT = 5   // external read data valid MEM_LAT clk after mem_rd rises
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        pause,
    input  wire        cgb_enable,
    input  wire [7:0]  cart_type,
    input  wire [7:0]  rom_size,
    input  wire [7:0]  ram_size,
    input  wire [7:0]  buttons,      // 1 = pressed {start,select,b,a,down,up,left,right}

    output wire [21:0] mem_addr,
    output wire        mem_rd,
    output wire        mem_wr,
    output wire [7:0]  mem_wdata,
    input  wire [7:0]  mem_rdata,

    output wire        pix_valid,
    output wire [5:0]  pix_index,
    output wire        hsync,
    output wire        vsync,
    output wire        cgb_mode,
    output wire        pal_wr,
    output wire [6:0]  pal_wr_addr,
    output wire [7:0]  pal_wr_data,

    output wire [15:0] audio_l,
    output wire [15:0] audio_r
);

    // =========================================================================
    // Mode latch
    // =========================================================================
    reg cgb;
    always @(posedge clk)
        if (reset) cgb <= cgb_enable;
    assign cgb_mode = cgb;

    // =========================================================================
    // Clock enables: 21.6 MHz * 32768 / 84375 = 8.388608 MHz
    // =========================================================================
    reg [16:0] ce_acc;
    reg        ce_fast_r, ce_half;
    wire [16:0] ce_acc_inc = ce_acc + 17'd32768;
    always @(posedge clk) begin
        if (reset) begin
            ce_acc    <= 17'd0;
            ce_fast_r <= 1'b0;
            ce_half   <= 1'b0;
        end else begin
            ce_fast_r <= 1'b0;
            if (!pause) begin
                if (ce_acc_inc >= 17'd84375) begin
                    ce_acc    <= ce_acc_inc - 17'd84375;
                    ce_fast_r <= 1'b1;
                    ce_half   <= ~ce_half;
                end else
                    ce_acc <= ce_acc_inc;
            end
        end
    end
    wire ce_fast = ce_fast_r & ~pause;
    wire ce_slow = ce_fast & ce_half;      // 4.194304 MHz (PPU dot / APU / normal CPU)

    reg  double_speed;
    wire cpu_ce_raw = double_speed ? ce_fast : ce_slow;

    reg ce_slow_d;
    always @(posedge clk) ce_slow_d <= ce_slow;

    // =========================================================================
    // CPU
    // =========================================================================
    wire [15:0] cpu_a;
    wire [7:0]  cpu_dout;
    wire        cpu_rd, cpu_wr;
    wire [1:0]  cpu_ct;
    wire [4:0]  cpu_if_out;
    wire        cpu_speed_switch;
    reg  [7:0]  cpu_din;
    reg  [4:0]  if_r;
    reg  [7:0]  ie_r;
    reg         key1_prep;
    wire        cpu_en;

    gbc_cpu cpu (
        .clk(clk), .rst(reset), .enable(cpu_en),
        .phi(), .ct(cpu_ct), .a(cpu_a), .dout(cpu_dout), .din(cpu_din),
        .rd(cpu_rd), .wr(cpu_wr),
        .int_en(ie_r[4:0]), .int_flags_in(if_r), .int_flags_out(cpu_if_out),
        .key_in(buttons), .done(), .fault(), .stop(), .halt(),
        .cgb_speed_switch(cgb & key1_prep), .speed_switch(cpu_speed_switch),
        .d_opcode(), .d_pc(), .d_last_pc(), .d_bus_op(), .d_m_cycle(),
        .d_int_master_en(), .d_sp()
    );

    reg  cpu_wr_d;
    always @(posedge clk) cpu_wr_d <= reset ? 1'b0 : cpu_wr;
    wire wr_stb  = cpu_wr & ~cpu_wr_d;               // 1-clk CPU write strobe
    wire cpu_ct0 = cpu_en && cpu_ct == 2'd0;         // M-cycle start (new address)

    // Address decode
    reg  boot_en, boot_off_pend;
    wire a_boot  = boot_en && cpu_a[15:8] == 8'h00;
    wire a_rom   = !cpu_a[15] && !a_boot;
    wire a_vram  = cpu_a[15:13] == 3'b100;
    wire a_cram  = cpu_a[15:13] == 3'b101;
    wire a_wram  = cpu_a[15:14] == 2'b11 && cpu_a[15:9] != 7'h7F;   // C000-FDFF
    wire a_oam   = cpu_a[15:8] == 8'hFE && cpu_a[7:0] < 8'hA0;
    wire a_unus  = cpu_a[15:8] == 8'hFE && cpu_a[7:0] >= 8'hA0;
    wire a_io    = cpu_a[15:8] == 8'hFF;
    wire a_hram  = a_io && cpu_a[7] && cpu_a[6:0] != 7'h7F;
    wire a_ext   = a_rom || a_cram || a_wram;

    // =========================================================================
    // Cartridge mapper
    // =========================================================================
    reg  [15:0] miu_sel_a;
    wire [21:0] map_addr;
    wire        map_ff;
    gbc_cart_mapper mapper (
        .clk(clk), .reset(reset),
        .mapper_type(cart_type), .rom_size_code(rom_size), .ram_size_code(ram_size),
        .wr(wr_stb && !cpu_a[15]), .wr_addr(cpu_a), .wr_data(cpu_dout),
        .addr(miu_sel_a), .cart_addr(map_addr), .ff(map_ff)
    );

    // =========================================================================
    // External memory interface unit (one outstanding access)
    // =========================================================================
    localparam [1:0] OWN_CPUR = 2'd0, OWN_CPUW = 2'd1, OWN_DMA = 2'd2, OWN_HDMA = 2'd3;

    reg [2:0]  svbk;
    reg        miu_busy, miu_ffacc;
    reg [3:0]  miu_cnt;
    reg [1:0]  miu_owner;
    reg        mem_rd_r, mem_wr_r;
    reg [21:0] mem_addr_r;
    reg [7:0]  mem_wdata_r;
    assign mem_addr  = mem_addr_r;
    assign mem_rd    = mem_rd_r;
    assign mem_wr    = mem_wr_r;
    assign mem_wdata = mem_wdata_r;

`ifdef GBC_BREAK_LATENCY
    // negative-test hook only: samples the read data one clk too early
    localparam [3:0] DONE_CNT = MEM_LAT - 1;
`else
    localparam [3:0] DONE_CNT = MEM_LAT;
`endif
    wire miu_done = miu_busy && miu_cnt == DONE_CNT;
    wire miu_free = !miu_busy || miu_done;
    wire [7:0] miu_data = miu_ffacc ? 8'hFF : mem_rdata;

    // requesters
    reg         slot_valid;          // posted CPU write
    reg  [15:0] slot_a;
    reg  [7:0]  slot_d;
    reg         cpu_rd_issued, cpu_rd_ready;
    reg  [7:0]  cpu_rdata;
    reg         dma_need, dma_issued, dma_vram_pend;
    reg  [15:0] dma_src;
    reg         hdma_running, hdma_have, hdma_issued;
    reg  [11:0] hdma_src;
    reg  [3:0]  hdma_cnt;

    wire dma_src_vram = dma_src[15:13] == 3'b100;
    wire req_hdma = hdma_running && !hdma_have && !hdma_issued;
    wire req_dma  = dma_need && !dma_issued && !dma_src_vram;
    wire req_cpuw = slot_valid;
    wire req_cpur = cpu_rd && a_ext && !cpu_rd_issued && !cpu_rd_ready;
    wire miu_issue = miu_free && !pause && (req_hdma || req_dma || req_cpuw || req_cpur);

    reg [1:0] miu_sel_own;
    reg       miu_sel_wr;
    always @* begin
        if (req_hdma) begin
            miu_sel_own = OWN_HDMA; miu_sel_a = {hdma_src, hdma_cnt}; miu_sel_wr = 1'b0;
        end else if (req_dma) begin
            miu_sel_own = OWN_DMA;  miu_sel_a = dma_src;  miu_sel_wr = 1'b0;
        end else if (req_cpuw) begin
            miu_sel_own = OWN_CPUW; miu_sel_a = slot_a;   miu_sel_wr = 1'b1;
        end else begin
            miu_sel_own = OWN_CPUR; miu_sel_a = cpu_a;    miu_sel_wr = 1'b0;
        end
    end

    // WRAM: C000-CFFF bank 0, D000-DFFF bank SVBK (0->1) in CGB; echo E000-FDFF
    wire [2:0]  wram_bank = !miu_sel_a[12] ? 3'd0 :
                            (cgb && svbk != 3'd0) ? svbk : 3'd1;
    wire        sel_wram  = miu_sel_a[15:14] == 2'b11;
    wire        sel_vram  = miu_sel_a[15:13] == 3'b100;
    wire [21:0] sel_xaddr = sel_wram ? {7'b1111011, wram_bank, miu_sel_a[11:0]} : map_addr;
    wire        sel_ff    = sel_vram || (!sel_wram && map_ff);

    always @(posedge clk) begin
        if (reset) begin
            miu_busy  <= 1'b0;
            miu_ffacc <= 1'b0;
            miu_cnt   <= 4'd0;
            miu_owner <= OWN_CPUR;
            mem_rd_r  <= 1'b0;
            mem_wr_r  <= 1'b0;
            mem_addr_r  <= 22'd0;
            mem_wdata_r <= 8'd0;
        end else begin
            if (miu_busy && miu_cnt == 4'd1) begin
                mem_rd_r <= 1'b0;
                mem_wr_r <= 1'b0;
            end
            if (miu_busy && !miu_done)
                miu_cnt <= miu_cnt + 4'd1;
            if (miu_done)
                miu_busy <= 1'b0;
            if (miu_issue) begin
                miu_busy  <= 1'b1;
                miu_owner <= miu_sel_own;
                miu_ffacc <= sel_ff;
                if (sel_ff) begin
                    miu_cnt <= DONE_CNT;
                end else begin
                    miu_cnt     <= 4'd0;
                    mem_addr_r  <= sel_xaddr;
                    mem_wdata_r <= slot_d;
                    mem_rd_r    <= !miu_sel_wr;
                    mem_wr_r    <= miu_sel_wr;
                end
            end
        end
    end

    wire done_cpur = miu_done && miu_owner == OWN_CPUR;
    wire done_dma  = miu_done && miu_owner == OWN_DMA;
    wire done_hdma = miu_done && miu_owner == OWN_HDMA;
    wire grant_cpur = miu_issue && miu_sel_own == OWN_CPUR;
    wire grant_cpuw = miu_issue && miu_sel_own == OWN_CPUW;
    wire grant_dma  = miu_issue && miu_sel_own == OWN_DMA;
    wire grant_hdma = miu_issue && miu_sel_own == OWN_HDMA;

    // CPU external read / posted write bookkeeping
    always @(posedge clk) begin
        if (reset) begin
            cpu_rd_issued <= 1'b0;
            cpu_rd_ready  <= 1'b0;
            cpu_rdata     <= 8'hFF;
            slot_valid    <= 1'b0;
            slot_a        <= 16'd0;
            slot_d        <= 8'd0;
        end else begin
            if (grant_cpur) cpu_rd_issued <= 1'b1;
            if (done_cpur) begin
                cpu_rd_ready <= 1'b1;
                cpu_rdata    <= miu_data;
            end
            if (cpu_ct0) begin
                cpu_rd_issued <= 1'b0;
                cpu_rd_ready  <= 1'b0;
            end
            if (grant_cpuw) slot_valid <= 1'b0;
            if (wr_stb && (a_cram || a_wram)) begin
                slot_valid <= 1'b1;
                slot_a     <= cpu_a;
                slot_d     <= cpu_dout;
            end
        end
    end

    // =========================================================================
    // CPU clock enable with stall / pay-back
    // =========================================================================
    reg  [1:0] owe;
    reg        vq_ok;
    wire ext_wait  = cpu_ct == 2'd2 && cpu_rd && a_ext && !(cpu_rd_ready || done_cpur);
    wire vram_wait = cpu_ct == 2'd2 && cpu_rd && a_vram && !vq_ok;
    wire slot_wait = cpu_ct == 2'd0 && slot_valid;
    wire hdma_halt = cpu_ct == 2'd0 && hdma_running;
    wire stall = ext_wait || vram_wait || slot_wait || hdma_halt;
    assign cpu_en = (cpu_ce_raw || owe != 2'd0) && !stall && !pause;

    always @(posedge clk) begin
        if (reset)
            owe <= 2'd0;
        else if (!pause) begin
            if (cpu_ce_raw && stall && !hdma_halt) begin
                if (owe != 2'd3) owe <= owe + 2'd1;
            end else if (!cpu_ce_raw && owe != 2'd0 && !stall)
                owe <= owe - 2'd1;
        end
    end

    // =========================================================================
    // PPU
    // =========================================================================
    wire [12:0] ppu_vram_addr;
    wire [6:0]  ppu_oam_addr;
    wire        vram_acc_ext, oam_acc_ext;
    wire [7:0]  ppu_dout;
    wire        ppu_int_vblank, ppu_int_lcdc;
    wire [1:0]  ppu_pixel, ppu_color_idx, ppu_palette_id;
    wire [2:0]  ppu_cgb_pal;
    wire        ppu_valid, ppu_hs, ppu_vs;
    wire [1:0]  ppu_mode;
    wire [7:0]  ppu_ly, ppu_lcdc;
    reg  [7:0]  vram0_qb, vram1_qb;
    reg  [7:0]  oam_qe, oam_qo;
    reg         opri;

    wire ppu_wr = wr_stb && a_io && cpu_a[7:4] == 4'h4 && cpu_a[3:0] <= 4'hB;

    gbc_ppu ppu (
        .clk(clk), .rst(reset), .enable(ce_slow),
        .mmio_a(cpu_a), .mmio_dout(ppu_dout), .mmio_din(cpu_dout),
        .mmio_rd(cpu_rd), .mmio_wr(ppu_wr),
        .vram_a(16'd0), .vram_access_ext_out(vram_acc_ext), .vram_din(8'd0),
        .vram_rd(1'b0), .vram_wr(1'b0),
        .vram_addr_int_out(ppu_vram_addr), .vram_rd_int_out(), .vram_data_out_int(),
        .vram_data_in_int(vram0_qb), .vram_data_in_int_bank1(vram1_qb),
        .cgb_mode(cgb), .obj_prio_dmg_mode(cgb ? opri : 1'b1),
        .oam_a(16'd0), .oam_din(8'd0), .oam_wr(1'b0),
        .oam_access_ext_out(oam_acc_ext), .oam_addr_int_out(ppu_oam_addr), .oam_rd_int_out(),
        .oam_data_in_int({oam_qo, oam_qe}), .oam_data_out_int(), .oam_dout(),
        .int_vblank_req(ppu_int_vblank), .int_lcdc_req(ppu_int_lcdc),
        .int_vblank_ack(1'b1), .int_lcdc_ack(1'b1),
        .cpl(), .pixel(ppu_pixel), .valid(ppu_valid), .hs(ppu_hs), .vs(ppu_vs),
        .scx(), .scy(), .state(),
        .d_reg_lcdc(ppu_lcdc), .d_reg_stat(), .d_line(ppu_ly), .d_h_count(), .d_mode(ppu_mode),
        .d_reg_bgp(), .d_reg_obp0(), .d_reg_obp1(), .d_reg_lyc(),
        .cgb_palette_out(ppu_cgb_pal), .cgb_bg_priority_out(),
        .color_idx_out(ppu_color_idx), .palette_id_out(ppu_palette_id)
    );

    assign pix_valid = ppu_valid && ce_slow_d;
    assign pix_index = cgb ? {ppu_palette_id != 2'b00, ppu_cgb_pal, ppu_color_idx}
                           : {4'b0000, ppu_pixel};
    assign hsync = ppu_hs;
    assign vsync = ppu_vs;

    // =========================================================================
    // VRAM: 2 x 8 KiB true dual port (A: CPU/HDMA/OAM-DMA, B: PPU)
    // =========================================================================
    reg  vbk;
    wire vbk_eff = cgb & vbk;
    reg  [7:0] vram0 [0:8191];
    reg  [7:0] vram1 [0:8191];
    reg  [7:0] vram0_qa, vram1_qa;
    reg  [7:0] hdma_data;
    reg  [8:0] hdma_dst;

    wire cpu_vram_wr  = wr_stb && a_vram && vram_acc_ext;
    wire hdma_vram_wr = hdma_have && !cpu_vram_wr && !pause;
    wire dma_vram_rd  = dma_need && !dma_issued && !dma_vram_pend && dma_src_vram &&
                        !cpu_vram_wr && !hdma_vram_wr && !pause;
    wire [12:0] va_addr = hdma_vram_wr && !cpu_vram_wr ? {hdma_dst, hdma_cnt} :
                          dma_vram_rd ? dma_src[12:0] : cpu_a[12:0];
    wire [7:0]  va_din  = cpu_vram_wr ? cpu_dout : hdma_data;
    wire        va_we   = cpu_vram_wr || hdma_vram_wr;

    // Write-or-read keeps Gowin DPB in a supported write mode.
    always @(posedge clk) begin
        if (va_we && !vbk_eff) vram0[va_addr] <= va_din;
        else vram0_qa <= vram0[va_addr];
    end
    always @(posedge clk) begin
        if (va_we && vbk_eff) vram1[va_addr] <= va_din;
        else vram1_qa <= vram1[va_addr];
    end
    always @(posedge clk) vram0_qb <= vram0[ppu_vram_addr];
    always @(posedge clk) vram1_qb <= vram1[ppu_vram_addr];

    always @(posedge clk)
        vq_ok <= !hdma_vram_wr && !dma_vram_rd && !cpu_ct0;
    wire [7:0] vram_qa = vbk_eff ? vram1_qa : vram0_qa;

    // =========================================================================
    // OAM (160 B as 2 x 80 B, PPU reads 16-bit words) and OAM DMA
    // =========================================================================
    reg  [7:0] oam_e [0:79];
    reg  [7:0] oam_o [0:79];
    reg        dma_active;
    reg  [7:0] dma_idx;
    reg  [1:0] dma_tick;

    wire       dma_wr   = done_dma || dma_vram_pend;
    wire [7:0] dma_wd   = dma_vram_pend ? vram_qa : miu_data;
    wire       cpu_oam_wr = wr_stb && a_oam && oam_acc_ext && !dma_active;
    wire       oam_we   = dma_wr || cpu_oam_wr;
    wire [7:0] oam_wa   = dma_wr ? dma_idx : cpu_a[7:0];
    wire [7:0] oam_wd   = dma_wr ? dma_wd : cpu_dout;
    wire [6:0] oam_ra   = oam_acc_ext ? cpu_a[7:1] : ppu_oam_addr;

    always @(posedge clk) begin
        if (oam_we && !oam_wa[0]) oam_e[oam_wa[7:1]] <= oam_wd;
        if (oam_we &&  oam_wa[0]) oam_o[oam_wa[7:1]] <= oam_wd;
        oam_qe <= oam_e[oam_ra];
        oam_qo <= oam_o[oam_ra];
    end

    always @(posedge clk) begin
        if (reset) begin
            dma_active <= 1'b0;
            dma_need   <= 1'b0;
            dma_issued <= 1'b0;
            dma_idx    <= 8'd0;
            dma_tick   <= 2'd0;
            dma_src    <= 16'd0;
            dma_vram_pend <= 1'b0;
        end else begin
            dma_vram_pend <= dma_vram_rd;
            if (grant_dma || dma_vram_rd) dma_issued <= 1'b1;
            if (dma_wr) begin
                dma_need   <= 1'b0;
                dma_issued <= 1'b0;
                dma_idx    <= dma_idx + 8'd1;
                dma_src[7:0] <= dma_src[7:0] + 8'd1;
                if (dma_idx == 8'd159) dma_active <= 1'b0;
            end
            // one byte per M-cycle (4 CPU T-cycle enables)
            if (dma_active && cpu_ce_raw) begin
                dma_tick <= dma_tick + 2'd1;
                if (dma_tick == 2'd3 && !(dma_wr && dma_idx == 8'd159)) dma_need <= 1'b1;
            end
            if (wr_stb && a_io && cpu_a[7:0] == 8'h46) begin
                dma_active <= 1'b1;
                dma_need   <= 1'b0;
                dma_issued <= 1'b0;
                dma_idx    <= 8'd0;
                dma_tick   <= 2'd0;
                dma_src    <= {cpu_dout >= 8'hE0 ? cpu_dout - 8'h20 : cpu_dout, 8'h00};
            end
        end
    end

    // =========================================================================
    // HRAM (127 B) and CGRAM (2 x 64 B, CPU readback only; the colours are
    // exported through pal_wr*)
    // =========================================================================
    reg [7:0] hram [0:127];
    reg [7:0] hram_q;
    always @(posedge clk) begin
        if (wr_stb && a_hram) hram[cpu_a[6:0]] <= cpu_dout;
        hram_q <= hram[cpu_a[6:0]];
    end

    reg       bcps_inc, ocps_inc;
    reg [5:0] bcps_idx, ocps_idx;
    reg [7:0] bgpal  [0:63];
    reg [7:0] objpal [0:63];
    reg [7:0] bgpal_q, objpal_q;
    wire pal_cpu_wr_bg  = wr_stb && a_io && cpu_a[7:0] == 8'h69 && cgb;
    wire pal_cpu_wr_obj = wr_stb && a_io && cpu_a[7:0] == 8'h6B && cgb;
    wire pal_open = ppu_mode != 2'b11;
    always @(posedge clk) begin
        if (pal_cpu_wr_bg && pal_open)  bgpal[bcps_idx]  <= cpu_dout;
        if (pal_cpu_wr_obj && pal_open) objpal[ocps_idx] <= cpu_dout;
        bgpal_q  <= bgpal[bcps_idx];
        objpal_q <= objpal[ocps_idx];
    end

    reg       pal_wr_r;
    reg [6:0] pal_wr_addr_r;
    reg [7:0] pal_wr_data_r;
    always @(posedge clk) begin
        pal_wr_r <= !reset && pal_open && (pal_cpu_wr_bg || pal_cpu_wr_obj);
        pal_wr_addr_r <= pal_cpu_wr_obj ? {1'b1, ocps_idx} : {1'b0, bcps_idx};
        pal_wr_data_r <= cpu_dout;
    end
    assign pal_wr      = pal_wr_r;
    assign pal_wr_addr = pal_wr_addr_r;
    assign pal_wr_data = pal_wr_data_r;

    // =========================================================================
    // Timer, APU
    // =========================================================================
    wire [7:0] timer_dout;
    wire       timer_int;
    gbc_timer timer (
        .clk(clk), .rst(reset), .ce(cpu_ce_raw), .a(cpu_a), .dout(timer_dout),
        .din(cpu_dout), .rd(cpu_rd), .wr(wr_stb && a_io),
        .int_tim_req(timer_int), .int_tim_ack(1'b1)
    );

    wire [7:0] apu_dout;
    wire       apu_wr = wr_stb && a_io && cpu_a[7:6] == 2'b00 && cpu_a[5:4] != 2'b00;
    gbc_apu apu (
        .clk(clk), .resetn(!reset), .enable(ce_slow), .cgb_mode(cgb),
        .addr(cpu_a), .din(cpu_dout), .wr(apu_wr), .dout(apu_dout),
        .audio_l(audio_l), .audio_r(audio_r), .audio_ready()
    );

    // =========================================================================
    // IO registers
    // =========================================================================
    reg [1:0] p1_sel;
    reg [7:0] sb;
    reg       sc_start, sc_int;
    reg [11:0] sc_cnt;
    reg [7:0] ff72, ff73, ff74;
    reg [2:0] ff75;
    reg [7:0] hdma1, hdma2, hdma3, hdma4;
    reg       hdma_active, hdma_hblank;
    reg [6:0] hdma_blocks;
    reg       spd_sw_d;

    wire [3:0] joy_lo = ~(({4{!p1_sel[1]}} & buttons[7:4]) | ({4{!p1_sel[0]}} & buttons[3:0]));
    reg  [3:0] joy_lo_d;
    wire       joy_irq = |(joy_lo_d & ~joy_lo);

    reg vblank_d, lcdc_d, timer_d;
    wire irq_edges_vb = ppu_int_vblank & ~vblank_d;
    wire irq_edges_lc = ppu_int_lcdc   & ~lcdc_d;
    wire irq_edges_tm = timer_int      & ~timer_d;
    reg  serial_irq;
    wire [4:0] if_set = {joy_irq, serial_irq, irq_edges_tm, irq_edges_lc, irq_edges_vb};

    wire io_wr = wr_stb && a_io;
    wire [7:0] ioa = cpu_a[7:0];

    always @(posedge clk) begin
        if (reset) begin
            if_r <= 5'd0;
            ie_r <= 8'd0;
            vblank_d <= 1'b0; lcdc_d <= 1'b0; timer_d <= 1'b0;
            joy_lo_d <= 4'hF;
        end else begin
            vblank_d <= ppu_int_vblank;
            lcdc_d   <= ppu_int_lcdc;
            timer_d  <= timer_int;
            joy_lo_d <= joy_lo;
            if (cpu_en && cpu_if_out != if_r)
                if_r <= cpu_if_out | if_set;
            else if (io_wr && ioa == 8'h0F)
                if_r <= cpu_dout[4:0] | if_set;
            else
                if_r <= if_r | if_set;
            if (io_wr && ioa == 8'hFF) ie_r <= cpu_dout;
        end
    end

    // Joypad, serial (no link cable: internal-clock transfers shift in 0xFF)
    always @(posedge clk) begin
        if (reset) begin
            p1_sel <= 2'b11;
            sb <= 8'h00;
            sc_start <= 1'b0;
            sc_int <= 1'b0;
            sc_cnt <= 12'd0;
            serial_irq <= 1'b0;
        end else begin
            serial_irq <= 1'b0;
            if (sc_start && sc_int && ce_slow) begin
                sc_cnt <= sc_cnt + 12'd1;
                if (sc_cnt == 12'hFFF) begin
                    sc_start   <= 1'b0;
                    sb         <= 8'hFF;
                    serial_irq <= 1'b1;
                end
            end
            if (io_wr && ioa == 8'h00) p1_sel <= cpu_dout[5:4];
            if (io_wr && ioa == 8'h01) sb <= cpu_dout;
            if (io_wr && ioa == 8'h02) begin
                sc_start <= cpu_dout[7];
                sc_int   <= cpu_dout[0];
                sc_cnt   <= 12'd0;
            end
        end
    end

    // Boot ROM control, KEY1/double speed, VBK, SVBK, OPRI, FF72-75, CGRAM index
    always @(posedge clk) begin
        if (reset) begin
            boot_en <= 1'b1;
            boot_off_pend <= 1'b0;
            double_speed <= 1'b0;
            key1_prep <= 1'b0;
            spd_sw_d <= 1'b0;
            vbk <= 1'b0;
            svbk <= 3'd0;
            opri <= 1'b0;
            ff72 <= 8'd0; ff73 <= 8'd0; ff74 <= 8'd0; ff75 <= 3'd0;
            bcps_inc <= 1'b0; bcps_idx <= 6'd0;
            ocps_inc <= 1'b0; ocps_idx <= 6'd0;
        end else begin
            if (io_wr && ioa == 8'h50 && cpu_dout[0]) boot_off_pend <= 1'b1;
            if (boot_off_pend && cpu_rd && !cpu_a[15] && cpu_a[14:8] != 7'd0) boot_en <= 1'b0;

            spd_sw_d <= cpu_speed_switch;
            if (cpu_speed_switch && !spd_sw_d) begin
                double_speed <= ~double_speed;
                key1_prep <= 1'b0;
            end else if (io_wr && ioa == 8'h4D && cgb)
                key1_prep <= cpu_dout[0];

            if (io_wr && cgb) begin
                case (ioa)
                    8'h4F: vbk <= cpu_dout[0];
                    8'h70: svbk <= cpu_dout[2:0];
                    8'h6C: opri <= cpu_dout[0];
                    8'h74: ff74 <= cpu_dout;
                    8'h68: begin bcps_inc <= cpu_dout[7]; bcps_idx <= cpu_dout[5:0]; end
                    8'h6A: begin ocps_inc <= cpu_dout[7]; ocps_idx <= cpu_dout[5:0]; end
                    8'h69: if (bcps_inc) bcps_idx <= bcps_idx + 6'd1;
                    8'h6B: if (ocps_inc) ocps_idx <= ocps_idx + 6'd1;
                    default: ;
                endcase
            end
            if (io_wr && ioa == 8'h72) ff72 <= cpu_dout;
            if (io_wr && ioa == 8'h73) ff73 <= cpu_dout;
            if (io_wr && ioa == 8'h75) ff75 <= cpu_dout[6:4];
        end
    end

    // =========================================================================
    // HDMA / GDMA (CGB): source via MIU, destination VRAM bank VBK
    // =========================================================================
    reg [1:0] ppu_mode_d;
    always @(posedge clk) ppu_mode_d <= ppu_mode;
    wire hblank_start = ppu_mode_d == 2'b11 && ppu_mode == 2'b00 &&
                        ppu_lcdc[7] && ppu_ly < 8'd144;

    always @(posedge clk) begin
        if (reset) begin
            hdma1 <= 8'hFF; hdma2 <= 8'hFF; hdma3 <= 8'hFF; hdma4 <= 8'hFF;
            hdma_active  <= 1'b0;
            hdma_hblank  <= 1'b0;
            hdma_running <= 1'b0;
            hdma_have    <= 1'b0;
            hdma_issued  <= 1'b0;
            hdma_blocks  <= 7'h7F;
            hdma_src     <= 12'd0;
            hdma_dst     <= 9'd0;
            hdma_cnt     <= 4'd0;
            hdma_data    <= 8'd0;
        end else begin
            if (grant_hdma) hdma_issued <= 1'b1;
            if (done_hdma) begin
                hdma_issued <= 1'b0;
                hdma_have   <= 1'b1;
                hdma_data   <= miu_data;
            end
            if (hdma_vram_wr) begin
                hdma_have <= 1'b0;
                hdma_cnt  <= hdma_cnt + 4'd1;
                if (hdma_cnt == 4'hF) begin
                    hdma_src <= hdma_src + 12'd1;
                    hdma_dst <= hdma_dst + 9'd1;
                    if (hdma_blocks == 7'd0 || hdma_dst == 9'h1FF) begin
                        hdma_active  <= 1'b0;
                        hdma_running <= 1'b0;
                        hdma_blocks  <= 7'h7F;
                    end else begin
                        hdma_blocks <= hdma_blocks - 7'd1;
                        if (hdma_hblank) hdma_running <= 1'b0;
                    end
                end
            end
            if (hdma_active && hdma_hblank && !hdma_running && hblank_start && !pause)
                hdma_running <= 1'b1;

            if (io_wr && cgb) begin
                case (ioa)
                    8'h51: hdma1 <= cpu_dout;
                    8'h52: hdma2 <= cpu_dout;
                    8'h53: hdma3 <= cpu_dout;
                    8'h54: hdma4 <= cpu_dout;
                    8'h55: begin
                        if (hdma_active && hdma_hblank && !cpu_dout[7]) begin
                            hdma_active <= 1'b0;     // cancel (between blocks)
                        end else if (!hdma_active) begin
                            hdma_active  <= 1'b1;
                            hdma_hblank  <= cpu_dout[7];
                            hdma_blocks  <= cpu_dout[6:0];
                            hdma_src     <= {hdma1, hdma2[7:4]};
                            hdma_dst     <= {hdma3[4:0], hdma4[7:4]};
                            hdma_cnt     <= 4'd0;
                            hdma_running <= !cpu_dout[7] || !ppu_lcdc[7] || ppu_mode == 2'b00;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Boot ROM (homebrew, GBCandy: no Nintendo code). A = 0x11 in CGB mode.
    // =========================================================================
    reg [7:0] boot_q;
    always @* begin
        boot_q = 8'h00;
        if (cpu_a[7:6] == 2'b01 || (cpu_a[7:6] == 2'b00 && cpu_a[5:0] >= 6'h3B)) begin
            case (cpu_a[2:0])   // 0x3B..0x7A: 8 x {FF 7F B5 56 4A 29 00 00}
                3'd3: boot_q = 8'hFF; 3'd4: boot_q = 8'h7F;
                3'd5: boot_q = 8'hB5; 3'd6: boot_q = 8'h56;
                3'd7: boot_q = 8'h4A; 3'd0: boot_q = 8'h29;
                default: boot_q = 8'h00;
            endcase
            if (cpu_a[7:0] >= 8'h7B) boot_q = 8'h00;
        end else if (cpu_a[7:6] == 2'b00) begin
            case (cpu_a[5:0])
                6'h00: boot_q = 8'h3E; 6'h01: boot_q = 8'h00; 6'h02: boot_q = 8'hE0; 6'h03: boot_q = 8'h40;
                6'h04: boot_q = 8'hAF; 6'h05: boot_q = 8'hE0; 6'h06: boot_q = 8'h4F; 6'h07: boot_q = 8'h3E;
                6'h08: boot_q = 8'h01; 6'h09: boot_q = 8'hE0; 6'h0A: boot_q = 8'h70; 6'h0B: boot_q = 8'hAF;
                6'h0C: boot_q = 8'hE0; 6'h0D: boot_q = 8'h4D; 6'h0E: boot_q = 8'h3E; 6'h0F: boot_q = 8'hFC;
                6'h10: boot_q = 8'hE0; 6'h11: boot_q = 8'h47; 6'h12: boot_q = 8'h3E; 6'h13: boot_q = 8'h80;
                6'h14: boot_q = 8'hE0; 6'h15: boot_q = 8'h68; 6'h16: boot_q = 8'h21; 6'h17: boot_q = 8'h3B;
                6'h18: boot_q = 8'h00; 6'h19: boot_q = 8'h06; 6'h1A: boot_q = 8'h40; 6'h1B: boot_q = 8'h2A;
                6'h1C: boot_q = 8'hE0; 6'h1D: boot_q = 8'h69; 6'h1E: boot_q = 8'h05; 6'h1F: boot_q = 8'h20;
                6'h20: boot_q = 8'hFA; 6'h21: boot_q = 8'h3E; 6'h22: boot_q = 8'h80; 6'h23: boot_q = 8'hE0;
                6'h24: boot_q = 8'h6A; 6'h25: boot_q = 8'h21; 6'h26: boot_q = 8'h3B; 6'h27: boot_q = 8'h00;
                6'h28: boot_q = 8'h06; 6'h29: boot_q = 8'h40; 6'h2A: boot_q = 8'h2A; 6'h2B: boot_q = 8'hE0;
                6'h2C: boot_q = 8'h6B; 6'h2D: boot_q = 8'h05; 6'h2E: boot_q = 8'h20; 6'h2F: boot_q = 8'hFA;
                6'h30: boot_q = 8'h3E; 6'h31: boot_q = 8'h91; 6'h32: boot_q = 8'hE0; 6'h33: boot_q = 8'h40;
                6'h34: boot_q = 8'h3E; 6'h35: boot_q = cgb ? 8'h11 : 8'h01;
                6'h36: boot_q = 8'hE0; 6'h37: boot_q = 8'h50;
                6'h38: boot_q = 8'hC3; 6'h39: boot_q = 8'h00; 6'h3A: boot_q = 8'h01;
                default: boot_q = 8'h00;
            endcase
        end
    end

    // =========================================================================
    // CPU read data mux
    // =========================================================================
    reg [7:0] io_q;
    always @* begin
        io_q = 8'hFF;
        case (ioa)
            8'h00: io_q = {2'b11, p1_sel, joy_lo};
            8'h01: io_q = sb;
            8'h02: io_q = {sc_start, 6'h3F, sc_int};
            8'h04, 8'h05, 8'h06, 8'h07: io_q = timer_dout;
            8'h0F: io_q = {3'b111, if_r};
            8'h4D: io_q = cgb ? {double_speed, 6'h3F, key1_prep} : 8'hFF;
            8'h4F: io_q = cgb ? {7'h7F, vbk} : 8'hFF;
            8'h50: io_q = boot_en ? 8'hFF : 8'h7F;
            8'h55: io_q = cgb ? {~hdma_active, hdma_blocks} : 8'hFF;
            8'h68: io_q = cgb ? {bcps_inc, 1'b1, bcps_idx} : 8'hFF;
            8'h69: io_q = (cgb && pal_open) ? bgpal_q : 8'hFF;
            8'h6A: io_q = cgb ? {ocps_inc, 1'b1, ocps_idx} : 8'hFF;
            8'h6B: io_q = (cgb && pal_open) ? objpal_q : 8'hFF;
            8'h6C: io_q = cgb ? {7'h7F, opri} : 8'hFF;
            8'h70: io_q = cgb ? {5'h1F, svbk} : 8'hFF;
            8'h72: io_q = ff72;
            8'h73: io_q = ff73;
            8'h74: io_q = cgb ? ff74 : 8'hFF;
            8'h75: io_q = {1'b1, ff75, 4'hF};
            8'hFF: io_q = ie_r;
            default: begin
                if (ioa[7]) io_q = hram_q;
                else if (ioa[7:6] == 2'b00 && ioa[5:4] != 2'b00) io_q = apu_dout;
                else if (ioa[7:4] == 4'h4 && ioa[3:0] <= 4'hB) io_q = ppu_dout;
            end
        endcase
    end

    always @* begin
        if (a_boot)
            cpu_din = boot_q;
        else if (a_ext)
            cpu_din = done_cpur ? miu_data : cpu_rdata;
        else if (a_vram)
            cpu_din = (vram_acc_ext || cgb) ? vram_qa : 8'hFF;
        else if (a_oam)
            cpu_din = (oam_acc_ext && !dma_active) ? (cpu_a[0] ? oam_qo : oam_qe) : 8'hFF;
        else if (a_unus)
            cpu_din = 8'h00;
        else
            cpu_din = io_q;
    end

endmodule
