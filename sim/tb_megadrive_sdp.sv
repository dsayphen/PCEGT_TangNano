`timescale 1ns/1ps

module megadrive_sdp_case #(
    parameter AW = 9,
    parameter DW = 8,
    parameter WRITE_PORT_B = 0,
    parameter ASYNC_CLOCKS = 0
) (
    output reg done = 0
);
    reg wr_clk = 0, rd_clk = 0;
    always #5 wr_clk = ~wr_clk;
    generate if (ASYNC_CLOCKS) begin : g_async
        initial begin
            #2;
            forever #7 rd_clk = ~rd_clk;
        end
    end else begin : g_sync
        always @* rd_clk = wr_clk;
    end endgenerate

    reg [AW-1:0] wa = 0, ra = 1;
    reg [DW-1:0] wd = 0;
    reg we = 0;
    reg [DW/8-1:0] be = 0;
    wire [DW-1:0] q, reference_q;
    reg [DW-1:0] expected [0:(1 << AW)-1];
    reg [DW-1:0] sampled;
    integer i, lane;
    integer seed = 32'h530000 + AW * 64 + DW + WRITE_PORT_B + ASYNC_CLOCKS;

    md_sdp_ram #(AW, DW) dut (
        .wr_clk(wr_clk), .wr_addr(wa), .wr_data(wd), .wr_en(we), .wr_be(be),
        .rd_clk(rd_clk), .rd_addr(ra), .rd_data(q)
    );
    generate if (DW == 32) begin : g_cache_reference
        dpram32_block original (
            .clka(rd_clk), .addr_a({3'b0, ra}), .datain_a(32'b0),
            .dataout_a(reference_q), .we_a(1'b0), .be_a(4'b1111),
            .clkb(wr_clk), .addr_b({3'b0, wa}), .datain_b(wd),
            .dataout_b(), .we_b(we), .be_b(be)
        );
    end else if (WRITE_PORT_B) begin : g_sprite_reference
        dpram_block #(AW, DW) original (
            .clka(rd_clk), .addr_a(ra), .datain_a(8'b0),
            .dataout_a(reference_q), .we_a(1'b0),
            .clkb(wr_clk), .addr_b(wa), .datain_b(wd),
            .dataout_b(), .we_b(we && be[0])
        );
    end else begin : g_background_reference
        dpram_block #(AW, DW) original (
            .clka(wr_clk), .addr_a(wa), .datain_a(wd),
            .dataout_a(), .we_a(we && be[0]),
            .clkb(rd_clk), .addr_b(ra), .datain_b(8'b0),
            .dataout_b(reference_q), .we_b(1'b0)
        );
    end endgenerate

    initial begin
        for (i = 0; i < (1 << AW); i = i + 1)
            expected[i] = 0;
        #1;
        if (q !== 0 || reference_q !== 0)
            $fatal(1, "SDP must power up cleared");
    end

    always @(posedge wr_clk)
        if (we)
            for (integer b = 0; b < DW/8; b = b + 1)
                if (be[b])
                    expected[wa][b*8 +: 8] <= wd[b*8 +: 8];

    always @(posedge rd_clk) begin
        sampled = expected[ra];
        #1;
        // Same-address read/write collision behavior is not guaranteed by DPB.
        if (we && wa == ra)
            $fatal(1, "Test must not collide");
        if (q !== reference_q || q !== sampled)
            $fatal(1, "SDP AW=%0d DW=%0d portB=%0d async=%0d addr=%h got=%h ref=%h expected=%h",
                   AW, DW, WRITE_PORT_B, ASYNC_CLOCKS, ra, q, reference_q, sampled);
    end

    initial begin
        // Every address is checked before any writes.
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge rd_clk);
            ra = i;
        end
        @(negedge rd_clk);
        ra = 0;
        // Exercise every byte-enable mask, including writes with no enabled lane.
        for (i = 0; i < (1 << (DW/8)); i = i + 1) begin
            @(negedge wr_clk);
            wa = 1;
            we = 1;
            be = i;
            wd = ~32'h12345678 ^ (i * 32'h01010101);
            @(negedge wr_clk);
            we = 0;
            @(negedge rd_clk);
            ra = 1;
            @(negedge rd_clk);
            ra = 0;
        end
        // Write every address, preserving simultaneous reads at another address.
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge wr_clk);
            we = 0;
            @(negedge rd_clk);
            ra = i ^ 1;
            @(negedge wr_clk);
            wa = i;
            wd = 32'h5a3cc3a5 ^ (i * 32'h01020304);
            be = {DW/8{1'b1}};
            we = 1;
        end
        for (i = 0; i < 3000; i = i + 1) begin
            @(negedge wr_clk);
            we = 0;
            wa = $random(seed);
            @(negedge rd_clk);
            ra = wa ^ 1;
            @(negedge wr_clk);
            wd = $random(seed);
            be = $random(seed);
            we = $random(seed);
        end
        @(negedge wr_clk);
        we = 0;
        for (i = 0; i < (1 << AW); i = i + 1) begin
            @(negedge rd_clk);
            ra = i;
        end
        @(negedge rd_clk);
        done = 1;
    end
endmodule

module megadrive_fm_memory_case(output reg done = 0);
    reg clk = 0;
    always #5 clk = ~clk;
    reg ce = 0;
    reg rst = 0;
    reg [7:0] addr = 0;
    reg [21:0] data = 0;
    wire [11:0] sine_q;
    wire [9:0] exp_q;
    wire [21:0] shift_q, reset_shift_q;
    reg [11:0] expected_sine;
    reg [9:0] expected_exp;
    reg [21:0] history [0:23];
    integer n, k, enabled = 0;
    integer seed = 32'h2612;

    jt12_logsin sine (.clk(clk), .clk_en(ce), .addr(addr), .logsin(sine_q));
    jt12_exprom exp_rom (.clk(clk), .clk_en(ce), .addr(addr), .exp(exp_q));
    jt12_sh #(22, 24) shift_reg (.clk(clk), .clk_en(ce), .din(data), .drop(shift_q));
    jt12_sh_rst #(22, 24) reset_shift_reg (
        .clk(clk), .clk_en(ce), .rst(rst), .din(data), .drop(reset_shift_q)
    );
    initial begin
        for (k = 0; k < 24; k = k + 1) history[k] = 0;
        for (n = 0; n < 1800; n = n + 1) begin
            @(negedge clk);
            // Sweep both tables completely before introducing clock-enable stalls.
            addr = n;
            ce = n < 256 ? 1 : ($random(seed) & 1);
            data = $random(seed);
            rst = $random(seed);
            if (ce) begin
                expected_sine = sine.sinelut[addr];
                expected_exp = exp_rom.explut_jt51[addr];
                for (k = 23; k > 0; k = k - 1) history[k] = history[k-1];
                history[0] = data;
                enabled = enabled + 1;
            end
            @(posedge clk);
            #1;
            if (sine_q !== expected_sine || exp_q !== expected_exp)
                $fatal(1, "FM lookup latency/clock-enable mismatch");
            if (reset_shift_q !== history[23])
                $fatal(1, "FM initialized shift register mismatch");
            if (enabled >= 24 && shift_q !== history[23])
                $fatal(1, "FM shift register mismatch");
        end
        done = 1;
    end
endmodule

module tb_megadrive_sdp;
    GSR GSR (.GSRI(1'b1));
    wire [6:0] done;
    megadrive_sdp_case #(9, 8, 0, 0) background (done[0]);
    megadrive_sdp_case #(9, 8, 1, 0) sprite (done[1]);
    megadrive_sdp_case #(7, 32, 1, 0) cache (done[2]);
    megadrive_sdp_case #(9, 8, 0, 1) async_background (done[3]);
    megadrive_sdp_case #(9, 8, 1, 1) async_sprite (done[4]);
    megadrive_sdp_case #(7, 32, 1, 1) async_cache (done[5]);
    megadrive_fm_memory_case fm (done[6]);
    initial begin
        wait (&done);
        $display("tb_megadrive_sdp PASSED: video tables/cache match DPB; FM lookup/shift behavior preserved");
        $finish;
    end
    initial begin
        #500000;
        $fatal(1, "Mega Drive distributed memory test timeout");
    end
endmodule
