// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Length Counter for all sound channels
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
// WIDTH=6 for Ch1/2/4, WIDTH=8 for Ch3
//
// PCEGT_TangNano rewrite: explicit down-counter (Pan Docs model) because the
// original up-counter could not tell "expired" from "1 tick left":
//   - NRx1 write: remaining = 2^WIDTH - length
//   - 256 Hz tick with length enabled and remaining != 0: decrement,
//     the channel is disabled when it reaches 0
//   - trigger: remaining == 0 reloads 2^WIDTH (2^WIDTH - 1 when the length
//     enable is set during the first half of a length period)
//   - NRx4 write enabling length during the first half of a length period
//     clocks the counter once (extra length clocking quirk)
// clk_length_ctr is the level from the frame sequencer: high while the last
// sequencer step clocked the length counters (next step will not).

module gbc_apu_length_ctr #(
    parameter WIDTH = 6
) (
    input  clk,
    input  rst,
    input  clk_length_ctr,
    input  start,
    input  single,
    input  [WIDTH-1:0] length,
    input  reload,
    input  extra_clock_pulse, // unused, the quirk is detected locally
    output reg enable = 0
);
    localparam [WIDTH:0] FULL = {1'b1, {WIDTH{1'b0}}};

    reg [WIDTH:0] remaining = {(WIDTH+1){1'b0}};

    // start/reload are 1-cycle pulses issued on the same edge as the register
    // update; the 2-stage delay keeps them aligned with single_d1/single_d2.
    reg clk_length_ctr_d1 = 1'b0, clk_length_ctr_d2 = 1'b0;
    reg start_d1 = 1'b0, start_d2 = 1'b0;
    reg reload_d1 = 1'b0, reload_d2 = 1'b0;
    reg single_d1 = 1'b0, single_d2 = 1'b0;
    always @(posedge clk) begin
        clk_length_ctr_d1 <= clk_length_ctr;
        clk_length_ctr_d2 <= clk_length_ctr_d1;
        start_d1 <= start;
        start_d2 <= start_d1;
        reload_d1 <= reload;
        reload_d2 <= reload_d1;
        single_d1 <= single;
        single_d2 <= single_d1;
    end
    wire clk_length_ctr_rise = clk_length_ctr_d1 && !clk_length_ctr_d2;
    wire start_rise = start_d1 && !start_d2;
    wire reload_rise = reload_d1 && !reload_d2;
    wire single_rise = single_d1 && !single_d2;
    wire quirk_period = clk_length_ctr_d1;

    wire extra_clock = single_rise && quirk_period && remaining != 0;
    wire [WIDTH:0] after_extra = extra_clock ? remaining - 1'b1 : remaining;

    always @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            remaining <= {(WIDTH+1){1'b0}};
        end else if (start_rise) begin
            enable <= 1'b1;
            if (after_extra == 0)
                remaining <= (single_d1 && quirk_period) ? FULL - 1'b1 : FULL;
            else
                remaining <= after_extra;
        end else if (reload_rise) begin
            remaining <= FULL - {1'b0, length};
        end else if (single_rise) begin
            remaining <= after_extra;
            if (extra_clock && after_extra == 0)
                enable <= 1'b0;
        end else if (clk_length_ctr_rise && single_d1 && remaining != 0) begin
            remaining <= remaining - 1'b1;
            if (remaining == 1)
                enable <= 1'b0;
        end
    end
endmodule
