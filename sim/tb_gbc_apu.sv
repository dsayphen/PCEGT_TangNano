`timescale 1ns / 1ns

module tb_gbc_apu;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg ce = 1'b0;
    reg [15:0] addr = 16'h0000;
    reg [7:0] din = 8'h00;
    reg wr = 1'b0;
    wire [7:0] dout;
    wire [15:0] audio_l, audio_r;
    integer errors = 0;

    always #5 clk = ~clk;
    always @(posedge clk) ce <= ~ce;

    gbc_apu dut (
        .clk(clk), .resetn(resetn), .enable(ce), .cgb_mode(1'b1),
        .addr(addr), .din(din), .wr(wr), .dout(dout),
        .audio_l(audio_l), .audio_r(audio_r), .audio_ready()
    );

    // One frame-sequencer step = 8192 enables = 16384 clocks
    localparam integer STEP = 16384;

    task write_reg(input [15:0] a, input [7:0] d);
        begin
            @(posedge clk);
            addr <= a; din <= d; wr <= 1'b1;
            @(posedge clk);
            wr <= 1'b0; addr <= 16'h0000;
            repeat (4) @(posedge clk);
        end
    endtask

    task read_nr52(output [7:0] value);
        begin
            @(posedge clk);
            addr <= 16'hFF26;
            #1 value = dout;
            addr <= 16'h0000;
        end
    endtask

    task count_transitions(input integer cycles, output integer count);
        integer i;
        reg [15:0] last;
        begin
            count = 0;
            last = audio_l;
            for (i = 0; i < cycles; i = i + 1) begin
                @(posedge clk);
                if (audio_l != last) count = count + 1;
                last = audio_l;
            end
        end
    endtask

    task check(input cond, input [8*64-1:0] name);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", name);
            end else
                $display("ok:   %0s", name);
        end
    endtask

    reg [7:0] nr52;
    integer n_low, n_high, n_noise;

    initial begin
        repeat (10) @(posedge clk);
        resetn <= 1'b1;
        repeat (10) @(posedge clk);
        write_reg(16'hFF26, 8'h80);
        write_reg(16'hFF24, 8'h77);

        // Noise channel must actually produce noise (LFSR must run)
        write_reg(16'hFF25, 8'h88);
        write_reg(16'hFF21, 8'hF0);
        write_reg(16'hFF22, 8'h21);
        write_reg(16'hFF23, 8'h80);
        count_transitions(20000, n_noise);
        $display("noise transitions: %0d", n_noise);
        check(n_noise > 20, "noise LFSR toggles output");
        write_reg(16'hFF21, 8'h00);

        // Ch1 sweep up with shift 3: 0x400 -> 0x480 -> 0x510 -> 0x5B2 (no overflow)
        write_reg(16'hFF25, 8'h11);
        write_reg(16'hFF10, 8'h13);
        write_reg(16'hFF11, 8'h80);
        write_reg(16'hFF12, 8'hF0);
        write_reg(16'hFF13, 8'h00);
        write_reg(16'hFF14, 8'h84);
        repeat (12 * STEP) @(posedge clk);
        read_nr52(nr52);
        check(nr52[0] == 1'b1, "ch1 sweep-up keeps playing (shift is >>, not <<)");

        // Sweep overflow kills the channel, the next trigger must restart it
        write_reg(16'hFF13, 8'hFF);
        write_reg(16'hFF14, 8'h87);
        repeat (20) @(posedge clk);
        read_nr52(nr52);
        check(nr52[0] == 1'b0, "ch1 trigger-time sweep overflow disables channel");
        write_reg(16'hFF10, 8'h00);
        write_reg(16'hFF13, 8'h00);
        write_reg(16'hFF14, 8'h81);
        repeat (20) @(posedge clk);
        read_nr52(nr52);
        check(nr52[0] == 1'b1, "ch1 retrigger after overflow restarts channel");
        write_reg(16'hFF12, 8'h00);

        // Ch2 period write without trigger changes pitch
        write_reg(16'hFF25, 8'h22);
        write_reg(16'hFF16, 8'h80);
        write_reg(16'hFF17, 8'hF0);
        write_reg(16'hFF18, 8'hC0);
        write_reg(16'hFF19, 8'h87);
        count_transitions(200000, n_low);
        write_reg(16'hFF18, 8'h00);
        write_reg(16'hFF19, 8'h04);
        count_transitions(200000, n_high);
        $display("ch2 transitions: before=%0d after=%0d", n_low, n_high);
        check(n_high < n_low / 4, "ch2 NR23/NR24 write without trigger updates period");
        write_reg(16'hFF17, 8'h00);

        // Length 0 with length enable = 64 ticks (1/4 s), not 1 tick
        write_reg(16'hFF25, 8'h88);
        write_reg(16'hFF21, 8'hF0);
        write_reg(16'hFF20, 8'h00);
        write_reg(16'hFF23, 8'hC0);
        repeat (40 * STEP) @(posedge clk);
        read_nr52(nr52);
        check(nr52[3] == 1'b1, "ch4 length 0 still playing after ~20 ticks");
        repeat (100 * STEP) @(posedge clk);
        read_nr52(nr52);
        check(nr52[3] == 1'b0, "ch4 length 0 expires after 64 ticks");

        // Length 63 = 1 tick
        write_reg(16'hFF20, 8'h3F);
        write_reg(16'hFF23, 8'hC0);
        repeat (6 * STEP) @(posedge clk);
        read_nr52(nr52);
        check(nr52[3] == 1'b0, "ch4 length 63 expires after 1 tick");

        // Envelope period 1: volume 15 -> 0 in 15 envelope ticks (8 steps each)
        write_reg(16'hFF21, 8'h00);
        write_reg(16'hFF25, 8'h22);
        write_reg(16'hFF17, 8'hF1);
        write_reg(16'hFF19, 8'h87);
        repeat (8 * 16 * STEP + 2 * STEP) @(posedge clk);
        count_transitions(20000, n_noise);
        check(n_noise == 0, "envelope period 1 reaches 0 after 15 ticks");
        write_reg(16'hFF17, 8'h00);

        if (errors == 0) $display("tb_gbc_apu PASSED");
        else $display("tb_gbc_apu FAILED: %0d errors", errors);
        $finish;
    end
endmodule
