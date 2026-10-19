`timescale 1ns/1ps
module tb_megadrive_fm_mux;
    reg [13:0] raw, op1, op2, op3;
    reg effect;
    reg [2:0] channel;
    reg [1:0] operator_index;
    wire [10:0] fnum;
    wire [2:0] block_value;
    jt12_reg dut (
        .clk(1'b0), .clk_en(1'b0), .rst(1'b0), .din(8'b0), .ch(3'b0), .op(2'b0),
        .effect(effect), .fnum_ch3op1(op1[10:0]), .fnum_ch3op2(op2[10:0]),
        .fnum_ch3op3(op3[10:0]), .block_ch3op1(op1[13:11]), .block_ch3op2(op2[13:11]),
        .block_ch3op3(op3[13:11]), .fnum_I(fnum), .block_I(block_value)
    );
    reg [13:0] expected;
    reg s1, s2, s3;
    integer data_set, selection;
    initial begin
        for (data_set = 0; data_set < 2000; data_set = data_set + 1) begin
            raw = $random; op1 = $random; op2 = $random; op3 = $random;
            for (selection = 0; selection < 64; selection = selection + 1) begin
                {effect, operator_index, channel} = selection;
                force dut.cur_ch = channel;
                force dut.cur_op = operator_index;
                force dut.fnum_I_raw = raw[10:0];
                force dut.block_I_raw = raw[13:11];
                s1 = effect && channel == 2 && operator_index == 0;
                s2 = effect && channel == 2 && operator_index == 2;
                s3 = effect && channel == 2 && operator_index == 1;
                expected = ({14{s1}} & op1) | ({14{s2}} & op2) |
                           ({14{s3}} & op3) | ({14{!(s1 || s2 || s3)}} & raw);
                #1;
                if ({block_value,fnum} !== expected)
                    $fatal(1,"FM frequency mux mismatch selector=%0d",selection);
            end
        end
        $display("PASS Mega Drive FM mux: 128000 original-versus-factored cases");
        $finish;
    end
endmodule
