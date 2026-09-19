//
//
// Copyright (c) 2018 Sorgelig
//
// This program is GPL v2+ Licensed.
//
//
////////////////////////////////////////////////////////////////////////////////////////////////////////

module color_mix
(
	input            clk_vid,
	input            ce_pix,
	input      [2:0] mix,

	input      [7:0] R_in,
	input      [7:0] G_in,
	input      [7:0] B_in,
	input            HSync_in,
	input            VSync_in,
	input            HBlank_in,
	input            VBlank_in,

	output reg [7:0] R_out,
	output reg [7:0] G_out,
	output reg [7:0] B_out,
	output reg       HSync_out,
	output reg       VSync_out,
	output reg       HBlank_out,
	output reg       VBlank_out
);


reg [7:0] R,G,B;
reg HBl, VBl, HS, VS;
always @(posedge clk_vid) if(ce_pix) begin
	R   <= R_in;
	G   <= G_in;
	B   <= B_in;
	HS  <= HSync_in;
	VS  <= VSync_in;
	HBl <= HBlank_in;
	VBl <= VBlank_in;
end

wire [15:0] px = R * 16'd054 + G * 16'd183 + B * 16'd018;

// Composite-like horizontal low-pass filter. At the 25.92 MHz HDMI pixel
// clock, coefficient 9 gives a cutoff close to 3 MHz.
reg [12:0] comp_r, comp_g, comp_b;
wire [9:0] delta_r = {1'b0, R, 1'b0} - {1'b0, comp_r[12:4]};
wire [9:0] delta_g = {1'b0, G, 1'b0} - {1'b0, comp_g[12:4]};
wire [9:0] delta_b = {1'b0, B, 1'b0} - {1'b0, comp_b[12:4]};

always @(posedge clk_vid) if(ce_pix) begin
	if((mix != 1) || HBl) begin
		comp_r <= {R, 5'b00000};
		comp_g <= {G, 5'b00000};
		comp_b <= {B, 5'b00000};
	end else begin
		comp_r <= comp_r + {delta_r, 3'b000} + {{3{delta_r[9]}}, delta_r};
		comp_g <= comp_g + {delta_g, 3'b000} + {{3{delta_g[9]}}, delta_g};
		comp_b <= comp_b + {delta_b, 3'b000} + {{3{delta_b[9]}}, delta_b};
	end
end

always @(posedge clk_vid) if(ce_pix) begin
	{R_out, G_out, B_out} <= 0;

	case(mix)
		0: {R_out, G_out, B_out} <= {R,        G,        B         }; // raw RGB
		1: {R_out, G_out, B_out} <= {comp_r[12:5], comp_g[12:5],
		                                  comp_b[12:5]};              // composite
		2: {       G_out       } <= {          px[15:8]            }; // green
		3: {R_out, G_out       } <= {px[15:8], px[15:8] - px[15:10]}; // amber
		4: {       G_out, B_out} <= {          px[15:8], px[15:8]  }; // cyan
		5: {R_out, G_out, B_out} <= {px[15:8], px[15:8], px[15:8]  }; // gray
	endcase

	HSync_out  <= HS;
	VSync_out  <= VS;
	HBlank_out <= HBl;
	VBlank_out <= VBl;
end

endmodule
