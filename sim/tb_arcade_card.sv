`timescale 1ns/1ps

module tb_arcade_card;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg en = 1'b1;
    reg wr_n = 1'b1;
    reg rd_n = 1'b1;
    reg [20:0] addr = 21'd0;
    reg [7:0] din = 8'd0;
    wire [7:0] dout;
    wire sel_n;
    wire ram_cs_n;
    wire [20:0] ram_addr;

    ARCADE_CARD dut (
        .CLK(clk), .RST_N(resetn), .EN(en), .WR_N(wr_n), .RD_N(rd_n),
        .A(addr), .DI(din), .DO(dout), .SEL_N(sel_n),
        .RAM_CS_N(ram_cs_n), .RAM_A(ram_addr)
    );

    localparam [20:0] REG_BASE = 21'h1FFA00;
    localparam [20:0] RAM_BASE = 21'h080000;
    integer errors = 0;

    task write_reg;
        input [3:0] reg_addr;
        input [7:0] value;
        begin
            @(negedge clk);
            addr = REG_BASE | reg_addr;
            din = value;
            wr_n = 1'b0;
            @(posedge clk);
            @(negedge clk);
            wr_n = 1'b1;
        end
    endtask

    task read_reg;
        input [3:0] reg_addr;
        input [7:0] expected;
        begin
            @(negedge clk);
            addr = REG_BASE | reg_addr;
            rd_n = 1'b0;
            #1;
            if (dout !== expected) begin
                $display("FAIL register %h: got %h expected %h", reg_addr, dout, expected);
                errors = errors + 1;
            end
            @(negedge clk);
            rd_n = 1'b1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1'b1;

        // Port 0: base 0x123456, increment by one byte through offset.
        write_reg(4'd2, 8'h56);
        write_reg(4'd3, 8'h34);
        write_reg(4'd4, 8'h12);
        write_reg(4'd5, 8'h00);
        write_reg(4'd6, 8'h00);
        write_reg(4'd7, 8'h01);
        write_reg(4'd8, 8'h00);
        write_reg(4'd9, 8'h03);

        read_reg(4'd2, 8'h56);
        read_reg(4'd3, 8'h34);
        read_reg(4'd4, 8'h12);
        read_reg(4'd9, 8'h03);

        @(negedge clk);
        addr = RAM_BASE;
        rd_n = 1'b0;
        #1;
        if (ram_cs_n !== 1'b0 || ram_addr !== 21'h123456) begin
            $display("FAIL first RAM access: cs=%b addr=%h", ram_cs_n, ram_addr);
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        rd_n = 1'b1;
        addr = 21'd0;
        @(posedge clk);
        @(negedge clk);
        addr = RAM_BASE;
        @(posedge clk);
        @(negedge clk);
        if (ram_addr !== 21'h123457) begin
            $display("FAIL incremented RAM address: got %h cs=%b", ram_addr, ram_cs_n);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "Arcade Card unit test failed with %0d errors", errors);
        $display("*** tb_arcade_card PASSED ***");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "Arcade Card unit test timeout");
    end
endmodule