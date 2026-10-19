`timescale 1ns/1ps
// Checks that the MCLK-side Z80 output shadows only load values that have
// been stable for two MCLKs, which is what the SDC multicycle path assumes.
module tb_megadrive_z80_shadow;
    reg MCLK = 0, CLK_Z80 = 0, RESET_N = 0, PAUSE_EN = 0, wClk = 0;
    always #5 MCLK = ~MCLK;
    // CLKOUTD is MCLK/2 with rising edges aligned to MCLK rising edges.
    initial begin
        #5;
        forever begin
            CLK_Z80 = ~CLK_Z80;
            #10;
        end
    end
    wire [1:0] TURBO = 0;
    reg M68K_CLKENp, M68K_CLKENn, Z80_CLKENp, Z80_CLKENn, PSG_CLKEN;
    `include "md_clock_enables.vh"

    wire        Z80r_BUSAK_N, Z80r_MREQ_N, Z80r_RD_N, Z80r_WR_N;
    wire [15:0] Z80r_A;
    wire  [7:0] Z80r_DO;
    `include "md_z80_shadow.vh"

    // T80 model: async-reset core registers, T80s sync-reset bus strobes.
    reg Z80_RESET_N = 0;
    reg [15:0] core_q = 0;
    reg [10:0] strobe_q = 11'h7ff;
    always @(posedge CLK_Z80) Z80_RESET_N <= z80_reset_n;
    always @(posedge CLK_Z80 or negedge Z80_RESET_N)
        if (!Z80_RESET_N) core_q <= 0;
        else if (Z80_CLKENn) core_q <= core_q + 16'h1235;
    always @(posedge CLK_Z80)
        if (!Z80_RESET_N) strobe_q <= 11'h7ff;
        else if (Z80_CLKENn) strobe_q <= strobe_q + 11'h0a5;
    assign Z80r_A = core_q;
    assign Z80r_DO = strobe_q[7:0];
    assign Z80r_MREQ_N = strobe_q[8];
    assign Z80r_RD_N = strobe_q[9];
    assign Z80r_WR_N = strobe_q[10];
    assign Z80r_BUSAK_N = ~(core_q[0] & Z80_RESET_N);

    realtime last_change = -1000;
    integer raw_changes = 0;
    always @(Z80r_A or Z80r_DO or Z80r_MREQ_N or Z80r_RD_N or Z80r_WR_N or Z80r_BUSAK_N) begin
        last_change = $realtime;
        raw_changes = raw_changes + 1;
    end

    integer loads = 0, reset_edges = 0, max_wait = 0, wait_count = 0;
    reg pending = 0;
    always @(posedge MCLK) begin
        if (RESET_N && !z80_shadow_hold) begin
            if ($realtime - last_change < 20.0)
                $fatal(1, "Z80 shadow loaded %0.1f ns after a raw change", $realtime - last_change);
            loads = loads + 1;
        end
        // Shadow must catch up within a few MCLKs once the raw bus settles.
        if (RESET_N && {Z80_BUSAK_N, Z80_MREQ_N, Z80_RD_N, Z80_WR_N, Z80_A, Z80_DO} !==
                       {Z80r_BUSAK_N, Z80r_MREQ_N, Z80r_RD_N, Z80r_WR_N, Z80r_A, Z80r_DO}) begin
            wait_count = wait_count + 1;
            if (wait_count > max_wait) max_wait = wait_count;
        end else wait_count = 0;
    end

    integer i, gap;
    initial begin
        z80_reset_n = 0;
        repeat (20) @(posedge MCLK);
        RESET_N <= 1;
        for (i = 0; i < 400; i = i + 1) begin
            gap = 20 + ($urandom % 97);
            repeat (gap) @(posedge MCLK);
            z80_reset_n <= ~z80_reset_n;
            reset_edges = reset_edges + 1;
        end
        repeat (200) @(posedge MCLK);
        if (loads < 1000) $fatal(1, "Z80 shadow rarely loaded (%0d)", loads);
        if (raw_changes < 1000) $fatal(1, "Z80 model barely ran (%0d changes)", raw_changes);
        // Raw change on a CEN edge -> blocked for up to 2 more MCLKs; a reset
        // change (async, then T80s sync one CLK_Z80 later) for up to 7.
        if (max_wait > 7) $fatal(1, "Z80 shadow lag too long: %0d MCLKs", max_wait);
        $display("PASS tb_megadrive_z80_shadow loads=%0d raw_changes=%0d reset_edges=%0d max_lag=%0d",
                 loads, raw_changes, reset_edges, max_wait);
        $finish;
    end
endmodule
