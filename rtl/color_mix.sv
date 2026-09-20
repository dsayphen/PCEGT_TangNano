// Module color_mix : Matrice de couleur NTSC + filtre passe-bas d'origine
// Basé sur le module original par Sorgelig (GPL v2+)

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

// 1. Registres de synchronisation des signaux d'entrée
reg [7:0] R, G, B;
reg HBl, VBl, HS, VS;

always @(posedge clk_vid) if (ce_pix) begin
	R   <= R_in;
	G   <= G_in;
	B   <= B_in;
	HS  <= HSync_in;
	VS  <= VSync_in;
	HBl <= HBlank_in;
	VBl <= VBlank_in;
end

// 2. Filtre passe-bas horizontal d'origine (cutoff ~3 MHz à 25.92 MHz)
reg [12:0] comp_r, comp_g, comp_b;
wire [9:0] delta_r = {1'b0, R, 1'b0} - {1'b0, comp_r[12:4]};
wire [9:0] delta_g = {1'b0, G, 1'b0} - {1'b0, comp_g[12:4]};
wire [9:0] delta_b = {1'b0, B, 1'b0} - {1'b0, comp_b[12:4]};

always @(posedge clk_vid) if (ce_pix) begin
	if ((mix != 1) || HBl) begin
		comp_r <= {R, 5'b00000};
		comp_g <= {G, 5'b00000};
		comp_b <= {B, 5'b00000};
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

// 3. Calcul YCbCr à partir du RGB filtré
wire [15:0] luma_full = (R_lpf * 16'd77) + (G_lpf * 16'd150) + (B_lpf * 16'd29);
wire [7:0]  Y         = luma_full[15:8];

wire signed [8:0] Cb = $signed({1'b0, B_lpf}) - $signed({1'b0, Y});
wire signed [8:0] Cr = $signed({1'b0, R_lpf}) - $signed({1'b0, Y});

// Alternative monochrome globale (modes 2 à 5)
wire [15:0] px = (R * 16'd54) + (G * 16'd183) + (B * 16'd18);

// 4. Reconstitution de la matrice de couleur NTSC
wire signed [10:0] R_comp_raw = $signed({2'b00, Y}) + $signed(Cr) + $signed(Cr >>> 2);
wire signed [10:0] G_comp_raw = $signed({2'b00, Y}) - $signed(Cb >>> 2) - $signed(Cr >>> 1);
wire signed [10:0] B_comp_raw = $signed({2'b00, Y}) + $signed(Cb) + $signed(Cb >>> 2);

// Saturation et Clamp [0 - 255]
wire [7:0] R_comp = (R_comp_raw[10] || (R_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|R_comp_raw[9:8]) ? 8'd255 : R_comp_raw[7:0];
wire [7:0] G_comp = (G_comp_raw[10] || (G_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|G_comp_raw[9:8]) ? 8'd255 : G_comp_raw[7:0];
wire [7:0] B_comp = (B_comp_raw[10] || (B_comp_raw[9:8] == 2'b11)) ? 8'd0 : (|B_comp_raw[9:8]) ? 8'd255 : B_comp_raw[7:0];

// 5. Multiplexage de la sortie vidéo
always @(posedge clk_vid) if (ce_pix) begin
	{R_out, G_out, B_out} <= 0;

	case (mix)
		3'd0: {R_out, G_out, B_out} <= {R,        G,        B         }; // Raw RGB
		3'd1: {R_out, G_out, B_out} <= {R_comp,   G_comp,   B_comp    }; // Composite (LPF + Matrice NTSC)
		3'd2: {       G_out       } <= {          px[15:8]            }; // Monochrome Vert
		3'd3: {R_out, G_out       } <= {px[15:8], px[15:8] - px[15:10]}; // Monochrome Ambre
		3'd4: {       G_out, B_out} <= {          px[15:8], px[15:8]  }; // Monochrome Cyan
		3'd5: {R_out, G_out, B_out} <= {px[15:8], px[15:8], px[15:8]  }; // Niveaux de gris
		default: {R_out, G_out, B_out} <= {R, G, B};
	endcase

	HSync_out  <= HS;
	VSync_out  <= VS;
	HBlank_out <= HBl;
	VBlank_out <= VBl;
end

endmodule