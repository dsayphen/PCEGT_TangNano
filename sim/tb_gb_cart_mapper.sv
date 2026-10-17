`timescale 1ns/1ps

module tb_gb_cart_mapper;
    reg clk = 0;
    reg reset = 0;
    reg [7:0] mapper_type = 0;
    reg [7:0] ram_size_code = 0;
    reg [15:0] cpu_addr = 0;
    reg [7:0] cpu_dout = 0;
    reg cpu_rd = 0;
    reg cpu_wr = 0;
    wire [21:0] cart_addr;
    wire rom_select;
    wire ram_select;
    wire ram_write;
    wire mapper_supported;

    always #5 clk = ~clk;

    gb_cart_mapper dut (
        .clk(clk), .reset(reset), .mapper_type(mapper_type),
        .ram_size_code(ram_size_code), .cpu_addr(cpu_addr),
        .cpu_dout(cpu_dout), .cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
        .cart_addr(cart_addr), .rom_select(rom_select),
        .ram_select(ram_select), .ram_write(ram_write),
        .mapper_supported(mapper_supported)
    );

    task write_reg(input [15:0] address, input [7:0] value);
        begin
            @(negedge clk);
            cpu_addr = address;
            cpu_dout = value;
            cpu_wr = 1;
            @(negedge clk);
            cpu_wr = 0;
        end
    endtask

    task check(input condition, input [255:0] message);
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $fatal(1);
            end
        end
    endtask

    initial begin
        reset = 1;
        @(negedge clk);
        reset = 0;

        mapper_type = 8'h00;
        cpu_addr = 16'h4000;
        cpu_rd = 1;
        #1;
        check(mapper_supported && rom_select && cart_addr == 22'h004000,
              "ROM-only maps the second 16 KiB bank");

        mapper_type = 8'h03;
        ram_size_code = 8'h03;
        write_reg(16'h2000, 8'h03);
        cpu_addr = 16'h4000;
        #1;
        check(cart_addr == 22'h00c000, "MBC1 low ROM bank");
        write_reg(16'h4000, 8'h02);
        cpu_addr = 16'h4000;
        #1;
        check(cart_addr == 22'h10c000, "MBC1 upper ROM bank bits");
        write_reg(16'h6000, 8'h01);
        cpu_addr = 16'h0000;
        #1;
        check(cart_addr == 22'h100000, "MBC1 mode-one fixed bank");
        write_reg(16'h0000, 8'h0a);
        write_reg(16'h4000, 8'h01);
        cpu_addr = 16'ha000;
        cpu_wr = 0;
        cpu_rd = 1;
        #1;
        check(ram_select && cart_addr == 22'h3e2000,
              "MBC1 enabled banked RAM");
        cpu_wr = 1;
        #1;
        check(ram_write, "MBC1 RAM write enable");
        cpu_wr = 0;

        mapper_type = 8'h13;
        write_reg(16'h0000, 8'h0a);
        write_reg(16'h2000, 8'h05);
        cpu_addr = 16'h4000;
        #1;
        check(cart_addr == 22'h014000, "MBC3 ROM bank");
        write_reg(16'h4000, 8'h02);
        cpu_addr = 16'ha123;
        #1;
        check(ram_select && cart_addr == 22'h3e4123,
              "MBC3 RAM bank");
        write_reg(16'h4000, 8'h08);
        cpu_addr = 16'ha000;
        #1;
        check(!ram_select, "MBC3 RTC registers are not exposed as RAM");

        mapper_type = 8'h1b;
        write_reg(16'h0000, 8'h0a);
        write_reg(16'h2000, 8'h07);
        cpu_addr = 16'h4000;
        #1;
        check(cart_addr == 22'h01c000, "MBC5 low ROM bank");
        write_reg(16'h3000, 8'h01);
        cpu_addr = 16'h4000;
        #1;
        check(!rom_select, "MBC5 ROM banks above the 4 MiB cartridge window are rejected");
        write_reg(16'h3000, 8'h00);
        write_reg(16'h4000, 8'h03);
        cpu_addr = 16'ha000;
        #1;
        check(ram_select && cart_addr == 22'h3e6000,
              "MBC5 banked RAM");

        mapper_type = 8'h08;
        ram_size_code = 8'h02;
        cpu_addr = 16'ha000;
        #1;
        check(ram_select, "ROM+RAM cartridge exposes RAM without a bank-enable register");

        mapper_type = 8'h06;
        #1;
        check(!mapper_supported && !rom_select && !ram_select,
              "unsupported mapper is not aliased to a supported mapper");

        $display("PASS: GB cartridge mapper tests");
        $finish;
    end
endmodule
