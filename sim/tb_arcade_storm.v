//
// Arcade Card RAM traffic (CPU side, one byte per WAIT_N handshake) together with
// the softcore, both VDCs and ADPCM writes. Checks that nobody is locked out and
// that no CD/Arcade RAM wait ever fails to end.
//
`timescale 1ns/1ps

module tb_arcade_storm;

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

reg         cd_rd = 1'b0, cd_wr = 1'b0;
reg  [21:0] cd_addr = 22'd0;
reg  [7:0]  cd_din = 8'd0;
wire [7:0]  cd_dout;
wire        cd_rdy;

reg  [16:0] adram_addr = 17'd0;
reg  [3:0]  adram_din  = 4'd0;
reg         adram_we   = 1'b0;
reg         adram_clken = 1'b0;
integer     adram_period = 0;

pce_sdram_ctrl_3ch #(.FREQ(86_400_000)) mem (
    .clk(clk), .clk_mem(clk_mem), .clk_sdram(clk_sdram),
    .clkref(clkref), .refresh_window(1'b0), .resetn(resetn),
    .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
    .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
    .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
    .IO_sdram_dq(IO_sdram_dq), .O_sdram_addr(O_sdram_addr),
    .O_sdram_ba(O_sdram_ba), .O_sdram_dqm(O_sdram_dqm),
    .ld_wr(1'b0), .ld_addr(23'd0), .ld_data(8'd0),
    .ld_busy(), .ld_idle(), .ld_active(1'b0),
    .rom_rd(1'b0), .rom_a(22'd0), .rom_offset(23'd0),
    .rom_do(), .rom_rdy(),
    .vram_addr(vram_addr), .vram_din(16'd0), .vram_dout(vram_dout),
    .vram_rd(vram_rd), .vram_we(1'b0),
    .vram1_addr(vram1_addr), .vram1_din(16'd0), .vram1_dout(vram1_dout),
    .vram1_rd(vram1_rd), .vram1_we(1'b0),
    .rv_valid(rv_valid), .rv_ready(rv_ready), .rv_addr(rv_addr),
    .rv_wdata(32'd0), .rv_wstrb(4'd0), .rv_rdata(rv_rdata),
    .cdram_rd(cd_rd), .cdram_wr(cd_wr), .cdram_addr(cd_addr),
    .cdram_din(cd_din), .cdram_dout(cd_dout), .cdram_rdy(cd_rdy),
    .adram_addr(adram_addr), .adram_din(adram_din), .adram_dout(),
    .adram_we(adram_we), .adram_rd(1'b0), .adram_clken(adram_clken),
    .init_done(sdram_init_done)
);

sdram_model sd (
    .DQ(IO_sdram_dq), .A(O_sdram_addr), .BA(O_sdram_ba), .nCS(O_sdram_cs_n),
    .nWE(O_sdram_wen_n), .nRAS(O_sdram_ras_n), .nCAS(O_sdram_cas_n),
    .CLK(O_sdram_clk), .CKE(O_sdram_cke), .DQM(O_sdram_dqm), .clk(clk_mem)
);

localparam [22:0]  RV_LO    = 23'h400000;
localparam integer RV_WORDS = 512;

function [31:0] rv_expect;
    input [22:0] byte_addr;
    begin
        rv_expect = {~byte_addr[18:3], byte_addr[18:3]};
    end
endfunction

function [20:0] vram0_word;
    input [15:0] a;
    begin vram0_word = 21'h1FC000 + {6'd0, a[14:1]}; end
endfunction

function [20:0] vram1_word;
    input [15:0] a;
    begin vram1_word = 21'h17C000 + {6'd0, a[14:1]}; end
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

// Softcore: reads in a loop, mem_valid low for one clk after every ready.
integer rv_acks = 0, rv_errors = 0, rv_last_ack_clk = 0, rv_max_gap = 0, clk_count = 0;
reg     counting = 1'b0;

always @(posedge clk) begin
    clk_count <= clk_count + 1;
    if (!resetn) begin
        rv_valid <= 1'b0;
    end else if (sdram_init_done) begin
        if (!rv_valid)
            rv_valid <= 1'b1;
        else if (rv_ready) begin
            rv_valid <= 1'b0;
            if (counting) begin
                rv_acks = rv_acks + 1;
                if (clk_count - rv_last_ack_clk > rv_max_gap)
                    rv_max_gap = clk_count - rv_last_ack_clk;
                rv_last_ack_clk = clk_count;
                if (rv_rdata !== rv_expect(rv_addr))
                    rv_errors = rv_errors + 1;
            end
            rv_addr <= (rv_addr - RV_LO + 23'd4 >= RV_WORDS*4) ?
                       RV_LO : rv_addr + 23'd4;
        end
    end
end

// Dot clock: 6 clk per dot (7.16 MHz). VDC0 follows the real MWR slot order,
// VDC1 optionally runs the same pattern.
integer dots = 0;
reg [1:0] vdc1_on = 2'd0;   // 0 off, 1 fetching on every access slot, 2 idle (RD toggles, address fixed)
reg [1:0] vm = 2'b00;
reg [2:0] slot = 3'd0;

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
    slot <= slot + 3'd1;
    if (slot_is_access(vm, slot + 3'd1)) begin
        vram_rd   <= 1'b1;
        vram_addr <= vram_addr + 16'd2;
        if (vdc1_on == 2'd1) begin
            vram1_rd   <= 1'b1;
            vram1_addr <= vram1_addr + 16'd2;
        end else if (vdc1_on == 2'd2) begin
            vram1_rd   <= 1'b1;
        end
    end else begin
        vram_rd   <= 1'b0;
        vram_addr <= 16'd0;
        vram1_rd  <= 1'b0;
        if (vdc1_on == 2'd1) vram1_addr <= 16'd0;
    end
    dots = dots + 1;
    @(negedge clk);
    @(negedge clk);
    clkref <= 1'b0;
    repeat (3) @(negedge clk);
end

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

// PCE CPU on Arcade RAM: hold the strobe, wait while cdram_rdy is low, then idle
// 5 clk (CPU_CE is one clk in six).
integer arc_ops = 0, arc_errors = 0, arc_wedged = 0, arc_max_lat = 0;
reg     arc_on = 1'b0;
reg [7:0] q;
integer lat;

function [7:0] pat;
    input [21:0] a;
    begin pat = a[7:0] ^ a[15:8] ^ 8'h5A; end
endfunction

task arc_access;
    input        is_wr;
    input [21:0] a;
    begin
        @(negedge clk);
        cd_addr = a;
        cd_din  = pat(a);
        if (is_wr) cd_wr = 1'b1; else cd_rd = 1'b1;
        repeat (4) @(posedge clk);
        lat = 0;
        while (!cd_rdy && lat < 4000) begin
            @(posedge clk);
            lat = lat + 1;
        end
        #1;
        q = cd_dout;
        if (lat >= 4000) arc_wedged = arc_wedged + 1;
        if (lat > arc_max_lat) arc_max_lat = lat;
        if (!is_wr && lat < 4000 && q !== pat(a)) arc_errors = arc_errors + 1;
        @(negedge clk);
        cd_wr = 1'b0;
        cd_rd = 1'b0;
        repeat (5) @(posedge clk);
        arc_ops = arc_ops + 1;
    end
endtask

reg [21:0] a;
reg [21:0] base = 22'd0;
integer n;
always begin
    wait (arc_on);
    base = {6'd0, base[15:6] + 10'd1, 6'd0};
    for (n = 0; n < 64; n = n + 1) begin
        a = base + n;
        if (!arc_on) n = 64;
        else arc_access(1'b1, a);
    end
    for (n = 0; n < 64; n = n + 1) begin
        a = base + n;
        if (!arc_on) n = 64;
        else arc_access(1'b0, a);
    end
end

integer errors = 0;

task measure;
    input [255:0] label;
    input         with_arc;
    input [1:0]   with_vdc1;
    input [1:0]   vm_mode;
    input integer ad_period;
    integer start_dots;
    begin
        vdc1_on = with_vdc1;
        vm = vm_mode;
        adram_period = ad_period;
        repeat (40) @(posedge clk);
        rv_acks = 0; rv_errors = 0; rv_max_gap = 0; rv_last_ack_clk = clk_count;
        arc_ops = 0; arc_errors = 0; arc_wedged = 0; arc_max_lat = 0;
        counting = 1'b1;
        arc_on = with_arc;
        start_dots = dots;
        while (dots - start_dots < 6000)
            @(posedge clk);
        arc_on = 1'b0;
        counting = 1'b0;
        $display("%0s rv=%0d (gap %0d clk, bad %0d)  arcade ops=%0d (max wait %0d clk, wedged %0d, bad %0d)",
                 label, rv_acks, rv_max_gap, rv_errors, arc_ops, arc_max_lat,
                 arc_wedged, arc_errors);
        if (rv_acks == 0 || rv_errors || arc_wedged || arc_errors ||
            (with_arc && arc_ops == 0))
            errors = errors + 1;
        repeat (2000) @(posedge clk);
    end
endtask

initial begin
    a = 22'd0;
    repeat (10) @(posedge clk);
    resetn = 1'b1;
    wait (sdram_init_done);
    preload;
    repeat (100) @(posedge clk);

    measure("RV only                        ", 1'b0, 2'd0, 2'b00, 0);
    measure("Arcade + RV                    ", 1'b1, 2'd0, 2'b00, 0);
    measure("Arcade + RV + VDC0 VM=01       ", 1'b1, 2'd0, 2'b01, 0);
    measure("Arcade + RV + idle VDC1 VM=00  ", 1'b1, 2'd2, 2'b00, 0);
    measure("Arcade + RV + idle VDC1 VM=01  ", 1'b1, 2'd2, 2'b01, 0);
    measure("Arcade + RV + both VDC VM=00   ", 1'b1, 2'd1, 2'b00, 0);
    measure("Arcade + RV + both VDC VM=01   ", 1'b1, 2'd1, 2'b01, 0);
    measure("Arcade + RV + ADPCM every 18   ", 1'b1, 2'd0, 2'b00, 18);
    measure("Arcade + RV + ADPCM + idle VDC1", 1'b1, 2'd2, 2'b01, 18);

    if (errors)
        $display("FAILED: %0d scenario(s)", errors);
    else
        $display("PASSED");
    $finish;
end

initial begin
    #300000000;
    $display("FAILED: timeout");
    $finish;
end

endmodule
