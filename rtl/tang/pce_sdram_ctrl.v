//
// SDRAM scheduler for the Tang Nano 20K PC Engine port.
//
// The HuCard-only configuration of pce_top (extram variant, LITE=1,
// USE_INTERNAL_RAM=1, CD_SUPPORT=0) needs exactly one external memory client:
// the HuCard ROM.  Work RAM, VRAM, the palette and the sprite/attribute
// buffers all live in block RAM, so this controller only has to arbitrate
// between
//
//   1. ROM image writes coming from the UART loader (highest priority, rare)
//   2. periodic auto-refresh                       (must never be starved)
//   3. HuCard ROM byte reads from the CPU
//
// The underlying byte-addressed controller (sdram.v, nand2mario, GPLv3) needs
// ~5 clocks per access at 43.2 MHz which is close to one 7.16 MHz CPU cycle,
// so a single 32-bit word cache is kept in front of it.  Sequential opcode and
// operand fetches then hit the cache 3 times out of 4 and cost no wait state
// at all.
//
// The ROM_RD / ROM_RDY handshake reproduces the timing of the MiST/MiSTer top
// level: a request is registered when ROM_RD is asserted and the effective ROM
// address differs from the one currently presented on ROM_DO, and ROM_RDY (the
// CPU's WAIT_N) is deasserted one clock later.
//

module pce_sdram_ctrl #(
    parameter FREQ = 43_200_000,
    // one auto refresh every 512 clocks = 11.9 us at 43.2 MHz
    // (the SDRAM needs 4096 refreshes per 64 ms, i.e. one per 15.6 us)
    parameter REFRESH_INTERVAL = 512
) (
    input  wire        clk,          // 43.2 MHz system clock
    input  wire        clk_sdram,    // same clock, 180 degrees shifted
    input  wire        resetn,

    // SDRAM device pins (GW2AR embedded 64 Mbit / 32 bit SDRAM)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,

    // ROM loader write port (byte stream, sequential)
    input  wire        ld_wr,        // single cycle strobe
    input  wire [22:0] ld_addr,
    input  wire [7:0]  ld_data,
    output wire        ld_busy,      // previous write not accepted yet
    input  wire        ld_active,    // held high while a ROM image is loading

    // HuCard ROM read port (from pce_top)
    input  wire        rom_rd,
    input  wire [21:0] rom_a,
    input  wire [22:0] rom_offset,   // 0 or 512 (.pce header skip)
    output wire [7:0]  rom_do,
    output wire        rom_rdy,

    output reg         init_done
);

// ---------------------------------------------------------------------------
// SDRAM controller instance
// ---------------------------------------------------------------------------
reg         sd_rd;
reg         sd_wr;
reg         sd_refresh;
reg  [22:0] sd_addr;
reg  [7:0]  sd_din;
wire [7:0]  sd_dout;
wire [31:0] sd_dout32;
wire        sd_data_ready;
wire        sd_busy;

sdram #(.FREQ(FREQ)) sdram_i (
    .SDRAM_DQ   (IO_sdram_dq),
    .SDRAM_A    (O_sdram_addr),
    .SDRAM_BA   (O_sdram_ba),
    .SDRAM_nCS  (O_sdram_cs_n),
    .SDRAM_nWE  (O_sdram_wen_n),
    .SDRAM_nRAS (O_sdram_ras_n),
    .SDRAM_nCAS (O_sdram_cas_n),
    .SDRAM_CLK  (O_sdram_clk),
    .SDRAM_CKE  (O_sdram_cke),
    .SDRAM_DQM  (O_sdram_dqm),

    .clk        (clk),
    .clk_sdram  (clk_sdram),
    .resetn     (resetn),
    .rd         (sd_rd),
    .wr         (sd_wr),
    .refresh    (sd_refresh),
    .addr       (sd_addr),
    .din        (sd_din),
    .dout       (sd_dout),
    .dout32     (sd_dout32),
    .data_ready (sd_data_ready),
    .busy       (sd_busy)
);

// ---------------------------------------------------------------------------
// ROM read address, 32-bit word cache
// ---------------------------------------------------------------------------
wire [22:0] rom_addr_eff = {1'b0, rom_a} + rom_offset;

reg  [22:0] rom_addr_r;      // address currently reflected by rom_do_r
reg  [7:0]  rom_do_r;
reg         rom_pending;

reg         cache_valid;
reg  [20:0] cache_tag;
reg  [31:0] cache_data;

wire        cache_hit = cache_valid && (cache_tag == rom_addr_eff[22:2]);

reg  [7:0]  cache_byte;
always @(*) begin
    case (rom_addr_eff[1:0])
        2'd0: cache_byte = cache_data[7:0];
        2'd1: cache_byte = cache_data[15:8];
        2'd2: cache_byte = cache_data[23:16];
        default: cache_byte = cache_data[31:24];
    endcase
end

reg  [7:0]  fill_byte;
always @(*) begin
    case (rom_addr_r[1:0])
        2'd0: fill_byte = sd_dout32[7:0];
        2'd1: fill_byte = sd_dout32[15:8];
        2'd2: fill_byte = sd_dout32[23:16];
        default: fill_byte = sd_dout32[31:24];
    endcase
end

assign rom_do  = rom_do_r;
assign rom_rdy = ~rom_pending;

// ---------------------------------------------------------------------------
// Loader write buffer
// ---------------------------------------------------------------------------
reg         wr_pending;
reg  [22:0] wr_addr;
reg  [7:0]  wr_data;

assign ld_busy = wr_pending;

// ---------------------------------------------------------------------------
// Refresh timer
// ---------------------------------------------------------------------------
reg [15:0] refresh_cnt;
reg        refresh_pending;

// ---------------------------------------------------------------------------
// Arbiter
//
// Command outputs are registered, so the SDRAM controller only sees them (and
// only raises `busy`) one clock after they are issued.  ST_CMD adds that clock
// for writes and refreshes; reads wait for `data_ready` anyway.
// ---------------------------------------------------------------------------
localparam ST_INIT = 3'd0;
localparam ST_IDLE = 3'd1;
localparam ST_CMD  = 3'd2;
localparam ST_READ = 3'd3;
localparam ST_WAIT = 3'd4;

reg [2:0] st;

wire refresh_tick  = (refresh_cnt == REFRESH_INTERVAL[15:0] - 16'd1);
wire issue_refresh = (st == ST_IDLE) && !sd_busy && !wr_pending && refresh_pending;

always @(posedge clk) begin
    sd_rd      <= 1'b0;
    sd_wr      <= 1'b0;
    sd_refresh <= 1'b0;

    // ---- refresh request -------------------------------------------------
    if (refresh_tick)
        refresh_cnt <= 16'd0;
    else
        refresh_cnt <= refresh_cnt + 16'd1;

    // the tick wins, so a request is never dropped
    if (refresh_tick)
        refresh_pending <= 1'b1;
    else if (issue_refresh)
        refresh_pending <= 1'b0;

    // ---- loader write request -------------------------------------------
    if (ld_wr && !wr_pending) begin
        wr_pending <= 1'b1;
        wr_addr    <= ld_addr;
        wr_data    <= ld_data;
    end

    // The cache must never survive a ROM image change.
    if (ld_active)
        cache_valid <= 1'b0;

    // ---- ROM read request (same timing as the MiST top level) -----------
    if (rom_rd && !rom_pending && rom_addr_r != rom_addr_eff) begin
        rom_addr_r <= rom_addr_eff;
        if (cache_hit)
            rom_do_r <= cache_byte;
        else
            rom_pending <= 1'b1;
    end

    // ---- SDRAM command scheduling ---------------------------------------
    case (st)
        ST_INIT: begin
            if (!sd_busy) begin
                st        <= ST_IDLE;
                init_done <= 1'b1;
            end
        end

        ST_IDLE: if (!sd_busy) begin
            if (wr_pending) begin
                sd_addr    <= wr_addr;
                sd_din     <= wr_data;
                sd_wr      <= 1'b1;
                wr_pending <= 1'b0;
                st         <= ST_CMD;
            end else if (refresh_pending) begin
                sd_refresh <= 1'b1;
                st         <= ST_CMD;
            end else if (rom_pending) begin
                sd_addr <= {rom_addr_r[22:2], 2'b00};
                sd_rd   <= 1'b1;
                st      <= ST_READ;
            end
        end

        // let the SDRAM controller latch the command and raise busy
        ST_CMD: st <= ST_WAIT;

        ST_READ: begin
            if (sd_data_ready) begin
                cache_data  <= sd_dout32;
                cache_tag   <= rom_addr_r[22:2];
                cache_valid <= ~ld_active;
                rom_do_r    <= fill_byte;
                rom_pending <= 1'b0;
                st          <= ST_WAIT;
            end
        end

        ST_WAIT: begin
            if (!sd_busy)
                st <= ST_IDLE;
        end

        default: st <= ST_IDLE;
    endcase

    if (!resetn) begin
        st              <= ST_INIT;
        init_done       <= 1'b0;
        rom_pending     <= 1'b0;
        rom_addr_r      <= {23{1'b1}};
        rom_do_r        <= 8'hFF;
        cache_valid     <= 1'b0;
        cache_tag       <= 21'd0;
        wr_pending      <= 1'b0;
        refresh_cnt     <= 16'd0;
        refresh_pending <= 1'b0;
    end
end

endmodule
