//
// Behavioural model of the GW2AR on-package SDRAM, good enough to exercise
// rtl/tang/sdram.v in simulation.
//
// 2K rows x 256 columns x 4 banks x 32 bits = 8 MiB.  Commands are latched on
// the falling edge of `clk` (which is where clk_sdram, the 180 degree shifted
// clock the controller feeds the chip, has its rising edge).  Read data is
// held on DQ for several cycles around the CAS-2 window, which is deliberately
// forgiving: the point of these tests is the functional behaviour of the
// scheduler and its new 32 bit masked write, not the SDRAM AC timing (which is
// unchanged and already proven on hardware).
//
module sdram_model #(
    parameter integer DQ_HOLD_CYCLES = 3,
    parameter real DQ_OUTPUT_DELAY_NS = 0.0,
    parameter real DQ_VALID_NS = 0.0,
    parameter integer CHECK_TIMING = 0,
    parameter integer MIN_RCD_CYCLES = 2,
    parameter integer MIN_RC_CYCLES = 6
) (
    inout  wire [31:0] DQ,
    input  wire [10:0] A,
    input  wire [1:0]  BA,
    input  wire        nCS,
    input  wire        nWE,
    input  wire        nRAS,
    input  wire        nCAS,
    input  wire        CLK,
    input  wire        CKE,
    input  wire [3:0]  DQM,
    input  wire        clk        // logic side clock, for edge alignment
);

reg [31:0] mem [0:2097151];       // 2 M words
reg [10:0] row [0:3];
integer last_act [0:3];
integer model_cycle = 0;
integer ac_timing_errors = 0;

reg [31:0] dq_data;
reg [3:0]  dq_hold;

assign DQ = (dq_hold != 0) ? dq_data : 32'bz;

wire [2:0] cmd = {nRAS, nCAS, nWE};
localparam CMD_ACTIVATE = 3'b011;
localparam CMD_WRITE    = 3'b100;
localparam CMD_READ     = 3'b101;

wire [20:0] full_addr = {BA, row[BA], A[7:0]};

reg        rd_v1, rd_v2;
reg [20:0] rd_a1, rd_a2;

integer i;
initial begin
    for (i = 0; i < 2097152; i = i + 1)
        mem[i] = 32'h0000_0000;
    for (i = 0; i < 4; i = i + 1)
        row[i] = 11'd0;
    for (i = 0; i < 4; i = i + 1)
        last_act[i] = -1000;
    dq_hold = 0;
    dq_data = 0;
    rd_v1   = 0;
    rd_v2   = 0;
end

always @(negedge clk) begin
    model_cycle = model_cycle + 1;
    rd_v1 <= 1'b0;

    if (dq_hold != 0)
        dq_hold <= dq_hold - 4'd1;

    if (!nCS) begin
        case (cmd)
            CMD_ACTIVATE: begin
                if (CHECK_TIMING && model_cycle - last_act[BA] < MIN_RC_CYCLES) begin
                    if (ac_timing_errors < 8)
                        $display("SDRAM tRC bank=%0d gap=%0d cycle=%0d",
                                 BA, model_cycle - last_act[BA], model_cycle);
                    ac_timing_errors = ac_timing_errors + 1;
                end
                last_act[BA] = model_cycle;
                row[BA] <= A;
            end
            CMD_WRITE: begin
                if (CHECK_TIMING && model_cycle - last_act[BA] < MIN_RCD_CYCLES) begin
                    if (ac_timing_errors < 8)
                        $display("SDRAM tRCD write bank=%0d gap=%0d cycle=%0d",
                                 BA, model_cycle - last_act[BA], model_cycle);
                    ac_timing_errors = ac_timing_errors + 1;
                end
                if (!DQM[0]) mem[full_addr][7:0]   <= DQ[7:0];
                if (!DQM[1]) mem[full_addr][15:8]  <= DQ[15:8];
                if (!DQM[2]) mem[full_addr][23:16] <= DQ[23:16];
                if (!DQM[3]) mem[full_addr][31:24] <= DQ[31:24];
            end
            CMD_READ: begin
                if (CHECK_TIMING && model_cycle - last_act[BA] < MIN_RCD_CYCLES) begin
                    if (ac_timing_errors < 8)
                        $display("SDRAM tRCD read bank=%0d gap=%0d cycle=%0d",
                                 BA, model_cycle - last_act[BA], model_cycle);
                    ac_timing_errors = ac_timing_errors + 1;
                end
                rd_v1 <= 1'b1;
                rd_a1 <= full_addr;
            end
            default: ;
        endcase
    end

    // CAS 2: present the data a couple of cycles later and hold it long
    // enough for the controller's sampling window.
    rd_v2 <= rd_v1;
    rd_a2 <= rd_a1;
    if (rd_v2) begin
        dq_data <= #(DQ_OUTPUT_DELAY_NS) mem[rd_a2];
        dq_hold <= #(DQ_OUTPUT_DELAY_NS) DQ_HOLD_CYCLES;
        if (DQ_VALID_NS > 0.0)
            dq_hold <= #(DQ_OUTPUT_DELAY_NS + DQ_VALID_NS) 4'd0;
    end
end

endmodule
