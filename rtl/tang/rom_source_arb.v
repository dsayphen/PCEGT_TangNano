//
// ROM source arbiter for the Tang Nano 20K PC Engine port.
//
// Two loaders can fill the HuCard ROM in SDRAM:
//
//   * sd_loader.v   - runs once at power-on, reads /GAME.PCE from the microSD
//                     card (the default way to start a game)
//   * rom_loader.v  - the UART loader, always available, used as the fallback
//                     when there is no card / no file and to replace the image
//                     at any later time
//
// Exactly one of them owns the SDRAM write port at any instant.  SD owns it
// from reset; ownership moves to the UART loader - permanently - as soon as
// either
//
//   * the SD attempt fails (sd_failed), or
//   * the UART loader starts receiving an image (ua_loading).
//
// The switch is a multiplexer driven by `own_uart_next`, never an OR of the
// two write strobes, so the two sources can never write in the same cycle.
// `own_uart_next` is combinational in the two (registered) trigger signals, so
// the aggregate `loading` rises and `image_valid` falls in the very cycle the
// UART loader announces a new transfer - before its first payload byte, which
// is at least one character time (>= 375 clocks at 115200 baud) away.  The SD
// side sees `sd_enable` drop in the same cycle, which resets the SD reader and
// parks the SD adapter.
//
// The loser of the arbitration is given ld_busy = 1 so that it can never
// believe a write was accepted while it was masked out.
//

module rom_source_arb (
    input  wire        clk,
    input  wire        resetn,

    // ---- SD loader -------------------------------------------------------
    input  wire        sd_ld_wr,
    input  wire [22:0] sd_ld_addr,
    input  wire [7:0]  sd_ld_data,
    input  wire        sd_loading,
    input  wire        sd_image_valid,
    input  wire [7:0]  sd_rom_sz,
    input  wire [22:0] sd_rom_offset,
    input  wire        sd_failed,
    output wire        sd_enable,
    output wire        sd_ld_busy,

    // ---- UART loader -----------------------------------------------------
    input  wire        ua_ld_wr,
    input  wire [22:0] ua_ld_addr,
    input  wire [7:0]  ua_ld_data,
    input  wire        ua_loading,
    input  wire        ua_image_valid,
    input  wire [7:0]  ua_rom_sz,
    input  wire [22:0] ua_rom_offset,
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
    output wire        own_uart_o      // 0 = SD owns, 1 = UART owns
);

reg  own_uart;
wire own_uart_next = own_uart | sd_failed | ua_loading;

always @(posedge clk) begin
    if (!resetn)
        own_uart <= 1'b0;
    else
        own_uart <= own_uart_next;
end

assign ld_wr       = own_uart_next ? ua_ld_wr       : sd_ld_wr;
assign ld_addr     = own_uart_next ? ua_ld_addr     : sd_ld_addr;
assign ld_data     = own_uart_next ? ua_ld_data     : sd_ld_data;
assign loading     = own_uart_next ? ua_loading     : sd_loading;
assign image_valid = own_uart_next ? ua_image_valid : sd_image_valid;
assign rom_sz      = own_uart_next ? ua_rom_sz      : sd_rom_sz;
assign rom_offset  = own_uart_next ? ua_rom_offset  : sd_rom_offset;

assign sd_enable   = ~own_uart_next;
assign sd_ld_busy  = own_uart_next ? 1'b1 : ld_busy;
assign ua_ld_busy  = own_uart_next ? ld_busy : 1'b1;

assign own_uart_o  = own_uart_next;

endmodule
