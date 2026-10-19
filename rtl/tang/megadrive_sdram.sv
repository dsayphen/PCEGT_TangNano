// Mega Drive byte addresses map onto the Nano 20K's 8 MiB x32 SDRAM.
// Both toggle-handshake clients and the SDRAM engine run on clk.
module megadrive_sdram #(
    parameter FREQ = 53_693_175,
    parameter [22:0] WORK_RAM_BASE = 23'h600000,
    parameter [22:0] CART_RAM_BASE = 23'h620000
) (
    input  wire        clk,
    input  wire        clk_sdram,
    input  wire        resetn,
    input  wire        core_enable,
    input  wire [24:1] mem_addr,
    input  wire [15:0] mem_wdata,
    input  wire [1:0]  mem_be,
    input  wire        mem_we,
    input  wire        mem_req,
    output reg  [15:0] mem_rdata,
    output reg         mem_ack,
    // Host accesses are physical, aligned x32 words, with little-endian lanes.
    input  wire [22:2] host_addr,
    input  wire [31:0] host_wdata,
    input  wire [3:0]  host_be,
    input  wire        host_we,
    input  wire        host_req,
    output reg  [31:0] host_rdata,
    output reg         host_ack,
    output reg         init_done,
    output reg         address_fault,
    inout  wire [31:0] SDRAM_DQ,
    output wire [10:0] SDRAM_A,
    output wire [1:0]  SDRAM_BA,
    output wire [3:0]  SDRAM_DQM,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_CLK,
    output wire        SDRAM_CKE
);
    // Reserve bank 3 for 64 KiB work RAM, 128 KiB cartridge RAM and future host RAM.
    wire [24:0] core_byte_addr = {mem_addr, 1'b0};
    wire is_rom = core_byte_addr < 25'h0600000;
    wire is_wram = core_byte_addr[24:16] == 9'h080;
    wire is_sram = core_byte_addr[24:17] == 8'h41;
    wire valid_addr = is_rom || is_wram || is_sram;
    wire [22:0] physical_addr = is_wram ? WORK_RAM_BASE | {7'b0, core_byte_addr[15:0]} :
                               is_sram ? CART_RAM_BASE | {6'b0, core_byte_addr[16:0]} :
                                         core_byte_addr[22:0];
    wire [15:0] swapped_data = {mem_wdata[7:0], mem_wdata[15:8]};
    wire [1:0] swapped_be = {mem_be[0], mem_be[1]};

    localparam IDLE = 2'd0, START = 2'd1, WAIT_DONE = 2'd2;
    // 7.14 us nominal leaves room for an in-flight access before the 7.8 us limit.
    localparam REFRESH_CYCLES = FREQ / 140_000;
    localparam REFRESH_BITS = $clog2(REFRESH_CYCLES + 1);
    reg [REFRESH_BITS-1:0] refresh_count;
    reg [1:0] state;
    reg prefer_host, active_host, active_refresh, active_write, active_req;
    reg halfword;
    reg rd, wr32, refresh;
    reg [22:0] addr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    wire [31:0] rdata;
    wire data_ready, busy;
    // Capture pins before the endian/halfword mux, allowing input-register packing.
    (* syn_preserve = 1 *) reg [31:0] read_pins;
    reg read_ready;
    always @(posedge clk) begin
        read_pins <= rdata;
        read_ready <= resetn && data_ready;
    end

    sdram #(.FREQ(FREQ)) engine (
        .clk(clk), .clk_sdram(clk_sdram), .resetn(resetn),
        .rd(rd), .wr(1'b0), .wr32(wr32), .refresh(refresh),
        .addr(addr), .din(8'b0), .din32(wdata), .wstrb(wstrb),
        .dout(), .dout32(rdata), .data_ready(data_ready), .busy(busy),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM(SDRAM_DQM), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE)
    );

    always @(posedge clk) begin
        rd <= 0;
        wr32 <= 0;
        refresh <= 0;
        if (!resetn) begin
            state <= IDLE;
            mem_ack <= 0;
            host_ack <= 0;
            mem_rdata <= 0;
            host_rdata <= 0;
            init_done <= 0;
            address_fault <= 0;
            refresh_count <= 0;
            prefer_host <= 0;
            active_host <= 0;
            active_refresh <= 0;
            active_write <= 0;
            active_req <= 0;
            halfword <= 0;
            addr <= 0;
            wdata <= 0;
            wstrb <= 0;
        end else begin
            if (!busy) init_done <= 1;
            if (init_done && refresh_count < REFRESH_CYCLES)
                refresh_count <= refresh_count + 1'b1;
            case (state)
                IDLE: if (!busy) begin
                    if (refresh_count == REFRESH_CYCLES) begin
                        refresh <= 1;
                        refresh_count <= 0;
                        active_refresh <= 1;
                        state <= START;
                    end else if (host_req != host_ack &&
                                 (prefer_host || !core_enable || mem_req == mem_ack)) begin
                        addr <= {host_addr, 2'b00};
                        wdata <= host_wdata;
                        wstrb <= host_be;
                        rd <= !host_we;
                        wr32 <= host_we;
                        active_write <= host_we;
                        active_req <= host_req;
                        active_host <= 1;
                        active_refresh <= 0;
                        prefer_host <= 0;
                        state <= START;
                    end else if (core_enable && mem_req != mem_ack) begin
                        if (!valid_addr) begin
                            // Never alias an unsupported ROM bank onto console/host RAM.
                            address_fault <= 1;
                            mem_rdata <= 16'hffff;
                            mem_ack <= mem_req;
                        end else begin
                            addr <= physical_addr;
                            wdata <= {swapped_data, swapped_data};
                            wstrb <= physical_addr[1] ? {swapped_be, 2'b00} :
                                                                      {2'b00, swapped_be};
                            halfword <= physical_addr[1];
                            rd <= !mem_we;
                            wr32 <= mem_we;
                            active_write <= mem_we;
                            active_req <= mem_req;
                            active_host <= 0;
                            active_refresh <= 0;
                            state <= START;
                        end
                        prefer_host <= 1;
                    end
                end
                // The registered command is accepted by the engine on this edge.
                START: state <= WAIT_DONE;
                WAIT_DONE: begin
                    if (!active_refresh && !active_write && read_ready) begin
                        if (active_host) host_rdata <= read_pins;
                        else mem_rdata <= halfword ? {read_pins[23:16], read_pins[31:24]} :
                                                    {read_pins[7:0], read_pins[15:8]};
                    end
                    if (!busy) begin
                        if (!active_refresh) begin
                            if (active_host) host_ack <= active_req;
                            else mem_ack <= active_req;
                        end
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
