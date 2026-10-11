module rv_memory_probe #(
    parameter WAIT_CYCLES = 432000,
    parameter [22:0] ADDRESS = 23'h407194,
    parameter DYNAMIC_ADDRESS = 0
) (
    input wire clk,
    input wire resetn,
    input wire stalled,
    input wire ready,
    input wire [31:0] rdata,
    input wire [22:0] target_address,
    output reg valid,
    output wire [22:0] address,
    output reg [127:0] snapshot,
    output wire has_result
);
reg [31:0] wait_count;
reg [2:0] reply_gap;
reg [2:0] read_count;
assign address = DYNAMIC_ADDRESS != 0 ? target_address : ADDRESS;
assign has_result = read_count == 4;
always @(posedge clk) begin
    if (!resetn) begin
        wait_count <= 0;
        reply_gap <= 0;
        read_count <= 0;
        snapshot <= 0;
        valid <= 0;
    end else begin
        if (!stalled && !valid)
            wait_count <= 0;
        else if (wait_count < WAIT_CYCLES)
            wait_count <= wait_count + 1;
        if (reply_gap != 0)
            reply_gap <= reply_gap - 1;
        if (stalled && wait_count == WAIT_CYCLES && read_count < 4 &&
            !valid && reply_gap == 0)
            valid <= 1;
        if (valid && ready) begin
            valid <= 0;
            read_count <= read_count + 1;
            reply_gap <= 3;
            snapshot <= {snapshot[95:0], rdata};
        end
    end
end
endmodule