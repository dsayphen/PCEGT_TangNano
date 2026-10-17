module gb_cart_mapper (
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  mapper_type,
    input  wire [7:0]  ram_size_code,
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  cpu_dout,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    output reg  [21:0] cart_addr,
    output reg         rom_select,
    output reg         ram_select,
    output wire        ram_write,
    output wire        mapper_supported
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

assign mapper_supported = is_rom_only || is_mbc1 || is_mbc3 || is_mbc5;
assign ram_write = ram_select && cpu_wr;

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
wire has_cart_ram = ram_size_code != 0 &&
                    (mbc_ram_type || rom_only_ram_type);

wire [8:0] selected_rom_bank =
    is_mbc1 ? {mbc1_rom_high, rom_bank_low[4:0]} :
    is_mbc3 ? {1'b0, rom_bank_low[6:0]} :
    is_mbc5 ? {rom_bank_high, rom_bank_low} :
              9'd1;
wire [8:0] switched_rom_bank =
    (selected_rom_bank == 0 && !is_mbc5) ? 9'd1 : selected_rom_bank;
wire [8:0] low_rom_bank =
    is_mbc1 && mbc1_mode ? {mbc1_rom_high, 5'b0} : 9'd0;
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
    ram_size_code == 8'd1 ? {2'b0, cpu_addr[10:0]} : cpu_addr[12:0];
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
    rom_select = 1'b0;
    ram_select = 1'b0;

    if (mapper_supported && cpu_addr <= 16'h7fff) begin
        rom_select = cpu_rd &&
                     (cpu_addr < 16'h4000 || switched_rom_bank_valid);
        if (cpu_addr < 16'h4000)
            cart_addr = {low_rom_bank[7:0], cpu_addr[13:0]};
        else
            cart_addr = {switched_rom_bank[7:0], cpu_addr[13:0]};
    end else if (mapper_supported &&
                 cpu_addr >= 16'ha000 && cpu_addr <= 16'hbfff &&
                 ram_access_enabled) begin
        ram_select = cpu_rd || cpu_wr;
        cart_addr = CART_RAM_BASE +
                    {selected_ram_bank, ram_byte_offset};
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
    end else if (cpu_wr &&
                 (cpu_addr < 16'h8000 ||
                  (is_rom_only && cpu_addr >= 16'ha000 &&
                   cpu_addr <= 16'hbfff))) begin
        if (is_rom_only) begin
            if (cpu_addr >= 16'ha000 && cpu_addr <= 16'hbfff)
                ram_enabled <= 1'b1;
        end else if (is_mbc1) begin
            case (cpu_addr[14:13])
                2'b00: ram_enabled <= cpu_dout[3:0] == 4'ha;
                2'b01: rom_bank_low <= {3'b0,
                                        cpu_dout[4:0] == 0 ? 5'd1 : cpu_dout[4:0]};
                2'b10: mbc1_rom_high <= cpu_dout[1:0];
                2'b11: mbc1_mode <= cpu_dout[0];
            endcase
            if (cpu_addr[14:13] == 2'b10)
                mbc1_ram_bank <= cpu_dout[1:0];
        end else if (is_mbc3) begin
            case (cpu_addr[14:13])
                2'b00: ram_enabled <= cpu_dout[3:0] == 4'ha;
                2'b01: rom_bank_low <= {1'b0, cpu_dout[6:0]};
                2'b10: mbc3_ram_rtc_bank <= cpu_dout;
                default: ;
            endcase
        end else if (is_mbc5) begin
            case (cpu_addr[14:12])
                3'b000: ram_enabled <= cpu_dout[3:0] == 4'ha;
                3'b010: rom_bank_low <= cpu_dout;
                3'b011: rom_bank_high <= cpu_dout[0];
                3'b100,
                3'b101: mbc5_ram_bank <= cpu_dout[3:0];
                default: ;
            endcase
        end
    end
end

endmodule
