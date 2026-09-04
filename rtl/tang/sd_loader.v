//
// SD card auto-boot adapter for the Tang Nano 20K PC Engine port.
//
// Wraps the vendored SD-native FAT16/FAT32 reader (rtl/tang/sd/sd_file_reader.v,
// RonnyA/nd-120, MIT) and turns its free running byte stream into the same
// byte-write SDRAM interface the UART loader uses:
//
//     sd_file_reader ---> 16 byte FIFO ---> ld_wr / ld_addr / ld_data
//
// At power-on the reader initialises the card (SDv1 / SDv2 / SDHC, byte or
// block addressing), mounts sector 0 as either a bare FAT volume
// ("superfloppy") or as an MBR and walks its partition table, scans the root
// directory and streams the first file whose name matches GAME.PCE
// (case-insensitive) into SDRAM, following the FAT cluster chain, so a
// fragmented file works exactly like a contiguous one.
//
// The image is written to SDRAM from byte address 0, header included, and the
// ROM description is published exactly like the UART loader does:
//
//     rom_sz     = size >> 16
//     rom_offset = 512 when size & 0x3FF == 0x200, else 0
//
// `loading` is asserted from reset and is only released when the attempt has
// finished, so the console never runs while SDRAM is being written.
//
// An attempt is accepted only when *all* of these hold:
//
//   * the reader reported file_found (a real directory match, not just the
//     end of the scan - scan_done alone also means "not found", "unmountable"
//     or "stream aborted"),
//   * the directory size is inside [MIN_SIZE, MAX_SIZE],
//   * the number of bytes emitted by the reader equals that size,
//   * every one of those bytes has been written: the FIFO is empty, no write
//     strobe is outstanding and the SDRAM controller reports ld_idle, i.e. the
//     last write has actually completed inside the SDRAM,
//   * no FIFO overflow and no surplus byte was ever seen.
//
// Anything else (no card, no file system, no GAME.PCE, CRC error, truncated
// stream, stall) ends in `failed`, which hands the SDRAM over to the UART
// loader.  Because the reader retries card initialisation forever when no card
// answers, a watchdog bounds the whole attempt.
//
// Backpressure: the reader has none, so the FIFO must never fill up.  At
// CLK_DIV = 2 the data clock is clk/4 = 10.8 MHz and one bit is sampled per SD
// clock (1-bit mode), i.e. one byte per 32 clk cycles.  Worst case in
// pce_sdram_ctrl, a byte arriving one cycle after a ROM read was issued waits
// 8 cycles for that read plus 7 cycles for its own write = 15 cycles, and
// loader writes have priority over refresh, so at most one FIFO entry is ever
// occupied.  16 entries give a 32x margin; DEPTH_LOG2 can be reduced to 2 if
// the LUTs are ever needed.
//

module sd_loader #(
    parameter CLK_FREQ   = 43_200_000,
    // data clock = clk / (2*CLK_DIV); 2 -> 10.8 MHz at 43.2 MHz.
    // The card identification clock is fixed at clk/198 = 218 kHz.
    parameter [2:0] CLK_DIV = 3'd2,
    parameter MIN_SIZE   = 32'h0000_0400,   // 1 KiB
    parameter MAX_SIZE   = 32'h0040_0000,   // 4 MiB
    // whole attempt / stream stall watchdog, in milliseconds
    parameter TIMEOUT_MS = 5000,
    parameter SIMULATE   = 0
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        enable,        // 0 = another source owns SDRAM: park

    // SD card, native 1-bit mode (CMD is bidirectional, tri-stated in the top)
    output wire        sd_clk,
    input  wire        sd_cmd_i,
    output wire        sd_cmd_o,
    output wire        sd_cmd_oe,
    input  wire        sd_dat0,

    // SDRAM write port (identical to the one used by rom_loader.v)
    output reg         ld_wr,
    output reg  [22:0] ld_addr,
    output reg  [7:0]  ld_data,
    input  wire        ld_busy,
    input  wire        ld_idle,       // no loader write pending *or* in flight

    // status / ROM description
    output reg         loading,
    output reg         image_valid,
    output reg  [7:0]  rom_sz,
    output reg  [22:0] rom_offset,
    output reg         failed,        // terminal: release the UART fallback
    output reg  [3:0]  err_code       // see E_* below, 0 while running / ok
);

// error codes, for simulation and for anybody hooking up a debug LED
localparam [3:0] E_NONE     = 4'd0;
localparam [3:0] E_TIMEOUT  = 4'd1;   // watchdog: no card / stalled stream
localparam [3:0] E_NOFILE   = 4'd2;   // scan finished without a match
localparam [3:0] E_SIZE     = 4'd3;   // size outside [MIN_SIZE, MAX_SIZE]
localparam [3:0] E_SHORT    = 4'd4;   // fewer bytes than announced
localparam [3:0] E_OVERRUN  = 4'd5;   // more bytes than announced
localparam [3:0] E_FIFO     = 4'd6;   // FIFO overflow (must never happen)
localparam [3:0] E_ABORT    = 4'd7;   // disabled while running (UART takeover)

// "GAME.PCE", byte 0 in the LOW byte: the reader compares
// target_name[8*i +: 8] against character i of the directory entry.
localparam [52*8-1:0] TARGET_NAME =
    {{(52-8){8'h00}},
     8'h45, 8'h43, 8'h50, 8'h2E, 8'h45, 8'h4D, 8'h41, 8'h47};  // E C P . E M A G
localparam [7:0] TARGET_LEN = 8'd8;

localparam [31:0] TIMEOUT = (CLK_FREQ / 1000) * TIMEOUT_MS;

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------
wire        rd_file_found;
wire        rd_outen;
wire [7:0]  rd_outbyte;
wire        rd_scan_done;
wire [31:0] rd_file_size;

wire        rdr_rstn = resetn & enable;

sd_file_reader #(
    .CLK_DIV  (CLK_DIV),
    .SIMULATE (SIMULATE)
) u_reader (
    .rstn      (rdr_rstn),
    .clk       (clk),

    .sdclk     (sd_clk),
    .sdcmd_i   (sd_cmd_i),
    .sdcmd_o   (sd_cmd_o),
    .sdcmd_oe  (sd_cmd_oe),
    .sddat0    (sd_dat0),

    .card_stat       (),
    .card_type       (),
    .filesystem_type (),

    .file_found      (rd_file_found),
    .outen           (rd_outen),
    .outbyte         (rd_outbyte),
    .scan_done       (rd_scan_done),
    .found_file_size (rd_file_size),

    .target_name (TARGET_NAME),
    .target_len  (TARGET_LEN),
    .no_stream   (1'b0),

    .dir_entry_valid   (),
    .dir_entry_name    (),
    .dir_entry_len     (),
    .dir_entry_size    (),
    .dir_entry_date    (),
    .dir_entry_cluster (),
    .dir_entry_is_dir  (),

    .found_file_first_sector (),

    .fs_cluster_size     (),
    .fs_fat0_sector      (),
    .fs_sectors_per_fat  (),
    .fs_num_fats         (),
    .fs_data_base_sector (),
    .fs_total_sectors    (),
    .fs_root_cluster     (),

    .found_dir_entry_sector (),
    .found_dir_entry_index  (),
    .found_file_cluster     (),

    .card_capacity_mb (),
    .card_rca         ()
);

// ---------------------------------------------------------------------------
// Byte FIFO (16 entries)
// ---------------------------------------------------------------------------
localparam DEPTH_LOG2 = 4;

reg  [7:0] fifo [0:(1<<DEPTH_LOG2)-1];
reg  [DEPTH_LOG2:0] wptr;
reg  [DEPTH_LOG2:0] rptr;

wire [DEPTH_LOG2:0] fifo_cnt = wptr - rptr;
wire fifo_empty = (wptr == rptr);
wire fifo_full  = fifo_cnt[DEPTH_LOG2];

wire [7:0] fifo_head = fifo[rptr[DEPTH_LOG2-1:0]];

// ---------------------------------------------------------------------------
// Transfer state
// ---------------------------------------------------------------------------
localparam [1:0] S_RUN   = 2'd0;   // card init / scan / stream
localparam [1:0] S_DRAIN = 2'd1;   // reader finished: flush the FIFO
localparam [1:0] S_DONE  = 2'd2;   // parked, image_valid or failed is set

reg [1:0]  state;
reg [31:0] size;          // directory size of the matched file
reg        size_seen;     // file_found has been latched
reg        size_ok;
reg [31:0] rcv_cnt;       // bytes taken from the reader
reg [31:0] wr_cnt;        // bytes handed to the SDRAM controller
reg [22:0] wr_ptr;
reg [31:0] wd;            // watchdog
reg [3:0]  err;

wire wr_go = !fifo_empty && !ld_busy && !ld_wr;

always @(posedge clk) begin
    ld_wr <= 1'b0;

    // ---------------------------------------------------------- FIFO fill
    if (state == S_RUN && rd_outen) begin
        if (fifo_full) begin
            err <= E_FIFO;
        end else begin
            fifo[wptr[DEPTH_LOG2-1:0]] <= rd_outbyte;
            wptr    <= wptr + 1'b1;
            rcv_cnt <= rcv_cnt + 32'd1;
            if (size_seen && rcv_cnt >= size)
                err <= E_OVERRUN;
        end
    end

    // ---------------------------------------------------------- FIFO drain
    if (wr_go) begin
        ld_wr   <= 1'b1;
        ld_addr <= wr_ptr;
        ld_data <= fifo_head;
        rptr    <= rptr + 1'b1;
        wr_ptr  <= wr_ptr + 23'd1;
        wr_cnt  <= wr_cnt + 32'd1;
    end

    // ---------------------------------------------------------- size latch
    if (state == S_RUN && rd_file_found && !size_seen) begin
        size      <= rd_file_size;
        size_seen <= 1'b1;
        size_ok   <= (rd_file_size >= MIN_SIZE) && (rd_file_size <= MAX_SIZE);
        wd        <= 32'd0;
    end

    // ---------------------------------------------------------- watchdog
    // reset by every streamed byte; card init, mount and the directory scan
    // must therefore all finish inside one TIMEOUT window
    if (state != S_RUN)
        wd <= 32'd0;
    else if (rd_outen)
        wd <= 32'd0;
    else if (wd != TIMEOUT)
        wd <= wd + 32'd1;

    // ---------------------------------------------------------- main FSM
    case (state)
        S_RUN: begin
            if (err != E_NONE) begin
                state <= S_DRAIN;
            end else if (wd == TIMEOUT) begin
                err   <= E_TIMEOUT;
                state <= S_DRAIN;
            end else if (rd_scan_done) begin
                if (!rd_file_found)      err <= E_NOFILE;
                else if (!size_ok)       err <= E_SIZE;
                else if (rcv_cnt != size) err <= E_SHORT;
                state <= S_DRAIN;
            end
        end

        // Everything the reader produced has been accepted; wait until it has
        // also reached the SDRAM.  ld_idle is only meaningful one clock after
        // the last strobe, hence the !ld_wr term.
        S_DRAIN: begin
            if (err != E_NONE) begin
                if (!ld_wr && ld_idle) begin
                    err_code    <= err;
                    failed      <= 1'b1;
                    image_valid <= 1'b0;
                    loading     <= 1'b0;
                    state       <= S_DONE;
                end
            end else if (fifo_empty && !ld_wr && ld_idle) begin
                if (wr_cnt == size) begin
                    rom_sz      <= size[23:16];
                    rom_offset  <= (size[9:0] == 10'h200) ? 23'd512 : 23'd0;
                    image_valid <= 1'b1;
                    loading     <= 1'b0;
                    state       <= S_DONE;
                end else begin
                    err <= E_SHORT;
                end
            end
        end

        S_DONE: ;   // parked until the next reset

        default: state <= S_DONE;
    endcase

    // ---------------------------------------------------------- takeover
    // The UART loader has claimed the SDRAM: stop writing at once (the reader
    // is held in reset by rdr_rstn) and park without claiming a failure - the
    // new owner publishes the ROM description from now on.
    if (!enable && state != S_DONE) begin
        ld_wr       <= 1'b0;
        loading     <= 1'b0;
        image_valid <= 1'b0;
        failed      <= 1'b0;
        err_code    <= E_ABORT;
        state       <= S_DONE;
    end

    if (!resetn) begin
        state       <= S_RUN;
        ld_wr       <= 1'b0;
        ld_addr     <= 23'd0;
        ld_data     <= 8'd0;
        loading     <= 1'b1;      // hold the console until the attempt is over
        image_valid <= 1'b0;
        rom_sz      <= 8'd0;
        rom_offset  <= 23'd0;
        failed      <= 1'b0;
        err_code    <= E_NONE;
        err         <= E_NONE;
        size        <= 32'd0;
        size_seen   <= 1'b0;
        size_ok     <= 1'b0;
        rcv_cnt     <= 32'd0;
        wr_cnt      <= 32'd0;
        wr_ptr      <= 23'd0;
        wptr        <= {(DEPTH_LOG2+1){1'b0}};
        rptr        <= {(DEPTH_LOG2+1){1'b0}};
        wd          <= 32'd0;
    end
end

endmodule
