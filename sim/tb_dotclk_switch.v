//
// Every client of the SDRAM controller at once (PicoRV32, CPU ROM reads, Arcade RAM,
// VDC0, idle VDC1, ADPCM) while the dot period changes on the fly, the way a game
// reprograms the VCE dot clock. Checks per phase that nobody is starved and that
// every returned byte is right.
//
`timescale 1ns/1ps

module tb_dotclk_switch;

reg clk = 0;
reg clk_mem = 0;
reg clk_sdram = 0;
reg resetn = 0;

always #11.574 clk = ~clk;
always #5.787 clk_mem = ~clk_mem;
always @(clk_mem) clk_sdram <= #5.787 clk_mem;

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

reg         rom_rd = 1'b0;
reg  [21:0] rom_a = 22'd0;
wire [7:0]  rom_do;
wire        rom_rdy;

reg  [16:0] adram_addr = 17'd0;
reg  [3:0]  adram_din  = 4'd0;
reg         adram_we   = 1'b0;
reg         adram_clken = 1'b0;

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
    .rom_rd(rom_rd), .rom_a(rom_a), .rom_offset(23'd0),
    .rom_do(rom_do), .rom_rdy(rom_rdy),
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
localparam integer ROM_WORDS = 4096;

function [31:0] rv_expect;
    input [22:0] byte_addr;
    begin rv_expect = {~byte_addr[18:3], byte_addr[18:3]}; end
endfunction

function [31:0] rom_word;
    input integer i;
    begin rom_word = 32'hA0B1C2D3 ^ (i * 32'h9E3779B1); end
endfunction

function [7:0] rom_expect;
    input [21:0] a;
    reg [31:0] w;
    begin
        w = rom_word(a >> 2);
        rom_expect = w >> (8 * a[1:0]);
    end
endfunction

function [7:0] pat;
    input [21:0] a;
    begin pat = a[7:0] ^ a[15:8] ^ 8'h5A; end
endfunction

integer i;
task preload;
    begin
        for (i = 0; i < RV_WORDS; i = i + 1)
            sd.mem[(RV_LO >> 2) + i] = rv_expect(RV_LO + i*4);
        for (i = 0; i < ROM_WORDS; i = i + 1)
            sd.mem[i] = rom_word(i);
    end
endtask

// ---- counters, cleared at the start of every phase ----
integer rv_acks = 0, rv_errors = 0, rv_max_gap = 0, rv_last_ack = 0, clk_count = 0;
integer rom_ops = 0, rom_errors = 0, rom_wedged = 0, rom_max_lat = 0;
integer arc_ops = 0, arc_errors = 0, arc_wedged = 0, arc_max_lat = 0;
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
                if (clk_count - rv_last_ack > rv_max_gap)
                    rv_max_gap = clk_count - rv_last_ack;
                rv_last_ack = clk_count;
                if (rv_rdata !== rv_expect(rv_addr))
                    rv_errors = rv_errors + 1;
            end
            rv_addr <= (rv_addr - RV_LO + 23'd4 >= RV_WORDS*4) ?
                       RV_LO : rv_addr + 23'd4;
        end
    end
end

// ---- dot clock: clk per dot is changed on the fly by the phase sequencer ----
integer dot_clk = 6;
integer dots = 0;
reg [2:0] slot = 3'd0;

always begin
    @(negedge clk);
    clkref <= 1'b1;
    slot <= slot + 3'd1;
    if (slot != 3'd3) begin
        vram_rd   <= 1'b1;
        vram_addr <= vram_addr + 16'd2;
        vram1_rd  <= 1'b1;
    end else begin
        vram_rd   <= 1'b0;
        vram_addr <= 16'd0;
        vram1_rd  <= 1'b0;
    end
    dots = dots + 1;
    @(negedge clk);
    clkref <= 1'b0;
    repeat (dot_clk - 1) @(negedge clk);
end

// ---- ADPCM nibble stream ----
integer adram_cnt = 0;
always @(posedge clk) begin
    adram_clken <= 1'b0;
    adram_we    <= 1'b0;
    adram_cnt = adram_cnt + 1;
    if (adram_cnt >= 18) begin
        adram_cnt   = 0;
        adram_clken <= 1'b1;
        adram_we    <= 1'b1;
        adram_addr  <= adram_addr + 17'd1;
        adram_din   <= adram_din + 4'd1;
    end
end

// ---- CPU reads from ROM: sequential runs with jumps, one byte per WAIT_N handshake ----
reg [21:0] ra = 22'd0;
integer rn = 0;
integer rlat;
reg [7:0] rq;
always begin
    wait (resetn && sdram_init_done && counting);
    ra = (rn % 7 == 0) ? ((rn * 37) % 8000) : ra + 1;
    rn = rn + 1;
    @(negedge clk);
    rom_a = ra;
    rom_rd = 1'b1;
    repeat (4) @(posedge clk);
    rlat = 0;
    while (!rom_rdy && rlat < 4000) begin
        @(posedge clk);
        rlat = rlat + 1;
    end
    #1;
    rq = rom_do;
    if (rlat >= 4000) rom_wedged = rom_wedged + 1;
    if (rlat > rom_max_lat) rom_max_lat = rlat;
    if (rlat < 4000 && rq !== rom_expect(ra)) rom_errors = rom_errors + 1;
    @(negedge clk);
    rom_rd = 1'b0;
    repeat (5) @(posedge clk);
    rom_ops = rom_ops + 1;
end

// ---- CPU accesses to Arcade RAM ----
reg [21:0] aa;
reg [21:0] abase = 22'd0;
integer an;
integer alat;
reg [7:0] aq;

task arc_access;
    input        is_wr;
    input [21:0] a;
    begin
        @(negedge clk);
        cd_addr = a;
        cd_din  = pat(a);
        if (is_wr) cd_wr = 1'b1; else cd_rd = 1'b1;
        repeat (4) @(posedge clk);
        alat = 0;
        while (!cd_rdy && alat < 4000) begin
            @(posedge clk);
            alat = alat + 1;
        end
        #1;
        aq = cd_dout;
        if (alat >= 4000) arc_wedged = arc_wedged + 1;
        if (alat > arc_max_lat) arc_max_lat = alat;
        if (!is_wr && alat < 4000 && aq !== pat(a)) arc_errors = arc_errors + 1;
        @(negedge clk);
        cd_wr = 1'b0;
        cd_rd = 1'b0;
        repeat (5) @(posedge clk);
        arc_ops = arc_ops + 1;
    end
endtask

always begin
    wait (resetn && sdram_init_done && counting);
    abase = {6'd0, abase[15:6] + 10'd1, 6'd0};
    for (an = 0; an < 64; an = an + 1) begin
        aa = abase + an;
        arc_access(1'b1, aa);
    end
    for (an = 0; an < 64; an = an + 1) begin
        aa = abase + an;
        arc_access(1'b0, aa);
    end
end

integer errors = 0;

task phase;
    input [255:0] label;
    input integer clk_per_dot;
    input integer ndots;
    integer start;
    begin
        dot_clk = clk_per_dot;
        rv_acks = 0; rv_errors = 0; rv_max_gap = 0; rv_last_ack = clk_count;
        rom_ops = 0; rom_errors = 0; rom_wedged = 0; rom_max_lat = 0;
        arc_ops = 0; arc_errors = 0; arc_wedged = 0; arc_max_lat = 0;
        start = dots;
        while (dots - start < ndots)
            @(posedge clk);
        $display("%0s dot=%0d clk  rv=%0d (gap %0d, bad %0d)  rom=%0d (wait %0d, wedged %0d, bad %0d)  arcade=%0d (wait %0d, wedged %0d, bad %0d)",
                 label, clk_per_dot, rv_acks, rv_max_gap, rv_errors,
                 rom_ops, rom_max_lat, rom_wedged, rom_errors,
                 arc_ops, arc_max_lat, arc_wedged, arc_errors);
        if (rv_acks == 0 || rom_ops == 0 || arc_ops == 0 ||
            rv_errors || rom_wedged || rom_errors || arc_wedged || arc_errors)
            errors = errors + 1;
    end
endtask

initial begin
    repeat (10) @(posedge clk);
    resetn = 1'b1;
    wait (sdram_init_done);
    preload;
    repeat (100) @(posedge clk);
    counting = 1'b1;

    phase("5.37 MHz ", 8, 1500);
    phase("7.16 MHz ", 6, 1500);
    phase("10.7 MHz ", 4, 1500);
    phase("7.16 MHz ", 6, 1500);
    phase("10.7 MHz ", 4, 1500);
    phase("5.37 MHz ", 8, 1500);
    phase("10.7 MHz ", 4, 1500);
    phase("5.37 MHz ", 8, 1500);

    if (errors)
        $display("FAILED: %0d phase(s)", errors);
    else
        $display("PASSED");
    $finish;
end

initial begin
    #400000000;
    $display("FAILED: timeout");
    $finish;
end

endmodule
