`timescale 1ns/1ps
module tb_gbc_color_correct;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [14:0] color;
    reg [1:0] component;
    wire [7:0] corrected;
    integer n, c, error, maximum = 0;
    real r, g, b, linear_value, reference_value;
    gbc_color_correct dut (.clk(clk), .color(color), .component(component), .corrected(corrected));
    initial begin
        for (n = 0; n < 32768; n++) begin
            color = n;
            r = (real'(n & 31) / 31.0) ** 1.7;
            g = (real'((n >> 5) & 31) / 31.0) ** 1.7;
            b = (real'((n >> 10) & 31) / 31.0) ** 1.7;
            for (c = 0; c < 3; c++) begin
                component = c;
                case (c)
                    0: linear_value = 0.94 * (0.82*r + 0.24*g - 0.06*b);
                    1: linear_value = 0.94 * (0.125*r + 0.665*g + 0.21*b);
                    2: linear_value = 0.94 * (0.195*r + 0.075*g + 0.73*b);
                endcase
                if (linear_value < 0) linear_value = 0;
                if (linear_value > 1) linear_value = 1;
                reference_value = 255.0 * (linear_value ** (1.0/2.2));
                repeat (3) @(negedge clk);
                error = $abs(integer'(corrected) - $rtoi(reference_value + 0.5));
                if (error > maximum) maximum = error;
                if (error > 2) $fatal(1, "FAILED RGB555=%h component=%0d error=%0d", color, c, error);
            end
        end
        $display("tb_gbc_color_correct PASSED: all 32768 colors, maximum channel error %0d/255", maximum);
        $finish;
    end
endmodule
