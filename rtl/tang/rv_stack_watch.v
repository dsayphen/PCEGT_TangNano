module rv_stack_watch #(
    parameter [31:0] ADDRESS = 32'h0019ff70,
    parameter BUS_TRACE = 0,
    parameter SUSPECT_READ = 0,
    parameter CHECK_LEGACY_OPCODES = 0
) (
    input wire clk,
    input wire resetn,
    input wire completed,
    input wire [31:0] address,
    input wire [31:0] write_data,
    input wire [31:0] read_data,
    input wire [3:0] write_strobes,
    input wire instruction,
    input wire [63:0] capture_data,
    input wire [31:0] bridge_data,
    input wire [127:0] bus_data,
    output reg [127:0] read_path,
    output reg [22:0] suspect_address,
    output wire has_read,
    output wire [127:0] snapshot
);
reg [31:0] last_write;
reg [31:0] last_read;
reg [27:0] write_count;
reg [31:0] read_count;
reg [3:0] last_strobes;
reg [127:0] suspect_snapshot;
wire suspect_pattern = read_data == 32'h03c003c0 ||
                       read_data == 32'h33cccc33 || read_data == 32'hcc3333cc;
wire known_instruction = address == 32'h000024c4 || address == 32'h00007194;
wire suspect_value = instruction ?
                     (read_data[1:0] != 2'b11 ||
                      (CHECK_LEGACY_OPCODES != 0 && known_instruction &&
                       read_data != 32'h000187b7)) :
                     (address[31:12] == 20'h0019f && suspect_pattern);
wire suspect_transfer = completed && write_strobes == 0 &&
                        address[31:21] == 0 && suspect_value;
assign snapshot = SUSPECT_READ != 0 ? suspect_snapshot :
                  {last_write, last_read, last_strobes, write_count, read_count};
assign has_read = read_count != 0;
always @(posedge clk) begin
    if (!resetn) begin
        last_write <= 0;
        last_read <= 0;
        write_count <= 0;
        read_count <= 0;
        last_strobes <= 0;
        read_path <= 0;
        suspect_address <= 0;
        suspect_snapshot <= 0;
    end else if (SUSPECT_READ != 0) begin
        if (suspect_transfer && !has_read) begin
            suspect_address <= capture_data[54:32];
            suspect_snapshot <= {address, capture_data[31:0], bridge_data, read_data};
            read_path <= bus_data;
            read_count <= 1;
        end
    end else if (completed && address == ADDRESS && !instruction) begin
        if (write_strobes != 0) begin
            last_write <= write_data;
            last_strobes <= write_strobes;
            write_count <= write_count + 1;
        end else begin
            last_read <= read_data;
            read_count <= read_count + 1;
            read_path <= BUS_TRACE != 0 ? bus_data : {capture_data, bridge_data, read_data};
        end
    end
end
endmodule