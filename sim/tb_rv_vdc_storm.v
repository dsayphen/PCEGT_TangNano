//
// Does the softcore still read its own data when VDC0 goes berserk?
//
// When a game rewrites HDS/HDW in the middle of a frame (R-Type USA,
// Daimakaimura, Granzort do it for a raster split), the HuC6270 horizontal
// state machine is cut short by the VCE HSYNC and can drive RAM_A with a new
// address on consecutive `clk` cycles instead of one per dot.
//
// The VDC0 bridge in rtl/tang/pce_sdram_ctrl_3ch.v toggles vram_req on every
// address change without looking at whether the previous request is still in
// flight:
//
//     if (!vram_addr[15] && ((vram_we && ...) || (vram_rd && ...))) begin
//         vram_addr_r <= vram_addr[14:0];
//         vram_req    <= ~vram_req;        // no vram_req == vram_ack guard
//     end
//
// Two toggles inside one slot put req back in phase with ack, so the request
// disappears - and the scheduler's vram_ack/vram_pending, which gate both the
// refresh and channel 1, go out of step with reality. This test checks what
// that does to the PicoRV32 reads sharing the memory.
//
`timescale 1ns/1ps

module tb_rv_vdc_storm;

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

reg  [15:0] vram_addr  = 16'd0;
reg         vram_rd    = 1'b0;
wire [15:0] vram_dout;

reg  [15:0] vram1_addr = 16'd0;
reg         vram1_rd   = 1'b0;
wire [15:0] vram1_dout;

reg         rv_valid = 1'b0;
wire        rv_ready;
reg  [22:0] rv_addr  = 23'h400000;
wire [31:0] rv_rdata;

reg         clkref = 1'b0;
wire        sdram_init_done;

// ADPCM RAM writes. RV_IDLE serves adram_take_write before rv_valid, so a
// stuck or continuous ADPCM write stream would lock the softcore out without
// ever showing up in the channel-1 starvation counter.
reg  [16:0] adram_addr = 17'd0;
reg  [3:0]  adram_din  = 4'd0;
reg         adram_we   = 1'b0;
reg         adram_clken = 1'b0;
integer     adram_period = 0;   // 0 = idle, else one nibble every N clk

pce_sdram_ctrl_3ch #(.FREQ(86_400_000)) mem (
    .clk           (clk),
    .clk_mem       (clk_mem),
    .clk_sdram     (clk_sdram),
    .clkref        (clkref),
    .refresh_window(1'b0),
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
    .adram_dout    (),
    .adram_we      (adram_we),
    .adram_rd      (1'b0),
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

// ---------------------------------------------------------------------------
// The scheduler turns a 23-bit byte address into the SDRAM word index
// addr[22:2] ({BA, row, column}), which is how sdram_model indexes its array
// (same convention as sim/tb_sprite_stream.v).
// ---------------------------------------------------------------------------
localparam [22:0]  RV_LO    = 23'h400000;   // softcore RAM window, bank 2
localparam integer RV_WORDS = 512;

function [31:0] rv_expect;
    input [22:0] byte_addr;
    begin
        rv_expect = {~byte_addr[18:3], byte_addr[18:3]};
    end
endfunction

function [20:0] vram0_word;          // VDC0: {7'b1111111, addr, 1'b0} >> 2
    input [15:0] a;
    begin
        vram0_word = 21'h1FC000 + {6'd0, a[14:1]};
    end
endfunction

function [20:0] vram1_word;          // VDC1: {7'b1011111, addr, 1'b0} >> 2
    input [15:0] a;
    begin
        vram1_word = 21'h17C000 + {6'd0, a[14:1]};
    end
endfunction

integer i;
task preload;
    begin
        for (i = 0; i < RV_WORDS; i = i + 1)
            sd.mem[(RV_LO >> 2) + i] = rv_expect(RV_LO + i*4);
        for (i = 0; i < 4096; i = i + 1) begin
            sd.mem[vram0_word(i*2)] = 32'h0BAD0BAD;
            sd.mem[vram1_word(i*2)] = 32'h1BAD1BAD;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Softcore: back-to-back word reads, every reply checked.
// ---------------------------------------------------------------------------
integer rv_acks   = 0;
integer rv_errors = 0;
reg     counting  = 1'b0;

always @(posedge clk) begin
    if (!resetn) begin
        rv_valid <= 1'b0;
    end else if (sdram_init_done) begin
        if (!rv_valid)
            rv_valid <= 1'b1;
        else if (rv_ready) begin
            rv_valid <= 1'b0;
            if (counting) begin
                rv_acks = rv_acks + 1;
                if (rv_rdata !== rv_expect(rv_addr)) begin
                    if (rv_errors < 4)
                        $display("      softcore read %h = %h, expected %h",
                                 rv_addr, rv_rdata, rv_expect(rv_addr));
                    rv_errors = rv_errors + 1;
                end
            end
            rv_addr <= (rv_addr - RV_LO + 23'd4 >= RV_WORDS*4) ?
                       RV_LO : rv_addr + 23'd4;
        end
    end
end

// ---------------------------------------------------------------------------
// Dot clock: 6 clk per dot (7.16 MHz), clkref high 2 clk.
// ---------------------------------------------------------------------------
integer dots  = 0;
reg     storm = 1'b0;      // VDC0 puts up a new address on every clk
reg     vdc1_on = 1'b0;
reg [1:0] vm    = 2'b11;   // 11 = free running, 00/01 = real MWR VM slot order
reg [2:0] slot  = 3'd0;

// HuC6270 background fetch slots, transcribed from the VM case in
// rtl/huc6270.vhd:
//   VM=00 : CPU BAT CPU NOP CPU CG0 CPU CG1
//   VM=01 : NOP BAT NOP CPU NOP CG0 NOP CG1
// and from the RAM_A process, where a NOP slot drops RAM_RD *and* forces
// RAM_A to 0x0000 ("when others => RAM_RD <= '0'; RAM_A <= x\"0000\";").
// That idle address is what distinguishes the two, and what earlier versions
// of this test failed to model.
function slot_is_access;
    input [1:0] mode;
    input [2:0] s;
    begin
        slot_is_access = (mode == 2'b00) ? (s != 3'd3) : (s[0] == 1'b1);
    end
endfunction

always begin
    @(negedge clk);
    clkref <= 1'b1;
    if (vm == 2'b11) begin
        if (!storm) begin
            vram_addr <= vram_addr + 16'd2;
            if (vdc1_on) vram1_addr <= vram1_addr + 16'd2;
        end
    end else begin
        slot <= slot + 3'd1;
        if (slot_is_access(vm, slot + 3'd1)) begin
            vram_rd   <= 1'b1;
            vram_addr <= vram_addr + 16'd2;
        end else begin
            vram_rd   <= 1'b0;
            vram_addr <= 16'd0;
        end
        if (vdc1_on)
            vram1_addr <= vram1_addr + 16'd2;
    end
    dots = dots + 1;
    @(negedge clk);
    @(negedge clk);
    clkref <= 1'b0;
    repeat (3) @(negedge clk);
end

always @(negedge clk) begin
    if (storm) begin
        vram_addr <= vram_addr + 16'd2;
        if (vdc1_on) vram1_addr <= vram1_addr + 16'd2;
    end
end

integer errors = 0;
integer adram_cnt = 0;

always @(posedge clk) begin
    adram_clken <= 1'b0;
    adram_we    <= 1'b0;
    if (adram_period != 0) begin
        adram_cnt = adram_cnt + 1;
        if (adram_cnt >= adram_period) begin
            adram_cnt   = 0;
            adram_clken <= 1'b1;
            adram_we    <= 1'b1;
            adram_addr  <= adram_addr + 17'd1;
            adram_din   <= adram_din + 4'd1;
        end
    end
end

task measure;
    input [255:0] label;
    input         vdc0_storm;
    input         with_vdc1;
    input [1:0]   vm_mode;
    input integer ad_period;
    integer start_dots;
    begin
        storm    = vdc0_storm;
        vdc1_on  = with_vdc1;
        vm       = vm_mode;
        adram_period = ad_period;
        vram_rd  = 1'b1;
        vram1_rd = with_vdc1;
        repeat (40) @(posedge clk);
        rv_acks    = 0;
        rv_errors  = 0;
        counting   = 1'b1;
        start_dots = dots;
        while (dots - start_dots < 3000)
            @(posedge clk);
        counting = 1'b0;
        if (rv_errors)
            $display("FAIL %0s: %0d of %0d softcore reads corrupted",
                     label, rv_errors, rv_acks);
        else
            $display("ok   %0s: %0d softcore reads, all correct",
                     label, rv_acks);
        errors = errors + rv_errors;
    end
endtask

initial begin
    repeat (10) @(posedge clk);
    resetn = 1'b1;
    wait (sdram_init_done);
    preload;
    repeat (100) @(posedge clk);

    measure("VDC0 one address per dot          ", 1'b0, 1'b0, 2'b11, 0);
    measure("VDC0 one address per clk (storm)  ", 1'b1, 1'b0, 2'b11, 0);
    measure("VDC0+VDC1 one address per dot     ", 1'b0, 1'b1, 2'b11, 0);
    measure("VDC0+VDC1 one address per clk     ", 1'b1, 1'b1, 2'b11, 0);
    measure("VDC0 real slots, MWR VM=00 (works)", 1'b0, 1'b0, 2'b00, 0);
    measure("VDC0 real slots, MWR VM=01 (hangs)", 1'b0, 1'b0, 2'b01, 0);
    measure("VDC0+VDC1 real slots, VM=01       ", 1'b0, 1'b1, 2'b01, 0);
    measure("ADPCM nibble every 8 clk          ", 1'b0, 1'b0, 2'b11, 8);
    measure("ADPCM nibble every 4 clk          ", 1'b0, 1'b0, 2'b11, 4);
    measure("ADPCM nibble every 2 clk          ", 1'b0, 1'b0, 2'b11, 2);
    measure("ADPCM nibble every clk            ", 1'b0, 1'b0, 2'b11, 1);

    if (errors)
        $display("FAILED: %0d corrupted softcore reads", errors);
    else
        $display("PASSED");
    $finish;
end

endmodule
