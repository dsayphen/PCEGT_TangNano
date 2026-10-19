// Pokefan531/hunterk public-domain color matrix, Gambatte Accurate defaults.
// The shared gamma ROM processes one RGB component per clock.
module gbc_color_correct (
    input wire clk,
    input wire [14:0] color,
    input wire [1:0] component,
    output reg [7:0] corrected
);
`include "rtl/nestang/palettes/gbc_contrib_0.svh"
`include "rtl/nestang/palettes/gbc_contrib_1.svh"
`include "rtl/nestang/palettes/gbc_contrib_2.svh"
    reg [7:0] gamma_rom [0:4095];
    initial $readmemh("rtl/nestang/palettes/gbc_gamma.hex", gamma_rom);
    reg signed [17:0] linear_value;
    wire [17:0] gamma_offset = linear_value - 18'd1024;
    wire [11:0] gamma_address = linear_value <= 0 ? 12'd0 :
        linear_value >= 65535 ? 12'd3039 :
        linear_value < 1024 ? linear_value[11:0] :
        12'd1024 + {1'b0, gamma_offset[15:5]};
    always @(posedge clk) begin
        linear_value <= gbc_contrib_0({component, color[4:0]}) +
                        gbc_contrib_1({component, color[9:5]}) +
                        gbc_contrib_2({component, color[14:10]});
        corrected <= gamma_rom[gamma_address];
    end
endmodule
