`timescale 1ns/1ps
module tb_megadrive_enables;
    reg MCLK = 0, CLK_Z80 = 0, RESET_N = 0, PAUSE_EN = 0, wClk = 0;
    always #5 MCLK = ~MCLK;
    always #10 CLK_Z80 = ~CLK_Z80;
    wire [1:0] TURBO = 0;
    reg M68K_CLKENp, M68K_CLKENn, Z80_CLKENp, Z80_CLKENn, PSG_CLKEN;
    `include "md_clock_enables.vh"
    `include "md_cpu_enables.vh"
    wire fm_enable;
    jt12_div fm_div (.clk(MCLK), .rst(!RESET_N), .cen(FM_CLKEN),
                     .div_setting(2'b00), .clk_en(fm_enable));
    reg lfo_reset = 1;
    wire [6:0] lfo_mod;
    jt12_lfo lfo (.rst(lfo_reset), .clk(MCLK), .clk_en(fm_enable), .zero(1'b1),
                  .lfo_rst(1'b0), .lfo_en(1'b1), .lfo_freq(3'd7), .lfo_mod(lfo_mod));

    localparam MBUS_IDLE = 0, MBUS_WAIT_FOR_S4 = 1, MBUS_SELECT = 2, MBUS_Z80_PREREAD = 3;
    localparam MSRC_M68K = 0, MSRC_VDP = 1, MSRC_Z80 = 2;
    reg [1:0] mstate = MBUS_IDLE, msrc, cycle_cnt;
    reg CTRL_SEL, MBUS_RNW, MBUS_UDS_N, MBUS_LDS_N;
    reg M68K_AS_N, M68K_MBUS_DTACK_N, M68K_RNW, VBUS_SEL, VDP_MBUS_DTACK_N;
    reg Z80_IO, Z80_ZBUS, Z80_MBUS_DTACK_N, Z80_BGACK_N, Z80_BR_N, Z80_WR_N;
    reg [23:1] M68K_A, VBUS_A, BAR, MBUS_A;
    reg [15:0] M68K_DO, Z80_A, MBUS_DO, data;
    reg [7:0] Z80_DO;
    wire [15:0] NO_DATA = 16'h4e71;
    always @(posedge MCLK) begin
        case (mstate)
            `include "md_bus_idle.vh"
            default: ;
        endcase
    end

    integer tick = 0, last_t1 = -100, last_t3 = -100, last_t4 = -100, last_fm = -100;
    integer t1_count = 0, t3_count = 0, fm_count = 0;
    always @(posedge MCLK) begin
        tick = tick + 1;
        if (!RESET_N) begin
            last_t1 = -100; last_t3 = -100; last_t4 = -100;
        end else begin
            if (enT1) begin
                if (tick - last_t1 < 2) $fatal(1, "IR/address enable spacing");
                last_t1 = tick;
                t1_count = t1_count + 1;
            end
            if (enT3) begin
                if (tick - last_t3 < 2 || tick - last_t4 < 2)
                    $fatal(1, "CCR enable spacing");
                last_t3 = tick;
                t3_count = t3_count + 1;
            end
            if (enT4) last_t4 = tick;
        end
        if (fm_enable === 1'b1) begin
            if (tick - last_fm < 2) $fatal(1, "FM enable spacing");
            last_fm = tick;
            fm_count = fm_count + 1;
        end
    end

    integer trial;
    reg [1:0] expected_source, expected_state;
    reg [15:0] expected_data, held_data;
    reg accepted, expected_rnw;
    reg [23:1] expected_address;
    initial begin
        repeat (8) @(negedge MCLK);
        lfo_reset = 0;
        for (trial = 0; trial < 20000; trial = trial + 1) begin
            RESET_N = trial % 347 > 6;
            PAUSE_EN = (trial % 97) < 20;
            wClk = (trial % 23) < 8;
            @(negedge MCLK);
        end
        if (t1_count < 100 || t3_count < 100 || fm_count < 100)
            $fatal(1, "Insufficient enable coverage");
        // All control combinations, including simultaneous requests, must
        // latch the same data/address on acceptance and retain it afterwards.
        for (trial = 0; trial < 4096; trial = trial + 1) begin
            {M68K_AS_N, M68K_MBUS_DTACK_N, VBUS_SEL, VDP_MBUS_DTACK_N,
             Z80_IO, Z80_ZBUS, Z80_MBUS_DTACK_N, Z80_BGACK_N, Z80_BR_N,
             M68K_RNW, Z80_WR_N} = trial;
            M68K_A = $random; VBUS_A = $random; BAR = $random; Z80_A = $random;
            M68K_DO = $random; Z80_DO = $random;
            mstate = MBUS_IDLE;
            accepted = 1;
            if (!M68K_AS_N && M68K_MBUS_DTACK_N) begin
                expected_source = MSRC_M68K; expected_state = MBUS_WAIT_FOR_S4;
                expected_data = M68K_DO; expected_address = M68K_A; expected_rnw = M68K_RNW;
            end else if (VBUS_SEL && VDP_MBUS_DTACK_N) begin
                expected_source = MSRC_VDP; expected_state = MBUS_SELECT;
                expected_data = 0; expected_address = VBUS_A; expected_rnw = 1;
            end else if (Z80_IO && !Z80_ZBUS && Z80_MBUS_DTACK_N && !Z80_BGACK_N && Z80_BR_N) begin
                expected_source = MSRC_Z80; expected_state = MBUS_Z80_PREREAD;
                expected_data = {Z80_DO, Z80_DO}; expected_rnw = Z80_WR_N;
                expected_address = Z80_A[15] ? {BAR[23:15], Z80_A[14:1]} :
                                               {16'hc000, Z80_A[7:1]};
            end else accepted = 0;
            @(negedge MCLK);
            if (accepted) begin
                if (mstate !== expected_state || msrc !== expected_source ||
                    MBUS_DO !== expected_data || MBUS_A !== expected_address || MBUS_RNW !== expected_rnw)
                    $fatal(1, "Accepted bus request changed at control combination %0d", trial);
                held_data = MBUS_DO;
                M68K_DO = ~M68K_DO; Z80_DO = ~Z80_DO;
                @(negedge MCLK);
                if (MBUS_DO !== held_data) $fatal(1, "Active bus data not held");
            end else if (mstate !== MBUS_IDLE) $fatal(1, "Spurious bus request");
        end
        $display("PASS Mega Drive timing contracts: actual CPU/FM enables, reset/pause/wait; 4096 bus request combinations");
        $finish;
    end
endmodule
