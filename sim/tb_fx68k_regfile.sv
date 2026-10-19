`timescale 1ns/1ps
// fx68k writes the register file only on enT3 and samples it on enT1, at least
// two clocks later, so every write here is followed by one idle clock with
// unrelated (randomized) addresses and data before the result is checked.
module tb_fx68k_regfile;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [4:0] rx = 0, ry = 1;
    reg [15:0] dx = 0, dy = 0;
    reg [1:0] bex = 0, bey = 0;
    wire [15:0] qx, qy;
    reg [15:0] original [0:17];
    integer seed = 32'h68000, count = 0;
    fx68k_regfile dut (.*);

    function [15:0] stored(input integer r);
        if (r == 16) stored = dut.r16;
        else if (r == 17) stored = dut.r17;
        else begin
            stored = {dut.g_byte[1].mem_x[r], dut.g_byte[0].mem_x[r]};
            if ({dut.g_byte[1].mem_y[r], dut.g_byte[0].mem_y[r]} !== stored)
                $fatal(1, "Read copies diverged for register %0d", r);
        end
    endfunction

    initial for (integer r = 0; r < 18; r = r + 1) original[r] = 0;

    task automatic transaction(input [4:0] x, input [4:0] y, input [3:0] masks);
        @(negedge clk);
        rx = x;
        ry = y;
        bex = masks[1:0];
        bey = masks[3:2];
        dx = $random(seed);
        dy = $random(seed);
        // Original indexed writes, including later per-byte Y priority.
        if (x < 18) begin
            if (bex[0]) original[x][7:0] = dx[7:0];
            if (bex[1]) original[x][15:8] = dx[15:8];
        end
        if (y < 18) begin
            if (bey[0]) original[y][7:0] = dy[7:0];
            if (bey[1]) original[y][15:8] = dy[15:8];
        end
        @(negedge clk);
        bex = 0;
        bey = 0;
        rx = $random(seed);
        ry = $random(seed);
        dx = $random(seed);
        dy = $random(seed);
        @(negedge clk);
        rx = ($random(seed) & 32'h7fffffff) % 18;
        ry = ($random(seed) & 32'h7fffffff) % 18;
        #1;
        if (qx !== original[rx] || qy !== original[ry])
            $fatal(1, "Register read mismatch rx=%0d ry=%0d after x=%0d y=%0d masks=%b", rx, ry, x, y, masks);
        for (integer r = 0; r < 18; r = r + 1)
            if (stored(r) !== original[r])
                $fatal(1, "Register %0d mismatch at transaction %0d", r, count);
        count = count + 1;
    endtask

    initial begin
        // Every destination pair and byte mask combination, including X==Y.
        for (integer x = 0; x < 18; x = x + 1)
            for (integer y = 0; y < 18; y = y + 1)
                for (integer masks = 0; masks < 16; masks = masks + 1)
                    transaction(x, y, masks);
        // Out-of-range destinations must not alias registers 16/17.
        for (integer x = 18; x < 32; x = x + 1)
            transaction(x, 31 - x + 18, 4'b1111);
        for (integer n = 0; n < 20000; n = n + 1)
            transaction(($random(seed) & 32'h7fffffff) % 18, ($random(seed) & 32'h7fffffff) % 18,
                        $random(seed));
        // Readers remain asynchronous; changing an address must not need a clock.
        for (integer r = 0; r < 18; r = r + 1) begin
            #0.1;
            rx = r;
            ry = 17 - r;
            #0.1;
            if (qx !== original[rx] || qy !== original[ry])
                $fatal(1, "Asynchronous register read changed latency");
        end
        $display("tb_fx68k_regfile PASSED: %0d transactions, all register pairs/masks, Y priority, LUT-RAM copies, asynchronous reads",
                 count);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "68000 register-file test timeout");
    end
endmodule
