// Module color_mix : Matrice de couleur NTSC + filtre passe-bas d'origine
// Basé sur le module original par Sorgelig (GPL v2+)
//
// Sync/blanking pass straight through (no added pipeline delay) so R/G/B_out
// stay pixel-aligned with the rest of the video path; the only clocked state
// is the horizontal low-pass filter itself, which is the source of the blur.

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

	output     [7:0] R_out,
	output     [7:0] G_out,
	output     [7:0] B_out,
	output           HSync_out,
	output           VSync_out,
	output           HBlank_out,
	output           VBlank_out
);

assign HSync_out  = HSync_in;
assign VSync_out  = VSync_in;
assign HBlank_out = HBlank_in;
assign VBlank_out = VBlank_in;

// 1. Filtre passe-bas horizontal d'origine (cutoff ~3 MHz à 25.92 MHz)
reg [12:0] comp_r, comp_g, comp_b;
wire [9:0] delta_r = {1'b0, R_in, 1'b0} - {1'b0, comp_r[12:4]};
wire [9:0] delta_g = {1'b0, G_in, 1'b0} - {1'b0, comp_g[12:4]};
wire [9:0] delta_b = {1'b0, B_in, 1'b0} - {1'b0, comp_b[12:4]};

always @(posedge clk_vid) if (ce_pix) begin
	if ((mix != 1) || HBlank_in) begin
		comp_r <= {R_in, 5'b00000};
		comp_g <= {G_in, 5'b00000};
		comp_b <= {B_in, 5'b00000};
	end else begin
		comp_r <= comp_r + {delta_r, 3'b000} + {{3{delta_r[9]}}, delta_r};
		comp_g <= comp_g + {delta_g, 3'b000} + {{3{delta_g[9]}}, delta_g};
		comp_b <= comp_b + {delta_b, 3'b000} + {{3{delta_b[9]}}, delta_b};
	end
end

// Extraction des signaux RGB lissés (8-bit)
wire [7:0] R_lpf = comp_r[12:5];
wire [7:0] G_lpf = comp_g[12:5];
wire [7:0] B_lpf = comp_b[12:5];

// 2. Calcul YCbCr à partir du RGB filtré
wire [15:0] luma_full = (R_lpf * 16'd77) + (G_lpf * 16'd150) + (B_lpf * 16'd29);
wire [7:0]  Y         = luma_full[15:8];

wire signed [8:0] Cb = $signed({1'b0, B_lpf}) - $signed({1'b0, Y});
wire signed [8:0] Cr = $signed({1'b0, R_lpf}) - $signed({1'b0, Y});

// Alternative monochrome globale (modes 2 à 5)
wire [15:0] px = (R_in * 16'd54) + (G_in * 16'd183) + (B_in * 16'd18);

// 3. Reconstitution de la matrice de couleur NTSC
wire signed [10:0] R_comp_raw = $signed({2'b00, Y}) + $signed(Cr) + $signed(Cr >>> 2);
wire signed [10:0] G_comp_raw = $signed({2'b00, Y}) - $signed(Cb >>> 2) - $signed(Cr >>> 1);
wire signed [10:0] B_comp_raw = $signed({2'b00, Y}) + $signed(Cb) + $signed(Cb >>> 2);

// Saturation et Clamp [0 - 255]
wire [7:0] R_comp = (R_comp_raw[10] || (R_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|R_comp_raw[9:8]) ? 8'd255 : R_comp_raw[7:0];
wire [7:0] G_comp = (G_comp_raw[10] || (G_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|G_comp_raw[9:8]) ? 8'd255 : G_comp_raw[7:0];
wire [7:0] B_comp = (B_comp_raw[10] || (B_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|B_comp_raw[9:8]) ? 8'd255 : B_comp_raw[7:0];

// 4. Multiplexage combinatoire de la sortie vidéo
reg [7:0] r_mux, g_mux, b_mux;
always @(*) begin
	case (mix)
		3'd0: {r_mux, g_mux, b_mux} = {R_in,     G_in,     B_in                }; // Raw RGB
		3'd1: {r_mux, g_mux, b_mux} = {R_comp,   G_comp,   B_comp              }; // Composite (LPF + Matrice NTSC)
		3'd2: {r_mux, g_mux, b_mux} = {8'd0,     px[15:8], 8'd0                }; // Monochrome Vert
		3'd3: {r_mux, g_mux, b_mux} = {px[15:8], px[15:8] - px[15:10], 8'd0    }; // Monochrome Ambre
		3'd4: {r_mux, g_mux, b_mux} = {8'd0,     px[15:8], px[15:8]            }; // Monochrome Cyan
		3'd5: {r_mux, g_mux, b_mux} = {px[15:8], px[15:8], px[15:8]            }; // Niveaux de gris
		default: {r_mux, g_mux, b_mux} = {R_in, G_in, B_in};
	endcase
end

assign R_out = r_mux;
assign G_out = g_mux;
assign B_out = b_mux;

endmodule
