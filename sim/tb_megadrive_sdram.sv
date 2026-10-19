`timescale 1ns/1ps
module tb_megadrive_sdram;
    localparam FREQ = 53_693_175;
    reg clk = 0;
    always #9.31235 clk = ~clk;
    wire clk_sdram = ~clk;
    reg resetn = 0, core_enable = 0;
    reg [24:1] mem_addr = 0;
    reg [15:0] mem_wdata = 0;
    reg [1:0] mem_be = 0;
    reg mem_we = 0, mem_req = 0;
    wire [15:0] mem_rdata;
    wire mem_ack;
    reg [22:2] host_addr = 0;
    reg [31:0] host_wdata = 0;
    reg [3:0] host_be = 0;
    reg host_we = 0, host_req = 0;
    wire [31:0] host_rdata;
    wire host_ack, init_done, address_fault;
    wire [31:0] dq;
    wire [10:0] a;
    wire [1:0] ba;
    wire [3:0] dqm;
    wire ncs, nras, ncas, nwe, sdclk, cke;

    megadrive_sdram dut (
        .clk(clk), .clk_sdram(clk_sdram), .resetn(resetn), .core_enable(core_enable),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_we(mem_we), .mem_req(mem_req), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_be(host_be),
        .host_we(host_we), .host_req(host_req), .host_rdata(host_rdata), .host_ack(host_ack),
        .init_done(init_done), .address_fault(address_fault),
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_DQM(dqm),
        .SDRAM_nCS(ncs), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_nWE(nwe),
        .SDRAM_CLK(sdclk), .SDRAM_CKE(cke)
    );
    // One-cycle data window, rather than the model's forgiving default.
    sdram_model #(.READ_HOLD_CYCLES(1)) ram (
        .DQ(dq), .A(a), .BA(ba), .DQM(dqm), .nCS(ncs), .nRAS(nras),
        .nCAS(ncas), .nWE(nwe), .CLK(sdclk), .CKE(cke), .clk(clk)
    );

    integer cycle = 0, last_refresh = 0, refreshes = 0, accesses = 0;
    integer reset_cycle = 0, init_stage = 0, last_init_command = 0;
    integer last_activate [0:3];
    integer bank_ready [0:3];
    integer global_ready = 0, i;
    reg [3:0] open_bank = 0;
    reg mode_set = 0;
    wire [3:0] command = {ncs, nras, ncas, nwe};
    // Check the actual command pins, independent of the controller's internals.
    always @(posedge sdclk) begin
        cycle = cycle + 1;
        if (!resetn) begin
            reset_cycle = cycle;
            init_stage = 0;
            mode_set = 0;
            open_bank = 0;
            global_ready = cycle;
            for (integer b = 0; b < 4; b = b + 1) begin
                bank_ready[b] = cycle;
                last_activate[b] = 0;
            end
        end else if (command != 4'b0111) begin
            if (cycle < global_ready)
                $fatal(1, "SDRAM global recovery violated");
            case (command)
                4'b0010: begin
                    if (!a[10] || init_stage != 0 || cycle - reset_cycle < FREQ / 5000)
                        $fatal(1, "SDRAM initialization/precharge delay violated");
                    init_stage = 1;
                    last_init_command = cycle;
                end
                4'b0001: begin
                    if (open_bank != 0) $fatal(1, "Refresh with an open bank");
                    for (integer b = 0; b < 4; b = b + 1)
                        if (cycle < bank_ready[b]) $fatal(1, "Refresh before auto-precharge");
                    if (!mode_set) begin
                        if (init_stage < 1 || init_stage > 2 ||
                            cycle - last_init_command < (init_stage == 1 ? 1 : 4))
                            $fatal(1, "Incorrect initialization refresh");
                        init_stage = init_stage + 1;
                        last_init_command = cycle;
                    end else refreshes = refreshes + 1;
                    global_ready = cycle + 4;
                    last_refresh = cycle;
                end
                4'b0000: begin
                    if (init_stage != 3 || a != 11'h020)
                        $fatal(1, "Mode must select CAS2 and burst length 1");
                    mode_set = 1;
                    global_ready = cycle + 2;
                    last_refresh = cycle;
                end
                4'b0011: begin
                    if (!mode_set || open_bank[ba] || cycle < bank_ready[ba])
                        $fatal(1, "Illegal bank activation");
                    open_bank[ba] = 1;
                    last_activate[ba] = cycle;
                end
                4'b0100, 4'b0101: begin
                    if (!mode_set || !open_bank[ba] || !a[10] ||
                        cycle - last_activate[ba] < 1 || a[9:8] != 0)
                        $fatal(1, "Illegal column access");
                    if (command == 4'b0100)
                        for (integer b = 0; b < 4; b = b + 1)
                            if (!dqm[b] && (^dq[b*8 +: 8] === 1'bx))
                                $fatal(1, "Write data invalid or bus contention");
                    bank_ready[ba] = cycle + 3;
                    open_bank[ba] = 0;
                    accesses = accesses + 1;
                end
                default: $fatal(1, "Unexpected SDRAM command %b", command);
            endcase
        end
        if (resetn && mode_set && cycle - last_refresh > FREQ / 128000)
            $fatal(1, "Refresh interval exceeded 7.8125 us");
    end

    integer start_cycle, max_latency = 0;
    task core_access(input [24:0] byte_addr, input wr, input [15:0] data,
                     input [1:0] mask, input [15:0] expected);
        begin
            @(negedge clk);
            #1;
            mem_addr = byte_addr[24:1];
            mem_we = wr;
            mem_wdata = data;
            mem_be = mask;
            mem_req = ~mem_req;
            start_cycle = cycle;
            wait (mem_ack == mem_req);
            #1;
            if (!wr && mem_rdata !== expected)
                $fatal(1, "Core addr=%h got=%h expected=%h", byte_addr, mem_rdata, expected);
            if (cycle - start_cycle > max_latency) max_latency = cycle - start_cycle;
            if (cycle - start_cycle > 32) $fatal(1, "Core request starved");
        end
    endtask
    task host_access(input [22:0] byte_addr, input wr, input [31:0] data,
                     input [3:0] mask, input [31:0] expected);
        integer started;
        begin
            @(negedge clk);
            #1;
            host_addr = byte_addr[22:2];
            host_we = wr;
            host_wdata = data;
            host_be = mask;
            host_req = ~host_req;
            started = cycle;
            wait (host_ack == host_req);
            #1;
            if (!wr && host_rdata !== expected)
                $fatal(1, "Host addr=%h got=%h expected=%h", byte_addr, host_rdata, expected);
            if (init_done && cycle - started > 32) $fatal(1, "Host request starved");
        end
    endtask

    reg [31:0] expected_word;
    reg [15:0] expected_half;
    integer seed = 32'h68000, mask, n, before_accesses, before_refreshes;
    reg [24:0] test_addr;
    reg [15:0] random_data;
    reg [24:0] written_addr [0:199];
    reg [15:0] written_data [0:199];
    initial begin
        repeat (4) @(negedge clk);
        #1 resetn = 1;
        // Queue a host request during power-up; it must not be acknowledged early.
        host_addr = 0;
        host_wdata = 32'h78563412;
        host_be = 15;
        host_we = 1;
        host_req = 1;
        repeat (100) @(negedge clk);
        if (init_done || host_ack) $fatal(1, "Host acknowledged before initialization");
        wait (init_done);
        if (!mode_set) $fatal(1, "Ready before mode initialization");
        wait (host_ack == host_req);
        // Raw ROM file bytes 12 34 56 78 are packed in increasing host lanes.
        host_access(0, 1, 32'h78563412, 15, 0);
        core_enable = 1;
        core_access(0, 0, 0, 3, 16'h1234);
        core_access(2, 0, 0, 3, 16'h5678);
        for (mask = 0; mask < 4; mask = mask + 1) begin
            host_access(0, 1, 32'h78563412, 15, 0);
            core_access(0, 1, 16'habcd, mask, 0);
            expected_half = {mask[1] ? 8'hab : 8'h12, mask[0] ? 8'hcd : 8'h34};
            core_access(0, 0, 0, 3, expected_half);
            host_access(0, 0, 0, 0, {16'h7856, expected_half[7:0], expected_half[15:8]});
            core_access(2, 1, 16'h9aef, mask, 0);
            expected_half = {mask[1] ? 8'h9a : 8'h56, mask[0] ? 8'hef : 8'h78};
            core_access(2, 0, 0, 3, expected_half);
        end
        for (mask = 0; mask < 16; mask = mask + 1) begin
            host_access(4, 1, 32'h12345678, 15, 0);
            host_access(4, 1, 32'hdeadbeef, mask, 0);
            expected_word = 32'h12345678;
            for (n = 0; n < 4; n = n + 1)
                if (mask[n]) expected_word[n*8 +: 8] = (32'hdeadbeef >> (n*8));
            host_access(4, 0, 0, 0, expected_word);
            core_access(4, 0, 0, 3, {expected_word[7:0], expected_word[15:8]});
            core_access(6, 0, 0, 3, {expected_word[23:16], expected_word[31:24]});
        end
        // Distinct rows, columns, both halfwords and all physical banks.
        for (n = 0; n < 200; n = n + 1) begin
            test_addr = (n % 3) * 25'h200000 + ((n * 1093) & 25'h1ffffe);
            random_data = $random(seed);
            written_addr[n] = test_addr;
            written_data[n] = random_data;
            core_access(test_addr, 1, random_data, 3, 0);
            core_access(test_addr, 0, 0, 3, random_data);
        end
        for (n = 0; n < 200; n = n + 1)
            core_access(written_addr[n], 0, 0, 3, written_data[n]);
        core_access(25'h01ffffe, 1, 16'h1111, 3, 0);
        core_access(25'h0200000, 1, 16'h2222, 3, 0);
        core_access(25'h03ffffe, 1, 16'h3333, 3, 0);
        core_access(25'h0400000, 1, 16'h4444, 3, 0);
        core_access(25'h05ffffe, 1, 16'h5555, 3, 0);
        core_access(25'h0800000, 1, 16'h6666, 3, 0);
        core_access(25'h080fffe, 1, 16'h7777, 3, 0);
        core_access(25'h0820000, 1, 16'h8888, 3, 0);
        core_access(25'h083fffe, 1, 16'h9999, 3, 0);
        core_access(25'h01ffffe, 0, 0, 3, 16'h1111);
        core_access(25'h0200000, 0, 0, 3, 16'h2222);
        core_access(25'h03ffffe, 0, 0, 3, 16'h3333);
        core_access(25'h0400000, 0, 0, 3, 16'h4444);
        core_access(25'h05ffffe, 0, 0, 3, 16'h5555);
        host_access(23'h600000, 0, 0, 0, 32'h00006666);
        host_access(23'h60fffc, 0, 0, 0, 32'h77770000);
        host_access(23'h620000, 0, 0, 0, 32'h00008888);
        host_access(23'h63fffc, 0, 0, 0, 32'h99990000);
        // Unsupported ROM banks are reported, acknowledged and cannot modify RAM.
        before_accesses = accesses;
        core_access(25'h0600000, 1, 16'hbad0, 3, 0);
        core_access(25'h0810000, 0, 0, 3, 16'hffff);
        core_access(25'h1000000, 0, 0, 3, 16'hffff);
        if (!address_fault || accesses != before_accesses)
            $fatal(1, "Invalid address must fault without a physical access");
        core_access(25'h0800000, 0, 0, 3, 16'h6666);
        // A pending console request must wait while loading; host still progresses.
        core_enable = 0;
        @(negedge clk);
        #1;
        mem_addr = 24'h400000;
        mem_we = 0;
        mem_req = ~mem_req;
        host_access(23'h640000, 1, 32'hcafebabe, 15, 0);
        if (mem_ack == mem_req) $fatal(1, "Disabled console accepted a new request");
        core_enable = 1;
        wait (mem_ack == mem_req);
        #1;
        if (mem_rdata !== 16'h6666) $fatal(1, "Pending console request lost");
        // Simultaneous continuous requesters, with autonomous refresh taking priority.
        before_refreshes = refreshes;
        fork
            begin
                for (integer c = 0; c < 300; c = c + 1)
                    core_access(25'h0800000, 0, 0, 3, 16'h6666);
            end
            begin
                for (integer h = 0; h < 300; h = h + 1)
                    host_access(23'h640000, 0, 0, 0, 32'hcafebabe);
            end
        join
        if (refreshes <= before_refreshes) $fatal(1, "No refresh during contention");
        before_refreshes = refreshes;
        repeat (1500) @(negedge clk);
        if (refreshes < before_refreshes + 3) $fatal(1, "No refresh during idle");
        // Restart the controller after an outstanding read, without clearing SDRAM.
        @(negedge clk);
        #1;
        mem_addr = 0;
        mem_req = ~mem_req;
        repeat (5) @(negedge clk);
        #1 resetn = 0;
        core_enable = 0;
        mem_req = 0;
        host_req = 0;
        repeat (4) @(negedge clk);
        #1 resetn = 1;
        wait (init_done);
        if (address_fault) $fatal(1, "Fault did not clear on controller reset");
        core_enable = 1;
        core_access(25'h0800000, 0, 0, 3, 16'h6666);
        host_access(23'h640000, 0, 0, 0, 32'hcafebabe);
        $display("tb_megadrive_sdram PASSED: endian, masks, mapping, arbitration, refresh, reset; max core latency=%0d clocks",
                 max_latency);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Mega Drive SDRAM test timeout");
    end
endmodule
