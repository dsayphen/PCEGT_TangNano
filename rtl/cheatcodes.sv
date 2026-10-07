// Cheat Code handling by Kitrinx
// Apr 21, 2019

// Code layout:
// {clock bit, 32'bcode flags, 32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.

module CODES(
	input  clk,        // Best to not make it too high speed for timing reasons
	input  reset,      // This should only be triggered when a new rom is loaded or before new codes load, not warm reset
	input  enable,
	output available,
	input  [ADDR_WIDTH - 1:0] addr_in,
	input  [DATA_WIDTH - 1:0] data_in,
	input  [128:0] code,
	output logic genie_ovr,
	output logic [DATA_WIDTH - 1:0] genie_data
);

parameter ADDR_WIDTH   = 16; // Not more than 32
parameter DATA_WIDTH   = 8;  // Not more than 32
parameter MAX_CODES    = 32;
parameter COMPARE_SUPPORT = 1;

localparam INDEX_SIZE  = $clog2(MAX_CODES-1); // Number of bits for index, must accomodate MAX_CODES

localparam DATA_S      = DATA_WIDTH - 1;
localparam COMP_S      = DATA_S + (COMPARE_SUPPORT ? DATA_WIDTH : 0);
localparam ADDR_S      = COMP_S + ADDR_WIDTH;
localparam COMP_F_S    = ADDR_S + 1;
localparam ENA_F_S     = COMP_F_S + 1;

reg [ENA_F_S:0] codes[MAX_CODES];

wire [ADDR_WIDTH-1: 0] code_addr    = code[64+:ADDR_WIDTH];
wire [DATA_WIDTH-1: 0] code_compare = code[32+:DATA_WIDTH];
wire [DATA_WIDTH-1: 0] code_data    = code[0+:DATA_WIDTH];
wire code_comp_f = code[96];

wire [COMP_F_S:0] code_trimmed;

generate
if (COMPARE_SUPPORT) begin : generate_compare_codes
	assign code_trimmed = {code_comp_f, code_addr, code_compare, code_data};
end else begin : generate_unconditional_codes
	assign code_trimmed = {1'b0, code_addr, code_data};
end
endgenerate

reg [INDEX_SIZE:0] index = '0;

localparam TREE_LEVELS = $clog2(MAX_CODES);
localparam TREE_LEAVES = 1 << TREE_LEVELS;

wire [TREE_LEAVES-1:0] match_tree [0:TREE_LEVELS];
wire [TREE_LEAVES*DATA_WIDTH-1:0] data_tree [0:TREE_LEVELS];

genvar leaf;
generate
for (leaf = 0; leaf < TREE_LEAVES; leaf = leaf + 1) begin : generate_match_leaves
	if (leaf < MAX_CODES) begin : generate_valid_leaf
		assign match_tree[0][leaf] = enable && codes[leaf][ENA_F_S] &&
			(codes[leaf][ADDR_S-:ADDR_WIDTH] == addr_in) &&
			(!codes[leaf][COMP_F_S] ||
			 (codes[leaf][COMP_S-:DATA_WIDTH] == data_in));
		assign data_tree[0][leaf*DATA_WIDTH +: DATA_WIDTH] =
			match_tree[0][leaf] ? codes[leaf][DATA_S-:DATA_WIDTH] : '0;
	end else begin : generate_empty_leaf
		assign match_tree[0][leaf] = 1'b0;
		assign data_tree[0][leaf*DATA_WIDTH +: DATA_WIDTH] = '0;
	end
end

for (genvar level = 0; level < TREE_LEVELS; level = level + 1) begin : generate_tree_level
	for (genvar node = 0; node < (TREE_LEAVES >> (level + 1)); node = node + 1) begin : generate_tree_node
		localparam LOW_NODE = node * 2;
		localparam HIGH_NODE = LOW_NODE + 1;
		assign match_tree[level+1][node] = match_tree[level][LOW_NODE] ||
			match_tree[level][HIGH_NODE];
		assign data_tree[level+1][node*DATA_WIDTH +: DATA_WIDTH] =
			match_tree[level][HIGH_NODE]
			? data_tree[level][HIGH_NODE*DATA_WIDTH +: DATA_WIDTH]
			: data_tree[level][LOW_NODE*DATA_WIDTH +: DATA_WIDTH];
	end
end
endgenerate

assign available = |index;

reg code_change;
always_ff @(posedge clk) begin
	int x;
	if (reset) begin
		index <= 0;
		code_change <= 0;
		for (x = 0; x < MAX_CODES; x = x + 1) codes[x] <= '0;
	end else begin
		code_change <= code[128];
		if (code[128] && ~code_change && (index < MAX_CODES)) begin // detect posedge
			codes[index] <= {1'b1, code_trimmed};
			index <= index + 1'b1;
		end
	end
end

always_comb begin
	genie_data = data_tree[TREE_LEVELS][0 +: DATA_WIDTH];
	genie_ovr = match_tree[TREE_LEVELS][0];
end

endmodule
