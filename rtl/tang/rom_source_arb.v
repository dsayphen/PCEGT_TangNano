//
// ROM source arbiter for the Tang Nano 20K PC Engine port.
//
// Two loaders can fill the HuCard ROM in SDRAM:
//
//   * the PicoRV32 IO subsystem (rtl/tang/iosys/iosys.v), whose firmware shows
//     the on-screen menu and streams the .PCE file the user picked off the
//     microSD card.  This is the normal way to start a game and it can be
//     used again at any time without a power cycle.
//   * rom_loader.v - the UART loader, always available, used as the fallback
//     when there is no card / no menu and to replace the image from a host PC
//     (see tools/pce_send.py).
//
// Exactly one of them owns the SDRAM write port at any instant.  Ownership
// follows whoever started a transfer most recently and is sticky in between,
// so the ROM description (`rom_sz` / `rom_offset` / `image_valid`) published
// to the core always belongs to the image that is actually in memory:
//
//     own_uart_next = ua_loading    ? 1              // UART transfer running
//                   : rv_loading    ? 0              // menu load running
//                                   : own_uart;      // keep the last owner
//
// `own_uart_next` is combinational in the two (registered) `loading` inputs,
// so the aggregate `loading` rises and `image_valid` falls in the very cycle a
// loader announces a new transfer - before its first payload byte, which for
// the UART is at least one character time (>= 375 clocks at 115200 baud) away.
//
// The switch is a multiplexer, never an OR of the two write strobes, so the
// two sources can never write in the same cycle, and the loser is given
// ld_busy = 1 so that it can never believe a write was accepted while it was
// masked out.  A UART transfer started in the middle of a menu load is
// therefore not mixed in: it simply stalls until the menu load has finished
// (and will usually time out and be retried, which is the documented
// behaviour - do not start a UART upload while the menu is loading).
//

module rom_source_arb (
    input  wire        clk,
    input  wire        resetn,

    // ---- softcore / menu loader -----------------------------------------
    input  wire        rv_ld_wr,
    input  wire [22:0] rv_ld_addr,
    input  wire [7:0]  rv_ld_data,
    input  wire        rv_loading,
    input  wire        rv_image_valid,
    input  wire [7:0]  rv_rom_sz,
    input  wire [22:0] rv_rom_offset,
    input  wire        rv_sgx_mode,
    output wire        rv_ld_busy,

    // ---- UART loader -----------------------------------------------------
    input  wire        ua_ld_wr,
    input  wire [22:0] ua_ld_addr,
    input  wire [7:0]  ua_ld_data,
    input  wire        ua_loading,
    input  wire        ua_image_valid,
    input  wire [7:0]  ua_rom_sz,
    input  wire [22:0] ua_rom_offset,
    input  wire        ua_sgx_mode,
    output wire        ua_ld_busy,

    // ---- aggregate -------------------------------------------------------
    output wire        ld_wr,
    output wire [22:0] ld_addr,
    output wire [7:0]  ld_data,
    input  wire        ld_busy,
    output wire        loading,
    output wire        image_valid,
    output wire [7:0]  rom_sz,
    output wire [22:0] rom_offset,
    output wire        sgx_mode,
    output wire        own_uart_o      // 0 = softcore owns, 1 = UART owns
);

reg  own_uart;
wire own_uart_next = ua_loading ? 1'b1 : (rv_loading ? 1'b0 : own_uart);

always @(posedge clk) begin
    if (!resetn)
        own_uart <= 1'b0;
    else
        own_uart <= own_uart_next;
end

assign ld_wr       = own_uart_next ? ua_ld_wr       : rv_ld_wr;
assign ld_addr     = own_uart_next ? ua_ld_addr     : rv_ld_addr;
assign ld_data     = own_uart_next ? ua_ld_data     : rv_ld_data;
assign loading     = own_uart_next ? ua_loading     : rv_loading;
assign image_valid = own_uart_next ? ua_image_valid : rv_image_valid;
assign rom_sz      = own_uart_next ? ua_rom_sz      : rv_rom_sz;
assign rom_offset  = own_uart_next ? ua_rom_offset  : rv_rom_offset;
assign sgx_mode    = own_uart_next ? ua_sgx_mode    : rv_sgx_mode;

assign rv_ld_busy  = own_uart_next ? 1'b1 : ld_busy;
assign ua_ld_busy  = own_uart_next ? ld_busy : 1'b1;

assign own_uart_o  = own_uart_next;

endmodule
