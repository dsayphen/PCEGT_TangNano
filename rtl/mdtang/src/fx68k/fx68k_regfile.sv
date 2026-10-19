// 18x16 68000 register half. Registers 0-15 live in LUT RAM (one write port,
// one asynchronous copy per read port); 16-17 stay in flip-flops.
// Two writes in the same clock are serialized: X is written immediately and Y
// one clock later, so Y keeps its per-byte priority. fx68k only writes on enT3
// and samples these outputs on enT1, which is always at least two clocks later.
module fx68k_regfile (
    input wire clk,
    input wire [4:0] rx, ry,
    input wire [15:0] dx, dy,
    input wire [1:0] bex, bey,
    output wire [15:0] qx, qy
);
    reg [4:0] ry_d;
    reg [15:0] dy_d;
    reg [1:0] bey_d = 0;
    always @(posedge clk) begin
        ry_d <= ry;
        dy_d <= dy;
        bey_d <= bey;
    end

    wire y_pending = |bey_d;
    wire [4:0] wa = y_pending ? ry_d : rx;
    wire [15:0] wd = y_pending ? dy_d : dx;
    wire [1:0] we = y_pending ? bey_d : bex;
    wire wa_low = !wa[4];
    wire wa_16 = wa == 5'd16;
    wire wa_17 = wa == 5'd17;

    reg [15:0] r16, r17;
    wire [15:0] ram_x, ram_y;
    for (genvar b = 0; b < 2; b = b + 1) begin : g_byte
        (* syn_ramstyle = "distributed_ram" *) reg [7:0] mem_x [0:15];
        (* syn_ramstyle = "distributed_ram" *) reg [7:0] mem_y [0:15];
        // synthesis translate_off
        initial for (integer r = 0; r < 16; r = r + 1) begin
            mem_x[r] = 0;
            mem_y[r] = 0;
        end
        // synthesis translate_on
        always @(posedge clk) begin
            if (we[b] && wa_low) begin
                mem_x[wa[3:0]] <= wd[b*8 +: 8];
                mem_y[wa[3:0]] <= wd[b*8 +: 8];
            end
            if (we[b] && wa_16) r16[b*8 +: 8] <= wd[b*8 +: 8];
            if (we[b] && wa_17) r17[b*8 +: 8] <= wd[b*8 +: 8];
        end
        assign ram_x[b*8 +: 8] = mem_x[rx[3:0]];
        assign ram_y[b*8 +: 8] = mem_y[ry[3:0]];
    end
    // synthesis translate_off
    initial begin
        r16 = 0;
        r17 = 0;
    end
    always @(posedge clk)
        if (y_pending && |bex) $fatal(1, "fx68k_regfile: X write one clock after a Y write");
    // synthesis translate_on

    assign qx = !rx[4] ? ram_x : rx[0] ? r17 : r16;
    assign qy = !ry[4] ? ram_y : ry[0] ? r17 : r16;
endmodule
