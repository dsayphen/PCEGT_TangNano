`timescale 1ns / 1ps
// 4 MiB SNES ROM support: the last 256 KiB of the ROM is stored in SDRAM bank 2
// and served on the ARAM channel. Checks the CPU deadline (data valid six mclk
// after the address changes), ARAM latency, physical placement and tRC.
module tb_snes_rom_hi #(
    parameter CHECK_REPHASE = 0
);
reg fclk = 0;
always #2 fclk = ~fclk;
reg mclk = 0;
reg mph = 0;
always @(posedge fclk) begin
    mph <= ~mph;
    if (mph) mclk <= ~mclk;
end

reg resetn = 0;
reg [1:0] dot_cnt = 0;
reg dot_ce = 0;
always @(posedge mclk) begin
    dot_cnt <= dot_cnt + 2'd1;
    dot_ce <= dot_cnt == 2'd3;
end

reg cpu_req = 0, cpu_we = 0, cpu_port = 0;
reg [22:1] cpu_addr = 0;
reg [15:0] cpu_din = 0;
wire cpu_ack;
wire [15:0] cpu_q0, cpu_q1;
reg rom_hi_en = 0, rom_hi_rd = 0;
reg [21:1] rom_hi_addr = 0;
wire [15:0] rom_hi_q;
reg aram_req = 0;
reg [15:0] aram_addr = 0;
wire aram_ack;
wire [15:0] aram_q;
reg rv_req = 0;
reg [22:1] rv_addr = 0;
wire rv_ack;
wire [15:0] rv_q;
reg vram_req = 0;
reg vram_we = 0;
wire vram1_ack, vram2_ack;
wire [7:0] vram1_q, vram2_q;
wire busy;
wire [10:0] sa;
wire [1:0] sba;
wire [3:0] sdqm;
wire scs, sras, scas, swe, scke;
wire [31:0] dq;

sdram_snes #(.SHARED_IOSYS(1), .SPLIT_WRAM(1), .UPSTREAM_RAM_LAYOUT(1),
             .ROM_HIGH_SHARED(1)) dut (
    .clk(fclk), .mclk(mclk), .clkref(dot_ce),
    .resetn(resetn), .busy(busy),
    .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_BA(sba), .SDRAM_DQM(sdqm),
    .SDRAM_nCS(scs), .SDRAM_nRAS(sras), .SDRAM_nCAS(scas), .SDRAM_nWE(swe), .SDRAM_CKE(scke),
    .cpu_din(cpu_din), .cpu_port(cpu_port), .cpu_addr(cpu_addr), .cpu_req(cpu_req),
    .cpu_we(cpu_we), .cpu_ds(2'b11), .cpu_req_ack(cpu_ack), .cpu_port0(cpu_q0), .cpu_port1(cpu_q1),
    .rom_hi_en(rom_hi_en), .rom_hi_rd(rom_hi_rd), .rom_hi_addr(rom_hi_addr), .rom_hi_q(rom_hi_q),
    .wram_addr(17'd0), .wram_din(8'd0), .wram_req(1'b0), .wram_ack(), .wram_we(1'b0),
    .bsram_addr(20'd0), .bsram_din(8'd0), .bsram_req(1'b0), .bsram_we(1'b0),
    .bsram_req_ack(), .bsram_dout(),
    .aram_16(1'b0), .aram_addr(aram_addr), .aram_din(16'd0), .aram_req(aram_req), .aram_we(1'b0),
    .aram_req_ack(aram_ack), .aram_dout(aram_q),
    .vram1_addr(15'h100), .vram1_din(8'haa), .vram1_req(vram_req), .vram1_we(vram_we),
    .vram2_addr(15'h100), .vram2_din(8'hbb), .vram2_req(vram_req), .vram2_we(vram_we),
    .vram1_ack(vram1_ack), .vram2_ack(vram2_ack),
    .vram1_dout(vram1_q), .vram2_dout(vram2_q),
    .rv_addr(rv_addr), .rv_din(16'd0), .rv_ds(2'b11), .rv_req(rv_req), .rv_we(1'b0),
    .rv_req_ack(rv_ack), .rv_dout(rv_q), .refreshing(), .total_refresh()
);
sdram_model #(.READ_HOLD_CYCLES(1), .CHECK_OPEN_ROWS(1)) memory (
    .DQ(dq), .A(sa), .BA(sba), .nCS(scs), .nRAS(sras), .nCAS(scas), .nWE(swe),
    .DQM(sdqm), .CKE(scke), .CLK(~fclk), .clk(fclk)
);

// tRC monitor: ACT/REFRESH to the same bank must be >= 6 fclk apart.
integer fcount = 0;
integer last_act [0:3];
integer last_ref = -100;
integer b;
initial for (b = 0; b < 4; b = b + 1) last_act[b] = -100;
always @(negedge fclk) begin
    fcount = fcount + 1;
    if (resetn && !busy) begin
        if (!scs && !sras && scas && swe) begin
            if (fcount - last_act[sba] < 6 || fcount - last_ref < 6)
                $fatal(1, "tRC violation bank %0d at %0t", sba, $time);
            last_act[sba] = fcount;
        end
        if (!scs && !sras && !scas && swe) begin
            for (b = 0; b < 4; b = b + 1)
                if (fcount - last_act[b] < 6)
                    $fatal(1, "refresh too close to ACT bank %0d at %0t", b, $time);
            last_ref = fcount;
        end
    end
end

function [15:0] rom_word(input [21:1] a);
    rom_word = {a[8:1], a[16:9]} ^ {3'b101, a[21:17], 8'h5A};
endfunction
function [7:0] aram_byte(input [15:0] a);
    aram_byte = a[7:0] ^ a[15:8] ^ 8'hC3;
endfunction

task put_word(input [22:0] byte_addr, input [15:0] value);
    if (byte_addr[1]) memory.mem[byte_addr >> 2][31:16] = value;
    else              memory.mem[byte_addr >> 2][15:0] = value;
endtask
function [15:0] get_word(input [22:0] byte_addr);
    get_word = byte_addr[1] ? memory.mem[byte_addr >> 2][31:16] : memory.mem[byte_addr >> 2][15:0];
endfunction

// Loader write through the CPU request port, like the top level.
task cpu_write(input [21:0] byte_addr, input [15:0] value);
    begin
        @(posedge mclk);
        cpu_addr <= byte_addr >> 1;
        cpu_din <= value;
        cpu_we <= 1;
        cpu_port <= 0;
        cpu_req <= ~cpu_req;
        @(posedge mclk);
        while (cpu_ack != cpu_req) @(posedge mclk);
    end
endtask

integer mcount = 0;
always @(posedge mclk) mcount <= mcount + 1;

// ARAM requester at DSP rate: a request every 5 or 6 mclk. The data must be
// usable 4 mclk after the request edge.
reg aram_traffic = 0;
reg rom_phase = 0;
integer err = 0;
integer aram_next = 0, aram_issue = 0;
reg aram_pending = 0;
integer max_aram_base = 0, max_aram_hi = 0, aram_lat;
always @(posedge mclk) begin
    if (aram_traffic && mcount >= aram_next) begin
        if (aram_pending) begin
            $display("ARAM request not served before next one at %0t", $time);
            err = err + 1;
        end
        aram_addr <= $urandom;
        aram_req <= ~aram_req;
        aram_issue <= mcount;
        aram_pending <= 1;
        aram_next <= mcount + 5 + ($urandom % 2);
    end
end
always @(negedge mclk) begin
    if (aram_pending && aram_ack == aram_req &&
        (aram_addr[0] ? aram_q[15:8] : aram_q[7:0]) === aram_byte(aram_addr)) begin
        aram_lat = mcount - aram_issue;
        if (aram_lat > 4)
            $fatal(1, "ARAM read missed DSP deadline after reset: %0d mclk", aram_lat);
        if (rom_phase) begin
            if (aram_lat > max_aram_hi) max_aram_hi = aram_lat;
        end else if (aram_lat > max_aram_base) max_aram_base = aram_lat;
        aram_pending <= 0;
    end
end

integer i, j, k, lat, hold, max_hi_lat = 0;
reg [21:1] a;
initial begin
    for (i = 0; i < 65536; i = i + 2)
        put_word(23'h5A0000 + i, {aram_byte(i + 1), aram_byte(i)});
    repeat (4) @(posedge mclk);
    resetn = 1;
    wait(!busy);
    repeat (10) @(posedge mclk);

    // Loader: first 1 KiB of the high region, the last word, and a few low words.
    rom_hi_en <= 1;
    for (i = 0; i < 1024; i = i + 2) cpu_write(22'h3C0000 + i, rom_word((22'h3C0000 + i) >> 1));
    cpu_write(22'h3FFFFE, rom_word(22'h3FFFFE >> 1));
    for (i = 0; i < 64; i = i + 2) cpu_write(22'h3BFF00 + i, rom_word((22'h3BFF00 + i) >> 1));
    @(posedge mclk) cpu_we <= 0;

    for (i = 0; i < 1024; i = i + 2)
        if (get_word(23'h5C0000 + i) !== rom_word((22'h3C0000 + i) >> 1)) begin
            $display("placement error high %h", i); err = err + 1;
        end
    if (get_word(23'h5FFFFE) !== rom_word(22'h3FFFFE >> 1)) begin
        $display("placement error top"); err = err + 1;
    end
    for (i = 0; i < 64; i = i + 2)
        if (get_word(23'h3BFF00 + i) !== rom_word((22'h3BFF00 + i) >> 1)) begin
            $display("placement error low %h", i); err = err + 1;
        end
    for (i = 0; i < 1024; i = i + 4)
        if (memory.mem[(23'h3C0000 + i) >> 2] !== 0) begin
            $display("high write leaked to bank 1 at %h", i); err = err + 1;
        end

    // Baseline ARAM latency.
    aram_traffic = 1;
    repeat (3000) @(posedge mclk);
    rom_phase = 1;

    // ROM-high reads: the address changes on an mclk edge (A0) and the CPU
    // latches the data at A0+6. Hold 6 mclk (back-to-back FAST cycles) or more.
    for (j = 0; j < 6000; j = j + 1) begin
        @(posedge mclk);
        a = (22'h3C0000 >> 1) + ($urandom % 512);
        if (j % 97 == 0) a = 22'h3FFFFE >> 1;
        rom_hi_addr <= a;
        rom_hi_rd <= 1;
        hold = 6 + (($urandom % 4 == 0) ? ($urandom % 4) : 0);
        lat = 0;
        for (k = 1; k <= hold; k = k + 1) begin
            @(negedge mclk);
            if (lat == 0 && rom_hi_q === rom_word(a)) lat = k;
            if (k == 6 && rom_hi_q !== rom_word(a))
                $fatal(1, "ROM high data invalid at CPU deadline: address=%h data=%h",
                       a, rom_hi_q);
            if (k < hold) @(posedge mclk);
        end
        if (lat == 0 || lat > 6) begin
            $display("ROM high read %h missed deadline (q=%h exp=%h) at %0t", a, rom_hi_q, rom_word(a), $time);
            err = err + 1;
        end
        if (lat > max_hi_lat) max_hi_lat = lat;
        if ($urandom % 5 == 0) begin
            @(posedge mclk);
            rom_hi_rd <= 0;
            repeat ($urandom % 8) @(posedge mclk);
        end
    end
    @(posedge mclk);
    rom_hi_rd <= 0;

    // RV keeps working after ROM-high traffic.
    for (j = 0; j < 20; j = j + 1) begin
        @(posedge mclk);
        rv_addr <= (23'h5C0000 + 2 * j) >> 1;
        rv_req <= ~rv_req;
        i = 0;
        @(posedge mclk);
        while (rv_ack != rv_req && i < 200) begin
            @(posedge mclk); i = i + 1;
        end
        if (i >= 200) begin $display("RV starved"); err = err + 1; end
    end
    aram_traffic = 0;
    repeat (20) @(posedge mclk);

    // A dot-counter restart can move the reference edge from cycle 2 to 6.
    // The old scheduler replayed CAS 3 on an auto-precharged bank.
    put_word(23'h7f0200, 16'ha55a);
    for (j = 0; CHECK_REPHASE && j < 2; j = j + 1) begin
        force dot_ce = 0;
        @(posedge mclk);
        a = (22'h3c0000 >> 1) + j;
        rom_hi_addr <= a;
        rom_hi_rd <= 1;
        vram_we <= j[0];
        vram_req <= ~vram_req;
        @(negedge fclk);
        while (!(dut.cycle[1] && dut.next_port[1] == dut.PORT_ROM_HI))
            @(negedge fclk);
        @(negedge fclk);
        while (!dut.cycle[6]) @(negedge fclk);
        force dot_ce = 1;
        repeat (6) @(negedge fclk);
        if (rom_hi_q !== rom_word(a))
            $fatal(1, "Dot-counter restart corrupted cached high-ROM word: q=%h expected=%h",
                   rom_hi_q, rom_word(a));
        repeat (12) @(negedge fclk);
        if (rom_hi_q !== rom_word(a))
            $fatal(1, "High-ROM cache did not recover after dot-counter restart");
        if (vram1_ack !== vram_req || vram2_ack !== vram_req)
            $fatal(1, "VRAM transaction lost during dot-counter restart");
        if (!vram_we && {vram2_q, vram1_q} !== 16'ha55a)
            $fatal(1, "VRAM read corrupted during dot-counter restart");
        if (vram_we && get_word(23'h7f0200) !== 16'hbbaa)
            $fatal(1, "VRAM write corrupted during dot-counter restart");
    end
    release dot_ce;

    $display("max ROM-high latency %0d mclk (deadline 6)", max_hi_lat);
    $display("max ARAM latency: baseline %0d, with ROM-high %0d", max_aram_base, max_aram_hi);
    if (max_aram_base == 0 || max_aram_hi == 0)
        $fatal(1, "ARAM traffic was not exercised in both phases");
    if (max_aram_hi > max_aram_base) begin
        $display("ARAM latency increased"); err = err + 1;
    end
    if (err) $fatal(1, "%0d errors", err);
    $display("PASS");
    $finish;
end
initial begin #50000000; $fatal(1, "timeout"); end
endmodule
