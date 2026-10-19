`timescale 1ns/1ps

module megadrive_ram_case #(
    parameter AW = 6,
    parameter DW = 16
) (
    input wire clk,
    output reg done = 0
);
    reg [AW-1:0] a = 0, b = 0;
    reg [DW-1:0] da = 0, db = 0;
    reg wa = 0, wb = 0;
    wire [DW-1:0] qa, qb;
    wire [15:0] ref_a, ref_b;
    wire [13:0] ada = DW == 4 ? {a, 2'b00} :
                      DW == 8 ? {a, 3'b000} : {a, 4'b0011};
    wire [13:0] adb = DW == 4 ? {b, 2'b00} :
                      DW == 8 ? {b, 3'b000} : {b, 4'b0011};
    wire [15:0] dia = da, dib = db;
    integer i;
    integer seed = 32'h12345678 + AW * 32 + DW;

    dpram_block #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW)) dut (
        .clka(clk), .clkb(clk),
        .addr_a(a), .datain_a(da), .dataout_a(qa), .we_a(wa),
        .addr_b(b), .datain_b(db), .dataout_b(qb), .we_b(wb)
    );
    DPB #(.BIT_WIDTH_0(DW), .BIT_WIDTH_1(DW)) reference_ram (
        .CLKA(clk), .CLKB(clk),
        .RESETA(1'b0), .RESETB(1'b0),
        .CEA(1'b1), .CEB(1'b1), .OCEA(1'b1), .OCEB(1'b1),
        .BLKSELA(3'b0), .BLKSELB(3'b0),
        .ADA(ada), .ADB(adb), .DIA(dia), .DIB(dib),
        .DOA(ref_a), .DOB(ref_b), .WREA(wa), .WREB(wb)
    );

    task check;
        begin
            @(posedge clk);
            #1;
            if (qa !== ref_a[DW-1:0] || qb !== ref_b[DW-1:0])
                $fatal(1, "RAM AW=%0d DW=%0d mismatch A=%h/%h B=%h/%h",
                       AW, DW, qa, ref_a[DW-1:0], qb, ref_b[DW-1:0]);
        end
    endtask

    initial begin
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge clk);
            a = i;
            b = a ^ 1;
            check;
            if (qa !== 0 || qb !== 0)
                $fatal(1, "RAM AW=%0d DW=%0d must power up cleared", AW, DW);
        end
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge clk);
            a = i;
            da = i ^ 16'h5a3c;
            wa = 1;
        end
        @(negedge clk);
        wa = 0;
        a = 0;
        b = 1;
        check;
        // Avoid simultaneous same-address access, which is undefined in BSRAM.
        for (i = 0; i < 2000; i = i + 1) begin
            @(negedge clk);
            a = $random(seed);
            b = a ^ 1;
            da = $random(seed);
            db = $random(seed);
            wa = $random(seed);
            wb = $random(seed);
            check;
        end
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge clk);
            wa = 0;
            wb = 0;
            a = i;
            b = a ^ 1;
            check;
        end
        done = 1;
    end
endmodule

module tb_megadrive_probe;
    reg clk = 0;
    always #5 clk = ~clk;
    wire [5:0] done;
    GSR GSR (.GSRI(1'b1));
    megadrive_ram_case #(5, 16) ram5_16 (clk, done[0]);
    megadrive_ram_case #(6, 16) ram6_16 (clk, done[1]);
    megadrive_ram_case #(6, 8) ram6_8 (clk, done[2]);
    megadrive_ram_case #(6, 4) ram6_4 (clk, done[3]);
    megadrive_ram_case #(7, 16) ram7_16 (clk, done[4]);
    megadrive_ram_case #(9, 8) ram9_8 (clk, done[5]);

    initial begin
        wait (&done);
        $display("tb_megadrive_probe PASSED: six RAM configurations match Gowin DPB");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Mega Drive memory test timeout");
    end
endmodule
