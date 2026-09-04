//
// DVI / TMDS 8b/10b encoder.
//
// Straight implementation of the encoding algorithm published in the DVI 1.0
// specification (figure 3-5): transition minimisation followed by DC balancing
// with a running disparity counter, plus the four fixed control period code
// words.
//

module tmds_encoder (
    input  wire       clk,
    input  wire       resetn,
    input  wire [7:0] din,      // pixel data
    input  wire [1:0] ctrl,     // {c1, c0} during blanking
    input  wire       de,       // 1 = pixel data, 0 = control
    output reg  [9:0] dout
);

// ---------------------------------------------------------------------------
// Stage 1: transition minimisation
// ---------------------------------------------------------------------------
wire [3:0] n1d = din[0] + din[1] + din[2] + din[3] +
                 din[4] + din[5] + din[6] + din[7];

wire use_xnor = (n1d > 4'd4) || ((n1d == 4'd4) && (din[0] == 1'b0));

wire [8:0] q_m;
assign q_m[0] = din[0];
assign q_m[1] = use_xnor ? ~(q_m[0] ^ din[1]) : (q_m[0] ^ din[1]);
assign q_m[2] = use_xnor ? ~(q_m[1] ^ din[2]) : (q_m[1] ^ din[2]);
assign q_m[3] = use_xnor ? ~(q_m[2] ^ din[3]) : (q_m[2] ^ din[3]);
assign q_m[4] = use_xnor ? ~(q_m[3] ^ din[4]) : (q_m[3] ^ din[4]);
assign q_m[5] = use_xnor ? ~(q_m[4] ^ din[5]) : (q_m[4] ^ din[5]);
assign q_m[6] = use_xnor ? ~(q_m[5] ^ din[6]) : (q_m[5] ^ din[6]);
assign q_m[7] = use_xnor ? ~(q_m[6] ^ din[7]) : (q_m[6] ^ din[7]);
assign q_m[8] = use_xnor ? 1'b0 : 1'b1;

// ---------------------------------------------------------------------------
// Stage 2: DC balancing
// ---------------------------------------------------------------------------
wire [3:0] n1q = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                 q_m[4] + q_m[5] + q_m[6] + q_m[7];
wire [3:0] n0q = 4'd8 - n1q;

// signed running disparity
reg signed [4:0] cnt;

wire signed [4:0] diff_1m0 = $signed({1'b0, n1q}) - $signed({1'b0, n0q});
wire signed [4:0] diff_0m1 = $signed({1'b0, n0q}) - $signed({1'b0, n1q});

wire signed [4:0] two_qm8  =  q_m[8] ? 5'sd2 : 5'sd0;
wire signed [4:0] two_nqm8 = ~q_m[8] ? 5'sd2 : 5'sd0;

wire balanced = (cnt == 5'sd0) || (n1q == n0q);
wire too_many_ones = (cnt > 5'sd0) && (n1q > n0q);
wire too_many_zeros = (cnt < 5'sd0) && (n0q > n1q);

always @(posedge clk) begin
    if (!de) begin
        cnt <= 5'sd0;
        case (ctrl)
            2'b00: dout <= 10'b1101010100;
            2'b01: dout <= 10'b0010101011;
            2'b10: dout <= 10'b0101010100;
            default: dout <= 10'b1010101011;
        endcase
    end else if (balanced) begin
        dout <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
        if (q_m[8])
            cnt <= cnt + diff_1m0;
        else
            cnt <= cnt + diff_0m1;
    end else if (too_many_ones || too_many_zeros) begin
        dout <= {1'b1, q_m[8], ~q_m[7:0]};
        cnt  <= cnt + two_qm8 + diff_0m1;
    end else begin
        dout <= {1'b0, q_m[8], q_m[7:0]};
        cnt  <= cnt - two_nqm8 + diff_1m0;
    end

    if (!resetn) begin
        cnt  <= 5'sd0;
        dout <= 10'b1101010100;
    end
end

endmodule
