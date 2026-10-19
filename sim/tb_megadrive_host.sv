`timescale 1ns/1ps
module tb_megadrive_host;
    reg clk = 0;
    always #9.31235 clk = ~clk;
    reg resetn = 0, loading = 0, ld_wr = 0, rv_valid = 0;
    reg [22:0] ld_addr = 0, rv_addr = 0;
    reg [7:0] ld_data = 0;
    reg [31:0] rv_wdata = 0;
    reg [3:0] rv_wstrb = 0;
    wire ld_busy, ld_idle, rv_ready, ram_initializing, protocol_fault;
    wire [31:0] rv_rdata, host_wdata, host_rdata;
    wire [22:2] host_addr;
    wire [3:0] host_be;
    wire host_we, host_req, host_ack, init_done, address_fault;
    reg core_enable = 0, mem_req = 0;
    reg [24:1] mem_addr = 0;
    wire mem_ack;
    wire [15:0] mem_rdata;
    wire [31:0] dq;
    wire [10:0] a;
    wire [1:0] ba;
    wire [3:0] dqm;
    wire ncs, nras, ncas, nwe, sdclk, cke;
    integer physical_writes = 0;
    always @(posedge sdclk)
        if (resetn && {ncs, nras, ncas, nwe} == 4'b0100)
            physical_writes = physical_writes + 1;

    megadrive_host_bridge bridge (
        .clk(clk), .resetn(resetn), .loading(loading),
        .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data),
        .ld_busy(ld_busy), .ld_idle(ld_idle),
        .rv_valid(rv_valid), .rv_addr(rv_addr), .rv_wdata(rv_wdata), .rv_wstrb(rv_wstrb),
        .rv_ready(rv_ready), .rv_rdata(rv_rdata), .host_addr(host_addr),
        .host_wdata(host_wdata), .host_be(host_be), .host_we(host_we), .host_req(host_req),
        .host_ack(host_ack), .host_rdata(host_rdata),
        .ram_initializing(ram_initializing), .protocol_fault(protocol_fault)
    );
    megadrive_sdram #(.WORK_RAM_BASE(23'h7a0000), .CART_RAM_BASE(23'h7c0000)) memory (
        .clk(clk), .clk_sdram(~clk), .resetn(resetn), .core_enable(core_enable),
        .mem_addr(mem_addr), .mem_wdata(16'b0), .mem_be(2'b11),
        .mem_we(1'b0), .mem_req(mem_req), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_be(host_be),
        .host_we(host_we), .host_req(host_req), .host_rdata(host_rdata), .host_ack(host_ack),
        .init_done(init_done), .address_fault(address_fault),
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_DQM(dqm),
        .SDRAM_nCS(ncs), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_nWE(nwe),
        .SDRAM_CLK(sdclk), .SDRAM_CKE(cke)
    );
    sdram_model #(.READ_HOLD_CYCLES(1)) ram (
        .DQ(dq), .A(a), .BA(ba), .DQM(dqm), .nCS(ncs), .nRAS(nras),
        .nCAS(ncas), .nWE(nwe), .CLK(sdclk), .CKE(cke), .clk(clk)
    );

    task rv_access(input [22:0] addr, input [31:0] data, input [3:0] mask,
                   input [31:0] expected);
        integer writes_after;
        time requested;
        begin
            @(negedge clk);
            #1;
            rv_addr = addr;
            rv_wdata = data;
            rv_wstrb = mask;
            rv_valid = 1;
            requested = $time;
            wait (rv_ready);
            #1;
            if ($time - requested > 2000)
                $fatal(1, "Firmware access starved during initialization/loading");
            if (mask == 0 && rv_rdata !== expected)
                $fatal(1, "RV read %h got %h expected %h", addr, rv_rdata, expected);
            writes_after = physical_writes;
            repeat (30) @(negedge clk);
            if (!loading && physical_writes != writes_after)
                $fatal(1, "RV valid held high caused duplicate writes");
            #1 rv_valid = 0;
            repeat (2) @(negedge clk);
        end
    endtask
    task load_byte(input [22:0] addr, input [7:0] data);
        begin
            wait (!ld_busy);
            @(negedge clk);
            #1;
            ld_addr = addr;
            ld_data = data;
            ld_wr = 1;
            @(negedge clk);
            #1 ld_wr = 0;
        end
    endtask
    task core_read(input [24:0] addr, input [15:0] expected);
        begin
            @(negedge clk);
            #1;
            mem_addr = addr[24:1];
            mem_req = ~mem_req;
            wait (mem_ack == mem_req);
            #1;
            if (mem_rdata !== expected)
                $fatal(1, "Core read %h got %h expected %h", addr, mem_rdata, expected);
        end
    endtask
    task check_clear;
        begin
            for (integer w = 0; w < 16384; w = w + 1)
                if (ram.mem[(23'h7a0000 >> 2) + w] !== 0)
                    $fatal(1, "Work RAM was not cleared at word %0d", w);
            for (integer w = 0; w < 32768; w = w + 1)
                if (ram.mem[(23'h7c0000 >> 2) + w] !== 32'hffffffff)
                    $fatal(1, "Cartridge RAM was not initialized at word %0d", w);
            if (ram.mem[23'h600000 >> 2] !== 32'h11223344 ||
                ram.mem[23'h79fffc >> 2] !== 32'h55667788 ||
                ram.mem[23'h7b0000 >> 2] !== 32'habcdef01)
                $fatal(1, "RAM initialization overwrote firmware/reserved memory");
        end
    endtask

    integer mask, lane;
    reg [31:0] expected;
    initial begin
        repeat (4) @(negedge clk);
        #1 resetn = 1;
        wait (init_done);
        rv_access(23'h600000, 32'h11223344, 15, 0);
        rv_access(23'h79fffc, 32'h55667788, 15, 0);
        rv_access(23'h7b0000, 32'habcdef01, 15, 0);
        for (mask = 0; mask < 16; mask = mask + 1) begin
            rv_access(23'h600004, 32'h12345678, 15, 0);
            rv_access(23'h600004, 32'hdeadbeef, mask, 32'h12345678);
            expected = 32'h12345678;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask[lane]) expected[lane*8 +: 8] = 32'hdeadbeef >> (lane*8);
            rv_access(23'h600004, 0, 0, expected);
        end
        // An early loader pulse can coincide with the loading edge.
        @(negedge clk);
        #1;
        loading = 1;
        ld_wr = 1;
        ld_addr = 0;
        ld_data = 8'h12;
        @(negedge clk);
        #1 ld_wr = 0;
        if (!ld_busy || ld_idle) $fatal(1, "Clear/queued load did not apply backpressure");
        // Firmware must continue to run while work/cartridge RAM are initialized.
        repeat (50) rv_access(23'h600000, 0, 0, 32'h11223344);
        wait (!ram_initializing && ld_idle);
        check_clear;
        load_byte(1, 8'h34);
        load_byte(2, 8'h56);
        load_byte(3, 8'h78);
        load_byte(23'h5ffffe, 8'hab);
        load_byte(23'h5fffff, 8'hcd);
        wait (ld_idle);
        @(negedge clk);
        #1 loading = 0;
        core_enable = 1;
        core_read(0, 16'h1234);
        core_read(2, 16'h5678);
        core_read(25'h5ffffe, 16'habcd);
        core_read(25'h800000, 16'h0000);
        core_read(25'h820000, 16'hffff);
        rv_access(23'h600000, 0, 0, 32'h11223344);

        // Reload after dirtying both RAMs, leaving the controller/host running.
        rv_access(23'h7a0000, 32'hbad0bad0, 15, 0);
        rv_access(23'h7dfffc, 0, 15, 0);
        core_enable = 0;
        @(negedge clk);
        #1 loading = 1;
        wait (ram_initializing);
        wait (!ram_initializing && ld_idle);
        check_clear;
        load_byte(0, 8'h9a);
        load_byte(1, 8'hbc);
        wait (ld_idle);
        @(negedge clk);
        #1 loading = 0;
        core_enable = 1;
        core_read(0, 16'h9abc);
        if (protocol_fault || address_fault) $fatal(1, "Unexpected valid-transaction fault");

        load_byte(23'h600000, 8'h00);
        repeat (3) @(negedge clk);
        if (!protocol_fault) $fatal(1, "Out-of-range ROM write did not report a fault");
        rv_access(23'h600000, 0, 0, 32'h11223344);
        @(negedge clk);
        #1 resetn = 0;
        repeat (4) @(negedge clk);
        #1 resetn = 1;
        wait (init_done);
        if (protocol_fault) $fatal(1, "Controller reset did not clear protocol fault");
        // Deliberately violate loader backpressure; it must not fail silently.
        load_byte(0, 8'h01);
        @(negedge clk);
        #1;
        ld_addr = 1;
        ld_data = 8'h02;
        ld_wr = 1;
        @(negedge clk);
        #1 ld_wr = 0;
        if (!protocol_fault) $fatal(1, "Loader pending-byte overflow was not reported");
        $display("tb_megadrive_host PASSED: firmware/loader handshakes, masks, all RAM clear words, reload, no alias, explicit fault");
        $finish;
    end
    initial begin
        #30000000;
        $fatal(1, "Mega Drive host test timeout");
    end
endmodule
