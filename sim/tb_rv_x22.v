`timescale 1ns/1ps
module tb_rv_x22;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
wire valid;
wire [31:0] address;
reg [31:0] data;
wire writeback;
wire [31:0] value;
wire [31:0] pc;
wire [31:0] opcode;
integer writes = 0;
picorv32 #(.ENABLE_COUNTERS(0), .COMPRESSED_ISA(0)) cpu (
    .clk(clk), .resetn(resetn), .mem_valid(valid), .mem_ready(valid),
    .mem_addr(address), .mem_rdata(data),
    .debug_x22_write(writeback), .debug_x22_value(value),
    .debug_x22_pc(pc), .debug_x22_opcode(opcode)
);
always @* begin
    case (address)
        0: data = 32'h00018b37;
        4: data = 32'h10000b13;
        8: data = 32'h000b2b03;
        12: data = 32'h0000006f;
        256: data = 32'h03c003c0;
        default: data = 32'h00000013;
    endcase
end
always @(posedge clk) begin
    if (writeback) begin
        case (writes)
            0: if (value !== 32'h18000 || pc !== 0 || opcode !== 32'h00018b37)
                $fatal(1, "LUI writeback mismatch pc=%h opcode=%h value=%h", pc, opcode, value);
            1: if (value !== 256 || pc !== 4 || opcode !== 32'h10000b13)
                $fatal(1, "ADDI writeback mismatch");
            2: begin
                if (value !== 32'h03c003c0 || pc !== 8 || opcode !== 32'h000b2b03)
                    $fatal(1, "LW writeback mismatch pc=%h opcode=%h value=%h", pc, opcode, value);
                $display("PASS x22 CPU writeback: LUI, ADDI, LW");
                $finish;
            end
        endcase
        writes = writes + 1;
    end
end
initial begin
    repeat (4) @(negedge clk);
    resetn = 1;
    #10000;
    $fatal(1, "CPU test timeout");
end
endmodule