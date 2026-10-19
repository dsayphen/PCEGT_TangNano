`timescale 1ns/1ps
module tb_megadrive_phase_inc;
    reg [2:0] block_value = 0;
    reg [10:0] fnum = 0;
    reg signed [8:0] pm_offset = 0;
    wire [16:0] actual;
    reg [11:0] modified;
    reg [16:0] expected;
    jt12_pg_inc dut (.block(block_value), .fnum(fnum), .pm_offset(pm_offset), .phinc_pure(actual));
    integer b, f, p;
    initial begin
        for (b = 0; b < 8; b = b + 1)
            for (f = 0; f < 2048; f = f + 1)
                for (p = 0; p < 512; p = p + 1) begin
                    block_value = b; fnum = f; pm_offset = p;
                    modified = {fnum,1'b0} + {{3{pm_offset[8]}},pm_offset};
                    case (block_value)
                        0: expected = {7'b0,modified[11:2]};
                        1: expected = {6'b0,modified[11:1]};
                        2: expected = {5'b0,modified};
                        3: expected = {4'b0,modified,1'b0};
                        4: expected = {3'b0,modified,2'b0};
                        5: expected = {2'b0,modified,3'b0};
                        6: expected = {1'b0,modified,4'b0};
                        7: expected = {modified,5'b0};
                    endcase
                    #1;
                    if (actual !== expected) $fatal(1,"FM phase increment mismatch b%0d f%0d p%0d",b,f,p);
                end
        $display("PASS Mega Drive FM phase increment: all 8388608 block/frequency/modulation combinations");
        $finish;
    end
endmodule
