// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Noise channel (Ch4) generator
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
//
// Two-stage frequency divider:
//   Stage 1: clk_divider counts to adjusted_freq_dividing_ratio, toggles clk_div
//   Stage 2: 14-bit clk_shifter increments on clk_div edges
//   LFSR clocks on bit [latched_shift_clock_freq] of clk_shifter
//
// LFSR: 15-bit (mode=0) or 7-bit (mode=1), taps at bits [0] and [1].
// Output: ~lfsr[0] (inverted bit 0).
//
// PCEGT_TangNano fixes: the LFSR next-state wires were 1 bit wide and the
// register started at 0 with XOR feedback, so it never left 0 (channel 4 was
// a DC level, no noise). NR43 is now read live instead of latched on trigger.

module gbc_apu_noise (
    input  rst,
    input  clk,
    input  cpu_ce,
    input  clk_length_ctr,
    input  clk_vol_env,
    input  [5:0] length,
    input  [3:0] initial_volume,
    input  envelope_increasing,
    input  [2:0] num_envelope_sweeps,
    input  [3:0] shift_clock_freq,
    input  counter_width,  // 0=15-bit LFSR, 1=7-bit LFSR
    input  [2:0] freq_dividing_ratio,
    input  start,
    input  single,
    input  reload,          // DMG: NR41 write reloads length counter
    input  dac_change,      // DMG: NR42 write triggers zombie mode check
    output [3:0] level,
    output enable,
    input  extra_clock_pulse  // DMG lenquirk: forwarded from gb_apu.v
);

    // ---------------------------------------------------------------
    // Frequency divider (NR43 is read live, as on hardware):
    // LFSR clock period = (r == 0 ? 8 : 16 * r) << s CPU cycles.
    // Stage 1 toggles clk_div every (r == 0 ? 2 : 4 * r) cycles, stage 2
    // is a 14-bit counter whose bit s clocks the LFSR. s = 14/15: no clock.
    // ---------------------------------------------------------------
    reg playing = 1'b0;

    reg start_d1 = 1'b0, start_d2 = 1'b0;
    always @(posedge clk) begin
        start_d1 <= start;
        start_d2 <= start_d1;
    end
    wire start_rise = start_d1 && !start_d2;

    wire [4:0] adjusted_freq_dividing_ratio =
        (freq_dividing_ratio == 3'b0) ? 5'd1 : {freq_dividing_ratio, 2'b00} - 5'd1;

    reg [4:0] clk_divider = 5'b0;
    reg clk_div = 0;

    always @(posedge clk) begin
        if (cpu_ce) begin
            if (clk_divider >= adjusted_freq_dividing_ratio) begin
                clk_div <= ~clk_div;
                clk_divider <= 0;
            end else begin
                clk_divider <= clk_divider + 1'b1;
            end
        end
    end

    reg [13:0] clk_shifter = 14'b0;

    reg clk_div_d1 = 1'b0;
    always @(posedge clk) begin
        clk_div_d1 <= clk_div;
    end
    wire clk_div_rise = clk_div && !clk_div_d1;

    always @(posedge clk) begin
        if (clk_div_rise)
            clk_shifter <= clk_shifter + 1'b1;
    end

    wire clk_shift = (shift_clock_freq[3:1] == 3'b111) ? 1'b0 : clk_shifter[shift_clock_freq];

    // ---------------------------------------------------------------
    // LFSR (Gambatte representation): all ones on trigger, feedback
    // bit0 ^ bit1 into bit 14 (and bit 6 in 7-bit mode), output = ~bit0.
    // ---------------------------------------------------------------
    reg [14:0] lfsr = 15'h7FFF;
    wire target_freq_out = ~lfsr[0];

    wire lfsr_xor_bit = lfsr[0] ^ lfsr[1];
    wire [14:0] lfsr_next_15 = {lfsr_xor_bit, lfsr[14:1]};
    wire [14:0] lfsr_next_7  = {lfsr_xor_bit, lfsr[14:8], lfsr_xor_bit, lfsr[6:1]};

    reg clk_shift_d1 = 1'b0;
    always @(posedge clk) begin
        clk_shift_d1 <= clk_shift;
    end
    wire clk_shift_rise = clk_shift && !clk_shift_d1;

    always @(posedge clk) begin
        if (start_rise) begin
            lfsr <= 15'h7FFF;
        end else if (clk_shift_rise) begin
            lfsr <= counter_width ? lfsr_next_7 : lfsr_next_15;
        end
    end

    // ---------------------------------------------------------------
    // Volume envelope
    // ---------------------------------------------------------------
    wire [3:0] target_vol;

    gbc_apu_vol_env vol_env_inst (
        .clk(clk),
        .rst(rst),
        .clk_vol_env(clk_vol_env),
        .start(start),
        .initial_volume(initial_volume),
        .envelope_increasing(envelope_increasing),
        .num_envelope_sweeps(num_envelope_sweeps),
        .dac_change(dac_change),
        .playing(playing),
        .target_vol(target_vol)
    );

    // ---------------------------------------------------------------
    // Length counter
    // ---------------------------------------------------------------
    wire enable_length;
    gbc_apu_length_ctr #(6) len_ctr_inst (
        .clk(clk),
        .rst(rst),
        .clk_length_ctr(clk_length_ctr),
        .start(start),
        .single(single),
        .length(length),
        .reload(reload),
        .extra_clock_pulse(extra_clock_pulse),
        .enable(enable_length)
    );

    // ---------------------------------------------------------------
    // Channel "playing" flag (NR52 bit) - SameBoy/DMG accurate model
    // Same logic as apu_square but without sweep overflow
    // ---------------------------------------------------------------
    // DMG DAC ON: NRx2[7:3] != 00000 (all 5 bits, including envelope direction bit 3)
    wire dac_on = |{initial_volume, envelope_increasing};

    // Edge detection for dac_change (start_rise already defined above)
    reg dac_change_d1 = 1'b0, dac_change_d2 = 1'b0;
    always @(posedge clk) begin
        dac_change_d1 <= dac_change;
        dac_change_d2 <= dac_change_d1;
    end
    wire dac_change_rise = dac_change_d1 && !dac_change_d2;

    // Detect length counter falling edge
    reg enable_length_d1 = 1'b0;
    always @(posedge clk) enable_length_d1 <= enable_length;
    wire enable_length_fall = enable_length_d1 && !enable_length;

    always @(posedge clk) begin
        if (rst) begin
            playing <= 1'b0;
        end else if (enable_length_fall) begin
            playing <= 1'b0;
        end else if (start_rise) begin
            if (dac_on)
                playing <= 1'b1;
        end else if (dac_change_rise && !dac_on && playing) begin
            playing <= 1'b0;
        end
    end

    assign enable = playing;

    assign level = (enable) ? (target_freq_out ? target_vol : 4'b0000) : 4'b0000;

endmodule
