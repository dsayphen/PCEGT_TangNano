module rv_stack_watch #(
    parameter [31:0] ADDRESS = 32'h0019ff70
) (
    input wire clk,
    input wire resetn,
    input wire completed,
    input wire [31:0] address,
    input wire [31:0] write_data,
    input wire [31:0] read_data,
    input wire [3:0] write_strobes,
    input wire instruction,
    output wire [127:0] snapshot
);
reg [31:0] last_write;
reg [31:0] last_read;
reg [27:0] write_count;
reg [31:0] read_count;
reg [3:0] last_strobes;
assign snapshot = {last_write, last_read, last_strobes, write_count, read_count};
always @(posedge clk) begin
    if (!resetn) begin
        last_write <= 0;
        last_read <= 0;
        write_count <= 0;
        read_count <= 0;
        last_strobes <= 0;
    end else if (completed && address == ADDRESS && !instruction) begin
        if (write_strobes != 0) begin
            last_write <= write_data;
            last_strobes <= write_strobes;
            write_count <= write_count + 1;
        end else begin
            last_read <= read_data;
            read_count <= read_count + 1;
        end
    end
end
endmodule