// gbc_cart_mapper - cartridge MBC for the gbc_core (PCEGT Tang Nano port)
//
// Derived from rtl/gb/gb_cart_mapper.sv of this repository (same register
// semantics: ROM only, MBC1, MBC3 without RTC, MBC5; cart RAM at 0x3E0000),
// split into:
//   * a register write port (1-clk strobe, CPU address/data), and
//   * a purely combinational translate port (16-bit bus address -> 22-bit
//     external byte address), used by the gbc_core memory interface for the
//     CPU, OAM DMA and HDMA.
// Additions: ROM bank masking with the header ROM size (0x148), MBC5 RAM
// enable decoded on the whole 0000-1FFF range, and an `ff` flag for accesses
// that must not reach SDRAM (unsupported mapper, out-of-range MBC5 bank,
// disabled / absent / out-of-range cart RAM): reads return 0xFF, writes are
// dropped.
module gbc_cart_mapper (
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  mapper_type,     // header 0x147
    input  wire [7:0]  rom_size_code,   // header 0x148
    input  wire [7:0]  ram_size_code,   // header 0x149

    // register write port (CPU writes to 0000-7FFF / A000-BFFF)
    input  wire        wr,
    input  wire [15:0] wr_addr,
    input  wire [7:0]  wr_data,

    // translate port (only meaningful for 0000-7FFF and A000-BFFF)
    input  wire [15:0] addr,
    output reg  [21:0] cart_addr,
    output reg         ff
);

localparam [21:0] CART_RAM_BASE = 22'h3e0000;

reg [7:0] rom_bank_low;
reg       rom_bank_high;
reg [1:0] mbc1_rom_high;
reg [1:0] mbc1_ram_bank;
reg [3:0] mbc5_ram_bank;
reg       mbc1_mode;
reg       ram_enabled;
reg [7:0] mbc3_ram_rtc_bank;

wire is_rom_only = mapper_type == 8'h00 ||
                   mapper_type == 8'h08 ||
                   mapper_type == 8'h09;
wire is_mbc1 = mapper_type >= 8'h01 && mapper_type <= 8'h03;
wire is_mbc3 = mapper_type >= 8'h0f && mapper_type <= 8'h13;
wire is_mbc5 = mapper_type >= 8'h19 && mapper_type <= 8'h1e;
wire mapper_supported = is_rom_only || is_mbc1 || is_mbc3 || is_mbc5;

wire mbc_ram_type = (is_mbc1 && (mapper_type == 8'h02 || mapper_type == 8'h03)) ||
                    (is_mbc3 && (mapper_type == 8'h10 ||
                                 mapper_type == 8'h12 ||
                                 mapper_type == 8'h13)) ||
                    (is_mbc5 && (mapper_type == 8'h1a ||
                                 mapper_type == 8'h1b ||
                                 mapper_type == 8'h1d ||
                                 mapper_type == 8'h1e));
wire rom_only_ram_type = is_rom_only &&
                         (mapper_type == 8'h08 || mapper_type == 8'h09);
// Cart RAM presence follows the header RAM size (0x149) for MBC1/3/5, even
// when the cartridge type byte says "no RAM" (e.g. 0x19), like most emulators.
wire has_cart_ram = ram_size_code != 0 &&
                    (mbc_ram_type || is_mbc1 || is_mbc3 || is_mbc5 ||
                     rom_only_ram_type);

// ROM size code n -> 2 << n banks of 16 KiB (n = 0..7 supported).
wire [7:0] rom_bank_mask =
    rom_size_code == 8'd0 ? 8'h01 :
    rom_size_code == 8'd1 ? 8'h03 :
    rom_size_code == 8'd2 ? 8'h07 :
    rom_size_code == 8'd3 ? 8'h0f :
    rom_size_code == 8'd4 ? 8'h1f :
    rom_size_code == 8'd5 ? 8'h3f :
    rom_size_code == 8'd6 ? 8'h7f : 8'hff;

wire [8:0] selected_rom_bank =
    is_mbc1 ? {2'b0, mbc1_rom_high, rom_bank_low[4:0]} :
    is_mbc3 ? {2'b0, rom_bank_low[6:0]} :
    is_mbc5 ? {rom_bank_high, rom_bank_low} :
              9'd1;
wire [8:0] switched_rom_bank =
    (selected_rom_bank == 0 && !is_mbc5) ? 9'd1 : selected_rom_bank;
wire [7:0] low_rom_bank =
    is_mbc1 && mbc1_mode ? {1'b0, mbc1_rom_high, 5'b0} : 8'd0;
wire switched_rom_bank_valid = !(is_mbc5 && rom_bank_high);

reg [3:0] selected_ram_bank;
always @* begin
    selected_ram_bank = 4'd0;
    if (is_mbc1 && mbc1_mode)
        selected_ram_bank = {2'b0, mbc1_ram_bank};
    else if (is_mbc3 && mbc3_ram_rtc_bank[7:4] == 0 &&
             mbc3_ram_rtc_bank[3:0] <= 3)
        selected_ram_bank = mbc3_ram_rtc_bank[3:0];
    else if (is_mbc5)
        selected_ram_bank = mbc5_ram_bank;
end

wire [12:0] ram_byte_offset =
    ram_size_code == 8'd1 ? {2'b0, addr[10:0]} : addr[12:0];
wire [3:0] ram_bank_limit =
    ram_size_code == 8'd4 ? 4'd15 :
    ram_size_code == 8'd5 ? 4'd7  :
    ram_size_code == 8'd3 ? 4'd3  : 4'd0;
wire ram_bank_valid = ram_size_code != 8'd0 &&
                      ram_size_code <= 8'd5 &&
                      selected_ram_bank <= ram_bank_limit;
wire mbc3_ram_selected = !is_mbc3 || mbc3_ram_rtc_bank <= 8'd3;
wire ram_access_enabled = has_cart_ram &&
                          (rom_only_ram_type ||
                           (ram_enabled && mbc3_ram_selected)) &&
                          ram_bank_valid;

always @* begin
    cart_addr = 22'd0;
    ff = 1'b1;
    if (!addr[15]) begin
        ff = !mapper_supported || (addr[14] && !switched_rom_bank_valid);
        if (!addr[14])
            cart_addr = {low_rom_bank & rom_bank_mask, addr[13:0]};
        else
            cart_addr = {switched_rom_bank[7:0] & rom_bank_mask, addr[13:0]};
    end else begin
        ff = !(mapper_supported && ram_access_enabled);
        cart_addr = CART_RAM_BASE + {5'b0, selected_ram_bank, ram_byte_offset};
    end
end

always @(posedge clk) begin
    if (reset) begin
        rom_bank_low <= 8'd1;
        rom_bank_high <= 1'b0;
        mbc1_rom_high <= 2'd0;
        mbc1_ram_bank <= 2'd0;
        mbc5_ram_bank <= 4'd0;
        mbc1_mode <= 1'b0;
        mbc3_ram_rtc_bank <= 8'd0;
        ram_enabled <= 1'b0;
    end else if (wr && !wr_addr[15]) begin
        if (is_mbc1) begin
            case (wr_addr[14:13])
                2'b00: ram_enabled <= wr_data[3:0] == 4'ha;
                2'b01: rom_bank_low <= {3'b0,
                                        wr_data[4:0] == 0 ? 5'd1 : wr_data[4:0]};
                2'b10: begin
                    mbc1_rom_high <= wr_data[1:0];
                    mbc1_ram_bank <= wr_data[1:0];
                end
                2'b11: mbc1_mode <= wr_data[0];
            endcase
        end else if (is_mbc3) begin
            case (wr_addr[14:13])
                2'b00: ram_enabled <= wr_data[3:0] == 4'ha;
                2'b01: rom_bank_low <= {1'b0, wr_data[6:0]};
                2'b10: mbc3_ram_rtc_bank <= wr_data;
                default: ;
            endcase
        end else if (is_mbc5) begin
            case (wr_addr[14:12])
                3'b000,
                3'b001: ram_enabled <= wr_data[3:0] == 4'ha;
                3'b010: rom_bank_low <= wr_data;
                3'b011: rom_bank_high <= wr_data[0];
                3'b100,
                3'b101: mbc5_ram_bank <= wr_data[3:0];
                default: ;
            endcase
        end
    end
end

endmodule
