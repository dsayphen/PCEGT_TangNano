`timescale 1ns/1ps
module tb_flash_pio;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg ctrl_write = 0, data_write = 0;
reg [31:0] wdata = 0;
wire [31:0] status;
wire [7:0] rdata;
wire owned, cs_n, sck, mosi;
reg loopback = 1;
wire flash_miso;
wire miso = loopback ? mosi : flash_miso;
flash_nor_test_model flash (.cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(flash_miso));
flash_pio dut (
    .clk(clk), .resetn(resetn), .ctrl_write(ctrl_write),
    .data_write(data_write), .wdata(wdata), .status(status),
    .rdata(rdata), .owned(owned), .cs_n(cs_n),
    .sck(sck), .mosi(mosi), .miso(miso)
);
task control;
    input [31:0] value;
    begin
        @(negedge clk); ctrl_write = 1; wdata = value;
        @(negedge clk); ctrl_write = 0;
    end
endtask
task exchange;
    input [7:0] value;
    begin
        @(negedge clk); data_write = 1; wdata = value;
        @(negedge clk); data_write = 0;
        if (!status[0]) $fatal(1, "No busy indication");
        wait (!status[0]);
    end
endtask
task transfer;
    input [7:0] value;
    begin
        exchange(value);
        if (rdata !== value) $fatal(1, "Loopback mismatch %h != %h", rdata, value);
    end
endtask
task address_command;
    input [7:0] command;
    input [23:0] address;
    begin
        control(2);
        exchange(command);
        exchange(address[23:16]);
        exchange(address[15:8]);
        exchange(address[7:0]);
    end
endtask
integer index;
reg [7:0] copy_buffer [0:255];
initial begin
    #2000000; $fatal(1, "Timeout");
end
initial begin
    repeat (3) @(negedge clk);
    resetn = 1;
    if (owned || !cs_n) $fatal(1, "Unsafe reset state");
    control(3);
    if (!owned || status[31:16] != 16'h4653) $fatal(1, "Ownership/version");
    control(2);
    transfer(8'ha5);
    transfer(8'h03);
    transfer(8'h00);
    transfer(8'hff);
    control(1);
    if (owned || !cs_n) $fatal(1, "Ownership/CS release");
    loopback = 0;
    control(3);
    address_command(8'h03, 24'h100000);
    for (index = 0; index < 256; index = index + 1) begin
        exchange(0);
        copy_buffer[index] = rdata;
        if (rdata !== (index ^ 8'ha5)) $fatal(1, "Source read mismatch");
    end
    control(3);
    address_command(8'h20, 0);
    control(3);
    if (flash.destination[0] !== 0) $fatal(1, "Erase without WREN accepted");
    control(2); exchange(8'h06); control(3);
    control(2); exchange(8'h05); exchange(0);
    if (rdata !== 2) $fatal(1, "WEL missing");
    control(3);
    address_command(8'h20, 0); control(3);
    for (index = 0; index < 4096; index = index + 1)
        if (flash.destination[index] !== 255) $fatal(1, "Sector erase failed");
    control(2); exchange(8'h06); control(3);
    address_command(8'h02, 0);
    for (index = 0; index < 256; index = index + 1)
        exchange(copy_buffer[index]);
    control(3);
    control(2); exchange(8'h05); exchange(0);
    if (rdata !== 0) $fatal(1, "WEL not cleared after programming");
    control(3);
    address_command(8'h03, 0);
    for (index = 0; index < 256; index = index + 1) begin
        exchange(0);
        if (rdata !== copy_buffer[index]) $fatal(1, "Program/readback mismatch");
    end
    control(3);
    address_command(8'h03, 24'h100000);
    for (index = 0; index < 256; index = index + 1) begin
        exchange(0);
        if (rdata !== copy_buffer[index]) $fatal(1, "Source changed");
    end
    control(1);
    $display("tb_flash_pio PASSED");
    $finish;
end
endmodule

module flash_nor_test_model (
    input wire cs_n, sck, mosi,
    output reg miso = 0
);
reg [7:0] destination [0:4095];
reg [7:0] source [0:255];
reg [7:0] command;
reg [7:0] shift_in;
reg [7:0] shift_out;
reg [23:0] address;
reg write_enable = 0;
integer bit_count, byte_count, index;
initial begin
    for (index = 0; index < 4096; index = index + 1) destination[index] = 0;
    for (index = 0; index < 256; index = index + 1) source[index] = index ^ 8'ha5;
end
always @(negedge cs_n) begin
    command = 0;
    address = 0;
    shift_in = 0;
    shift_out = 0;
    bit_count = 0;
    byte_count = 0;
end
always @(posedge sck) if (!cs_n) begin
    shift_in = {shift_in[6:0], mosi};
    bit_count = bit_count + 1;
    if (bit_count == 8) begin
        bit_count = 0;
        if (byte_count == 0) begin
            command = shift_in;
        end else if ((command == 8'h03 || command == 8'h02 || command == 8'h20) && byte_count <= 3) begin
            address = {address[15:0], shift_in};
        end else if (command == 8'h02 && write_enable) begin
            if (address >= 4096) $fatal(1, "Write outside destination");
            destination[address] = destination[address] & shift_in;
            address[7:0] = address[7:0] + 1;
        end else if (command == 8'h03 && byte_count > 3) begin
            address = address + 1;
        end
        byte_count = byte_count + 1;
        if (command == 8'h05) shift_out = {6'd0, write_enable, 1'b0};
        else if (command == 8'h03 && byte_count >= 4) begin
            if (address < 4096) shift_out = destination[address];
            else if (address >= 24'h100000 && address < 24'h100100)
                shift_out = source[address - 24'h100000];
            else shift_out = 255;
        end else shift_out = 0;
    end else shift_out = {shift_out[6:0], 1'b0};
end
always @(negedge sck) if (!cs_n) miso = shift_out[7];
always @(posedge cs_n) begin
    if (command == 8'h06) write_enable = 1;
    if (command == 8'h04) write_enable = 0;
    if (command == 8'h20 && byte_count == 4 && write_enable) begin
        if (address != 0) $fatal(1, "Erase outside destination");
        for (index = 0; index < 4096; index = index + 1) destination[index] = 255;
        write_enable = 0;
    end
    if (command == 8'h02) write_enable = 0;
end
endmodule