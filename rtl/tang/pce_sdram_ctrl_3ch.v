// Three-channel SDRAM scheduler for the Tang Nano 20K PC Engine port.
//
// The 8 MiB memory is partitioned by physical SDRAM bank:
//   banks 0-1: HuCard ROM and loader writes
//   bank 2:    PicoRV32 firmware/data and VDC1 VRAM
//   bank 3:    VDC0 VRAM (last 64 KiB, 0x7f0000-0x7fffff)
//
// The fixed eight-cycle schedule is derived from SNESTang's Nano 20K
// controller. At 86.4 MHz it completes one VRAM access per fastest PCE pixel
// period. VDC1 has priority over PicoRV32 on their shared channel.

module pce_sdram_ctrl_3ch #(
    parameter FREQ = 86_400_000
) (
    input  wire        clk,
    input  wire        clk_mem,
    input  wire        clk_sdram,
    input  wire        clkref,
    input  wire        refresh_window,
    input  wire        resetn,

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

    input  wire        ld_wr,
    input  wire [22:0] ld_addr,
    input  wire [7:0]  ld_data,
    output wire        ld_busy,
    output wire        ld_idle,
    input  wire        ld_active,

    input  wire        rom_rd,
    input  wire [21:0] rom_a,
    input  wire [22:0] rom_offset,
    output wire [7:0]  rom_do,
    output wire        rom_rdy,

    input  wire [15:0] vram_addr,
    input  wire [15:0] vram_din,
    output wire [15:0] vram_dout,
    input  wire        vram_rd,
    input  wire        vram_we,

    input  wire [15:0] vram1_addr,
    input  wire [15:0] vram1_din,
    output wire [15:0] vram1_dout,
    input  wire        vram1_rd,
    input  wire        vram1_we,

    input  wire        rv_valid,
    output reg         rv_ready,
    input  wire [22:0] rv_addr,
    input  wire [31:0] rv_wdata,
    input  wire [3:0]  rv_wstrb,
    output reg  [31:0] rv_rdata,

    output reg         init_done
);

// -------------------------------------------------------------------------
// 16-bit host port: loader writes and cached HuCard reads
// -------------------------------------------------------------------------
wire init_done_mem;
reg [1:0] init_done_mem_sync;
always @(posedge clk) begin
    if (!resetn)
        init_done_mem_sync <= 2'b00;
    else
        init_done_mem_sync <= {init_done_mem_sync[0], init_done_mem};
end

wire [22:0] rom_addr_eff = {1'b0, rom_a} + rom_offset;

reg         host_req;
wire        host_ack;
reg  [22:0] host_addr;
reg  [15:0] host_din;
reg  [1:0]  host_ds;
reg         host_we;
wire [15:0] host_dout;

reg [1:0] host_ack_sync;
reg       host_ack_seen;
wire      host_busy = host_req != host_ack_sync[1];

localparam HOST_NONE   = 2'd0;
localparam HOST_LOADER = 2'd1;
localparam HOST_ROM    = 2'd2;
reg [1:0] host_kind;

reg         wr_pending;
reg  [22:0] wr_addr;
reg  [7:0]  wr_data;

reg         rom_pending;
reg  [22:0] rom_addr_r;
reg  [7:0]  rom_do_r;
reg         cache_valid;
reg  [21:0] cache_tag;
reg  [15:0] cache_data;

wire cache_hit = cache_valid && cache_tag == rom_addr_eff[22:1];
wire [7:0] cache_byte = rom_addr_eff[0] ?
                        cache_data[15:8] : cache_data[7:0];

assign rom_do  = rom_do_r;
assign rom_rdy = ~rom_pending;
assign ld_busy = wr_pending;
assign ld_idle = !ld_wr && !wr_pending &&
                 !(host_busy && host_kind == HOST_LOADER);

always @(posedge clk) begin
    if (!resetn) begin
        host_req      <= 1'b0;
        host_ack_sync <= 2'b00;
        host_ack_seen <= 1'b0;
        host_addr     <= 23'd0;
        host_din      <= 16'd0;
        host_ds       <= 2'b00;
        host_we       <= 1'b0;
        host_kind     <= HOST_NONE;
        wr_pending    <= 1'b0;
        rom_pending   <= 1'b0;
        rom_addr_r    <= 23'h7fffff;
        rom_do_r      <= 8'hff;
        cache_valid   <= 1'b0;
        cache_tag     <= 22'd0;
        cache_data    <= 16'd0;
        init_done     <= 1'b0;
    end else begin
        host_ack_sync <= {host_ack_sync[0], host_ack};
        init_done     <= init_done_mem_sync[1];

        if (ld_wr && !wr_pending) begin
            wr_pending <= 1'b1;
            wr_addr    <= ld_addr;
            wr_data    <= ld_data;
        end

        // A reload in progress invalidates everything the ROM read path
        // knows about. Clearing cache_valid alone is not enough: rom_addr_r
        // is only reset to its sentinel at power-on, so if the very first
        // address the CPU fetches after the reloaded game's reset happens to
        // equal the last address read by the *previous* game (very likely
        // for bank-switched HuCards such as SF2, whose reset/IRQ vectors sit
        // at bank-relative addresses that can coincide across loads), the
        // `rom_addr_r != rom_addr_eff` guard below stays false and the CPU
        // silently gets served the stale `rom_do_r` byte instead of ever
        // issuing a fresh SDRAM read. Forcing rom_addr_r back to its
        // impossible sentinel (and dropping any pending request left over
        // from the previous game) guarantees the first post-reload access
        // always misses and re-fetches.
        if (ld_active) begin
            cache_valid <= 1'b0;
            rom_addr_r  <= 23'h7fffff;
            rom_pending <= 1'b0;
        end

        if (rom_rd && !rom_pending && rom_addr_r != rom_addr_eff) begin
            rom_addr_r <= rom_addr_eff;
            if (cache_hit)
                rom_do_r <= cache_byte;
            else
                rom_pending <= 1'b1;
        end

        if (host_ack_sync[1] != host_ack_seen) begin
            host_ack_seen <= host_ack_sync[1];
            if (host_kind == HOST_ROM) begin
                cache_valid <= 1'b1;
                cache_tag   <= rom_addr_r[22:1];
                cache_data  <= host_dout;
                rom_do_r    <= rom_addr_r[0] ? host_dout[15:8] :
                                                  host_dout[7:0];
                rom_pending <= 1'b0;
            end
            host_kind <= HOST_NONE;
        end

        if (init_done && !host_busy) begin
            if (wr_pending) begin
                host_addr  <= wr_addr;
                host_din   <= {wr_data, wr_data};
                host_ds    <= wr_addr[0] ? 2'b10 : 2'b01;
                host_we    <= 1'b1;
                host_kind  <= HOST_LOADER;
                host_req   <= ~host_req;
                wr_pending <= 1'b0;
            end else if (rom_pending && host_kind == HOST_NONE) begin
                host_addr <= {rom_addr_r[22:1], 1'b0};
                host_din  <= 16'd0;
                host_ds   <= 2'b11;
                host_we   <= 1'b0;
                host_kind <= HOST_ROM;
                host_req  <= ~host_req;
            end
        end
    end
end

// -------------------------------------------------------------------------
// PicoRV32: one native 32-bit SDRAM transaction per bus request.
// -------------------------------------------------------------------------
reg         rv_mem_req;
wire        rv_mem_ack;
reg  [22:0] rv_mem_addr;
reg  [31:0] rv_mem_din;
reg  [3:0]  rv_mem_ds;
reg         rv_mem_we;
wire [31:0] rv_mem_dout;
reg  [1:0]  rv_mem_ack_sync;
reg  [1:0]  rv_state;

localparam RV_IDLE  = 2'd0;
localparam RV_WAIT  = 2'd1;
localparam RV_REPLY = 2'd2;

always @(posedge clk) begin
    if (!resetn) begin
        rv_mem_req      <= 1'b0;
        rv_mem_ack_sync <= 2'b00;
        rv_mem_addr     <= 23'd0;
        rv_mem_din      <= 32'd0;
        rv_mem_ds       <= 4'd0;
        rv_mem_we       <= 1'b0;
        rv_rdata        <= 32'd0;
        rv_ready        <= 1'b0;
        rv_state        <= RV_IDLE;
    end else begin
        rv_mem_ack_sync <= {rv_mem_ack_sync[0], rv_mem_ack};
        rv_ready <= 1'b0;

        case (rv_state)
            RV_IDLE: if (init_done && rv_valid) begin
                rv_mem_addr <= {rv_addr[22:2], 2'b00};
                rv_mem_din  <= rv_wdata;
                rv_mem_ds   <= rv_wstrb;
                rv_mem_we   <= |rv_wstrb;
                rv_mem_req  <= ~rv_mem_req;
                rv_state    <= RV_WAIT;
            end

            RV_WAIT: if (rv_mem_ack_sync[1] == rv_mem_req) begin
                if (!rv_mem_we)
                    rv_rdata <= rv_mem_dout;
                rv_ready <= 1'b1;
                rv_state <= RV_REPLY;
            end

            // PicoRV32 may keep mem_valid high for a back-to-back request.
            // The ready pulse marks the boundary, so accept the next request
            // on the following clock without waiting for mem_valid to fall.
            RV_REPLY: rv_state <= RV_IDLE;
            default: rv_state <= RV_IDLE;
        endcase
    end
end

// -------------------------------------------------------------------------
// VDC0 bridge. The VDC changes its memory slot on clkref; the request remains
// stable until the bank-3 slot accepts it. Address bit 15 is outside the
// physical 32K-word VRAM and reads as zero.
// -------------------------------------------------------------------------
reg         vram_req;
wire        vram_ack;
reg  [14:0] vram_addr_r;
reg  [15:0] vram_din_r;
reg         vram_we_r;
wire [15:0] vram_dout_mem;
reg  [15:0] vram_addr_seen;
reg         vram_rd_d;
reg         vram_we_d;

assign vram_dout = vram_addr[15] ? 16'd0 : vram_dout_mem;

always @(posedge clk_mem) begin
    if (!resetn) begin
        vram_req       <= 1'b0;
        vram_addr_r    <= 15'd0;
        vram_din_r     <= 16'd0;
        vram_we_r      <= 1'b0;
        vram_addr_seen <= 16'hffff;
        vram_rd_d      <= 1'b0;
        vram_we_d      <= 1'b0;
    end else begin
        vram_rd_d <= vram_rd;
        vram_we_d <= vram_we;

        if (!vram_addr[15] &&
            ((vram_we && (!vram_we_d || vram_addr != vram_addr_seen)) ||
             (vram_rd && (!vram_rd_d || vram_addr != vram_addr_seen)))) begin
            vram_addr_r    <= vram_addr[14:0];
            vram_din_r     <= vram_din;
            vram_we_r      <= vram_we;
            vram_addr_seen <= vram_addr;
            vram_req       <= ~vram_req;
        end
    end
end

reg         vram1_req;
wire        vram1_ack;
reg  [14:0] vram1_addr_r;
reg  [15:0] vram1_din_r;
reg         vram1_we_r;
wire [15:0] vram1_dout_mem;
reg  [15:0] vram1_addr_seen;
reg         vram1_rd_d;
reg         vram1_we_d;

assign vram1_dout = vram1_addr[15] ? 16'd0 : vram1_dout_mem;

always @(posedge clk_mem) begin
    if (!resetn) begin
        vram1_req       <= 1'b0;
        vram1_addr_r    <= 15'd0;
        vram1_din_r     <= 16'd0;
        vram1_we_r      <= 1'b0;
        vram1_addr_seen <= 16'hffff;
        vram1_rd_d      <= 1'b0;
        vram1_we_d      <= 1'b0;
    end else begin
        vram1_rd_d <= vram1_rd;
        vram1_we_d <= vram1_we;

        if (!vram1_addr[15] &&
            ((vram1_we && (!vram1_we_d || vram1_addr != vram1_addr_seen)) ||
             (vram1_rd && (!vram1_rd_d || vram1_addr != vram1_addr_seen)))) begin
            vram1_addr_r    <= vram1_addr[14:0];
            vram1_din_r     <= vram1_din;
            vram1_we_r      <= vram1_we;
            vram1_addr_seen <= vram1_addr;
            vram1_req       <= ~vram1_req;
        end
    end
end

pce_sdram_interleaved #(
    .FREQ(FREQ)
) memory (
    .SDRAM_DQ(IO_sdram_dq),
    .SDRAM_A(O_sdram_addr),
    .SDRAM_DQM(O_sdram_dqm),
    .SDRAM_BA(O_sdram_ba),
    .SDRAM_nCS(O_sdram_cs_n),
    .SDRAM_nWE(O_sdram_wen_n),
    .SDRAM_nRAS(O_sdram_ras_n),
    .SDRAM_nCAS(O_sdram_cas_n),
    .SDRAM_CLK(O_sdram_clk),
    .SDRAM_CKE(O_sdram_cke),
    .clk(clk_mem),
    .clk_sdram(clk_sdram),
    .clkref(clkref),
    .refresh_window(refresh_window),
    .resetn(resetn),
    .host_addr(host_addr),
    .host_din(host_din),
    .host_ds(host_ds),
    .host_dout(host_dout),
    .host_req(host_req),
    .host_ack(host_ack),
    .host_we(host_we),
    .rv_addr(rv_mem_addr),
    .rv_din(rv_mem_din),
    .rv_ds(rv_mem_ds),
    .rv_dout(rv_mem_dout),
    .rv_req(rv_mem_req),
    .rv_ack(rv_mem_ack),
    .rv_we(rv_mem_we),
    .vram_addr(vram_addr_r),
    .vram_din(vram_din_r),
    .vram_dout(vram_dout_mem),
    .vram_req(vram_req),
    .vram_ack(vram_ack),
    .vram_we(vram_we_r),
    .vram_active(vram_rd | vram_we),
    .vram1_addr(vram1_addr_r),
    .vram1_din(vram1_din_r),
    .vram1_dout(vram1_dout_mem),
    .vram1_req(vram1_req),
    .vram1_ack(vram1_ack),
    .vram1_we(vram1_we_r),
    .vram1_active(vram1_rd | vram1_we),
    .init_done(init_done_mem)
);
endmodule


module pce_sdram_interleaved #(
    parameter FREQ = 86_400_000
) (
    inout  wire [31:0] SDRAM_DQ,
    output wire [10:0] SDRAM_A,
    output reg  [3:0]  SDRAM_DQM,
    output reg  [1:0]  SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CLK,
    output wire        SDRAM_CKE,
    input  wire        clk,
    input  wire        clk_sdram,
    input  wire        clkref,
    input  wire        refresh_window,
    input  wire        resetn,

    input  wire [22:0] host_addr,
    input  wire [15:0] host_din,
    input  wire [1:0]  host_ds,
    output reg  [15:0] host_dout,
    input  wire        host_req,
    output reg         host_ack,
    input  wire        host_we,

    input  wire [22:0] rv_addr,
    input  wire [31:0] rv_din,
    input  wire [3:0]  rv_ds,
    output reg  [31:0] rv_dout,
    input  wire        rv_req,
    output reg         rv_ack,
    input  wire        rv_we,

    input  wire [14:0] vram_addr,
    input  wire [15:0] vram_din,
    output reg  [15:0] vram_dout,
    input  wire        vram_req,
    output reg         vram_ack,
    input  wire        vram_we,
    input  wire        vram_active,

    input  wire [14:0] vram1_addr,
    input  wire [15:0] vram1_din,
    output reg  [15:0] vram1_dout,
    input  wire        vram1_req,
    output reg         vram1_ack,
    input  wire        vram1_we,
    input  wire        vram1_active,
    output reg         init_done
);

localparam CMD_NOP          = 4'b1111;
localparam CMD_SET_MODE     = 4'b0000;
localparam CMD_ACTIVATE     = 4'b0011;
localparam CMD_WRITE        = 4'b0100;
localparam CMD_READ         = 4'b0101;
localparam CMD_REFRESH      = 4'b0001;
localparam CMD_PRECHARGE    = 4'b0010;
localparam [10:0] MODE_REG  = {4'b0000, 3'd2, 1'b0, 3'b000};
localparam integer CFG_DELAY = FREQ / 5000;

reg [3:0]  cmd;
reg [10:0] addr_out;
reg        dq_oen;
reg [31:0] dq_out;
wire [31:0] dq_in = SDRAM_DQ;

assign SDRAM_DQ = dq_oen ? 32'bz : dq_out;
assign SDRAM_A = addr_out;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_CLK = clk_sdram;
assign SDRAM_CKE = 1'b1;

reg [$clog2(CFG_DELAY)-1:0] cfg_delay;
reg [4:0] init_cycle;
reg       configuring;
reg [2:0] cycle;
reg       clkref_r;

reg        refresh_block;
reg [15:0] refresh_cnt;

// Distributed, on-demand refresh (SNESTang model): instead of concentrating
// all refresh commands into the vblank window (refresh_window), where they
// directly compete with the VDC0 SATB/sprite burst fetch right at the start
// of vblank, spread single refresh commands across the whole frame and only
// issue one when the bus is genuinely idle (no channel active and no VRAM0/
// VRAM1 request freshly pending, and no active VDC0 read window). This mirrors
// nand2mario/snestang's
// sdram_nano.v, which refreshes off a free-running cycle counter instead of
// a vblank-gated burst. 64ms/8192 rows -> ~7.8us between refreshes.
reg [22:0] addr_latch [0:2];
reg [15:0] din_latch  [0:2];
reg [1:0]  ds_latch   [0:2];
reg [31:0] rv_din_latch;
reg [3:0]  rv_ds_latch;
reg [2:0]  oe_latch;
reg [2:0]  we_latch;
reg [2:0]  active;
reg [1:0]  channel1_port;
reg        host_cas_done;

// Distributed, on-demand refresh (SNESTang model): instead of concentrating
// all refresh commands into the vblank window (refresh_window), where they
// directly compete with the VDC0 SATB/sprite burst fetch right at the start
// of vblank, spread single refresh commands across the whole frame and only
// issue one when the bus is genuinely idle (no channel active and no VRAM0/
// VRAM1 request freshly pending). This mirrors nand2mario/snestang's
// sdram_nano.v, which refreshes off a free-running cycle counter instead of
// a vblank-gated burst. 64ms/8192 rows -> ~7.8us between refreshes.
localparam integer RFRSH_CYCLES = FREQ / 128_000;
wire       vram_pending  = (vram_req  != vram_ack);
wire       vram1_pending = (vram1_req != vram1_ack);
wire       need_refresh  = refresh_cnt >= RFRSH_CYCLES[15:0];
wire       refresh_now   = need_refresh &&
                            !active[0] && !active[1] && !active[2] &&
                            !vram_pending && !vram1_pending &&
                            !vram_active && !vram1_active;

localparam CHANNEL1_NONE  = 2'd0;
localparam CHANNEL1_RV    = 2'd1;
localparam CHANNEL1_VRAM1 = 2'd2;

always @(posedge clk) begin
    if (!resetn) begin
        cmd           <= CMD_NOP;
        addr_out      <= 11'd0;
        SDRAM_DQM     <= 4'b1111;
        SDRAM_BA      <= 2'b00;
        dq_oen        <= 1'b1;
        dq_out        <= 32'd0;
        cfg_delay     <= 0;
        init_cycle    <= 0;
        configuring   <= 1'b0;
        init_done     <= 1'b0;
        cycle         <= 3'd0;
        clkref_r      <= 1'b0;
        refresh_block <= 1'b0;
        refresh_cnt   <= 16'd0;
        host_ack      <= 1'b0;
        rv_ack        <= 1'b0;
        vram_ack      <= 1'b0;
        vram1_ack     <= 1'b0;
        host_dout     <= 16'd0;
        rv_dout       <= 32'd0;
        vram_dout     <= 16'd0;
        vram1_dout    <= 16'd0;
        oe_latch      <= 3'b000;
        we_latch      <= 3'b000;
        active        <= 3'b000;
        channel1_port <= CHANNEL1_NONE;
        host_cas_done <= 1'b0;
    end else begin
        cmd       <= CMD_NOP;
        SDRAM_DQM <= 4'b1111;
        dq_oen    <= 1'b1;
        clkref_r  <= clkref;

        if (!init_done && !configuring) begin
            if (cfg_delay == CFG_DELAY-1) begin
                configuring <= 1'b1;
                init_cycle  <= 0;
            end else begin
                cfg_delay <= cfg_delay + 1'b1;
            end
        end else if (configuring) begin
            init_cycle <= init_cycle + 1'b1;
            case (init_cycle)
                0: begin
                    cmd <= CMD_PRECHARGE;
                    addr_out[10] <= 1'b1;
                    SDRAM_BA <= 2'b00;
                end
                2:  cmd <= CMD_REFRESH;
                8:  cmd <= CMD_REFRESH;
                14: begin
                    cmd <= CMD_SET_MODE;
                    addr_out <= MODE_REG;
                    SDRAM_BA <= 2'b00;
                end
                16: begin
                    configuring <= 1'b0;
                    init_done   <= 1'b1;
                    cycle       <= 3'd0;
                end
                default: ;
            endcase
        end else if (init_done) begin
            // The phase counter resyncs to clkref every dot clock unless a
            // refresh command is actually in flight (refresh_block). Refresh
            // itself is now distributed across the whole frame based on
            // refresh_cnt (see note above), not concentrated into vblank, so
            // it no longer collides systematically with the VDC0 SATB/sprite
            // burst fetch at the start of vblank (confirmed in
            // sim/tb_sprite_stream.v).
            if (clkref && !clkref_r && !refresh_block)
                cycle <= 3'd1;
            else
                cycle <= cycle + 3'd1;

            // Free-running refresh timer: reset only when a refresh is
            // actually issued below, otherwise keep counting so need_refresh
            // stays asserted (and refresh_now keeps trying) until the bus is
            // idle enough to take it.
            if (cycle == 3'd0 && refresh_now)
                refresh_cnt <= 16'd0;
            else
                refresh_cnt <= refresh_cnt + 16'd1;

            // Complete the host read from its cycle-5 CAS.
            if (cycle == 3'd0) begin
                refresh_block <= 1'b0;
                if (active[0] && host_cas_done) begin
                    if (oe_latch[0])
                        host_dout <= addr_latch[0][1] ?
                                     dq_in[31:16] : dq_in[15:0];
                    host_ack <= host_req;
                    active[0] <= 1'b0;
                    host_cas_done <= 1'b0;
                end

                if (refresh_now) begin
                    cmd           <= CMD_REFRESH;
                    refresh_block <= 1'b1;
                end
            end

            // Channel 1: VDC1 has priority over PicoRV32.
            if (cycle == 3'd1 && !refresh_block) begin
                if (vram1_req != vram1_ack) begin
                    active[1]       <= 1'b1;
                    channel1_port   <= CHANNEL1_VRAM1;
                    addr_latch[1]   <= {7'b1011111, vram1_addr, 1'b0};
                    din_latch[1]    <= vram1_din;
                    ds_latch[1]     <= 2'b11;
                    we_latch[1]     <= vram1_we;
                    oe_latch[1]     <= !vram1_we;
                    addr_out        <= {5'b11111, vram1_addr[14:9]};
                    SDRAM_BA        <= 2'b10;
                    cmd             <= CMD_ACTIVATE;
                end else if (rv_req != rv_ack) begin
                    active[1]     <= 1'b1;
                    channel1_port <= CHANNEL1_RV;
                    addr_latch[1] <= rv_addr;
                    rv_din_latch  <= rv_din;
                    rv_ds_latch   <= rv_ds;
                    we_latch[1]   <= rv_we;
                    oe_latch[1]   <= !rv_we;
                    addr_out      <= rv_addr[20:10];
                    SDRAM_BA      <= rv_addr[22:21];
                    cmd           <= CMD_ACTIVATE;
                end else begin
                    active[1]     <= 1'b0;
                    channel1_port <= CHANNEL1_NONE;
                    we_latch[1]   <= 1'b0;
                    oe_latch[1]   <= 1'b0;
                end
            end

            // VDC0 RAS at cycle 2.
            if (cycle == 3'd2 && !refresh_block) begin
                active[2] <= vram_req != vram_ack;
                if (vram_req != vram_ack) begin
                    addr_latch[2] <= {7'b1111111, vram_addr, 1'b0};
                    din_latch[2]  <= vram_din;
                    ds_latch[2]   <= 2'b11;
                    we_latch[2]   <= vram_we;
                    oe_latch[2]   <= !vram_we;
                    addr_out      <= {5'b11111, vram_addr[14:9]};
                    SDRAM_BA      <= 2'b11;
                    cmd           <= CMD_ACTIVATE;
                end else begin
                    active[2]   <= 1'b0;
                    we_latch[2] <= 1'b0;
                    oe_latch[2] <= 1'b0;
                end

                if (active[0] && we_latch[0] &&
                    vram_req == vram_ack) begin
                    host_cas_done <= 1'b1;
                    cmd           <= CMD_WRITE;
                    addr_out      <= {3'b100, addr_latch[0][9:2]};
                    SDRAM_BA      <= addr_latch[0][22:21];
                    dq_oen        <= 1'b0;
                    dq_out        <= {din_latch[0], din_latch[0]};
                    SDRAM_DQM     <= addr_latch[0][1] ?
                                     {~ds_latch[0], 2'b11} :
                                     {2'b11, ~ds_latch[0]};
                end
            end

            // VDC1 / PicoRV32 CAS at cycle 3.
            if (cycle == 3'd3 && active[1]) begin
                if (channel1_port == CHANNEL1_VRAM1)
                    vram1_ack <= vram1_req;
                cmd      <= we_latch[1] ? CMD_WRITE : CMD_READ;
                addr_out <= {3'b100, addr_latch[1][9:2]};
                SDRAM_BA <= addr_latch[1][22:21];
                if (we_latch[1]) begin
                    dq_oen    <= 1'b0;
                    if (channel1_port == CHANNEL1_RV) begin
                        dq_out    <= rv_din_latch;
                        SDRAM_DQM <= ~rv_ds_latch;
                    end else begin
                        dq_out    <= {din_latch[1], din_latch[1]};
                        SDRAM_DQM <= addr_latch[1][1] ?
                                     4'b0011 : 4'b1100;
                    end
                end else begin
                    SDRAM_DQM <= 4'b0000;
                end
            end

            // VDC0 CAS at cycle 4.
            if (cycle == 3'd4 && active[2]) begin
                vram_ack <= vram_req;
                cmd      <= we_latch[2] ? CMD_WRITE : CMD_READ;
                addr_out <= {3'b100, addr_latch[2][9:2]};
                SDRAM_BA <= 2'b11;
                if (we_latch[2]) begin
                    dq_oen    <= 1'b0;
                    dq_out    <= {din_latch[2], din_latch[2]};
                    SDRAM_DQM <= addr_latch[2][1] ? 4'b0011 : 4'b1100;
                end else begin
                    SDRAM_DQM <= 4'b0000;
                end
            end

            // Host read CAS at cycle 5.
            if (cycle == 3'd5 && active[0] && !we_latch[0] &&
                !host_cas_done) begin
                host_cas_done <= 1'b1;
                cmd           <= CMD_READ;
                addr_out      <= {3'b100, addr_latch[0][9:2]};
                SDRAM_BA      <= addr_latch[0][22:21];
                SDRAM_DQM     <= 4'b0000;
            end

            // VDC1 / PicoRV32 read data at cycle 6.
            if (cycle == 3'd6 && active[1]) begin
                if (channel1_port == CHANNEL1_RV) begin
                    if (oe_latch[1])
                        rv_dout <= dq_in;
                    rv_ack <= rv_req;
                end else begin
                    if (oe_latch[1])
                        vram1_dout <= addr_latch[1][1] ?
                                      dq_in[31:16] : dq_in[15:0];
                    else
                        vram1_dout <= din_latch[1];
                end
                active[1] <= 1'b0;
            end

            // VDC0 read data and next host RAS at cycle 7.
            if (cycle == 3'd7 && active[2]) begin
                if (oe_latch[2])
                    vram_dout <= addr_latch[2][1] ?
                                 dq_in[31:16] : dq_in[15:0];
                else
                    vram_dout <= din_latch[2];
                active[2] <= 1'b0;
            end
            if (cycle == 3'd7 && !refresh_block && !active[0] &&
                host_req != host_ack) begin
                active[0]     <= 1'b1;
                addr_latch[0] <= host_addr;
                din_latch[0]  <= host_din;
                ds_latch[0]   <= host_ds;
                we_latch[0]   <= host_we;
                oe_latch[0]   <= !host_we;
                host_cas_done <= 1'b0;
                addr_out      <= host_addr[20:10];
                SDRAM_BA      <= host_addr[22:21];
                cmd           <= CMD_ACTIVATE;
            end
        end
    end
end

endmodule
