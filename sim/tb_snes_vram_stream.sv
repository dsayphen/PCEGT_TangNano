`timescale 1ns/1ps
module tb_snes_vram_stream #(
    parameter UPSTREAM_RAM_LAYOUT = 0,
    parameter VIDEO_RAM_LAYOUT = 0,
    parameter WRAM_WAIT = 0
);
localparam [22:0] WRAM_BASE = UPSTREAM_RAM_LAYOUT ? 23'h3e0000 :
                                 VIDEO_RAM_LAYOUT ? 23'h620000 : 23'h5c0000;
localparam [22:0] SAVE_BASE = UPSTREAM_RAM_LAYOUT ? 23'h3c0000 :
                                 23'h5e0000;
reg clk_mem = 0;
always #5 clk_mem = ~clk_mem;
reg [1:0] clk_div = 0;
always @(posedge clk_mem) clk_div <= clk_div + 1'b1;
wire clk_core = clk_div[1];
reg resetn = 0;
reg [1:0] dot_phase = 0;
reg clkref = 0;
always @(posedge clk_core) begin
    if (!resetn) begin
        dot_phase <= 0;
        clkref <= 0;
    end else begin
        dot_phase <= dot_phase + 1'b1;
        clkref <= dot_phase == 2;
    end
end
reg [22:0] host_addr = 0;
reg [31:0] host_wdata = 0;
reg [3:0] host_wstrb = 0;
reg host_valid = 0;
reg [23:0] rom_addr = 0;
reg rom_select_n = 1;
reg [16:0] wram_addr = 0;
reg [7:0] wram_data = 0;
reg wram_select_n = 1;
reg wram_read_n = 1;
reg wram_write_n = 1;
reg [19:0] save_addr = 0;
reg save_read_n = 1;
reg save_write_n = 1;
reg [7:0] save_data = 0;
reg [14:0] vram_addr = 0;
reg [7:0] vram_data0 = 0, vram_data1 = 0;
reg vram_read_n = 1, vram_write_n = 1;
wire [31:0] dq;
wire [10:0] sdram_addr;
wire [1:0] sdram_bank;
wire [3:0] sdram_mask;
wire sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cke;
integer index;
reg [31:0] stored;
integer wram_wait_cycles;
task drive_host(input valid, input [22:0] host_address_value,
                input [31:0] data_value, input [3:0] strobes_value);
    host_valid = valid;
    host_addr = host_address_value;
    host_wdata = data_value;
    host_wstrb = strobes_value;
    force dut.rv_valid = valid;
    force dut.rv_addr = host_address_value;
    force dut.rv_wdata = data_value;
    force dut.rv_wstrb = strobes_value;
endtask
task drive_rom(input select_n, input [23:0] address_value);
    rom_select_n = select_n;
    rom_addr = address_value;
    force dut.ROM_CE_N = select_n;
    force dut.ROM_ADDR = address_value;
endtask
task drive_wram(input select_n, input read_n, input write_n,
                input [16:0] address_value, input [7:0] data_value);
    wram_select_n = select_n;
    wram_read_n = read_n;
    wram_write_n = write_n;
    wram_addr = address_value;
    wram_data = data_value;
    force dut.WRAM_CE_N = select_n;
    force dut.WRAM_RD_N = read_n;
    force dut.WRAM_WE_N = write_n;
    force dut.WRAM_ADDR = address_value;
    force dut.WRAM_D = data_value;
endtask
task drive_vram(input [14:0] address_value, input [7:0] data0,
                input [7:0] data1, input read_n, input write_n);
    vram_addr = address_value;
    vram_data0 = data0;
    vram_data1 = data1;
    vram_read_n = read_n;
    vram_write_n = write_n;
    force dut.VRAM1_ADDR = address_value;
    force dut.VRAM2_ADDR = address_value;
    force dut.VRAM1_DO = data0;
    force dut.VRAM2_DO = data1;
    force dut.VRAM1_WE_N = write_n;
    force dut.VRAM2_WE_N = write_n;
    force dut.VRAM_OE_N = read_n;
endtask

top_tang_nano20k_snes #(
    .SNES_UPSTREAM_RAM_LAYOUT(UPSTREAM_RAM_LAYOUT),
    .SNES_VIDEO_RAM_LAYOUT(VIDEO_RAM_LAYOUT),
    .SNES_WRAM_WAIT(WRAM_WAIT)
) dut (
    .sys_clk(clk_mem), .s1(1'b0), .s2(1'b0), .uart_rx(1'b1), .pad_data(1'b1), .sd_dat0(1'b1),
    .IO_sdram_dq(dq), .O_sdram_addr(sdram_addr), .O_sdram_ba(sdram_bank), .O_sdram_dqm(sdram_mask),
    .O_sdram_cs_n(sdram_cs_n), .O_sdram_ras_n(sdram_ras_n), .O_sdram_cas_n(sdram_cas_n),
    .O_sdram_wen_n(sdram_we_n), .O_sdram_cke(sdram_cke)
);
sdram_model #(.READ_HOLD_CYCLES(1)) memory (
    .DQ(dq), .A(sdram_addr), .BA(sdram_bank), .DQM(sdram_mask), .nCS(sdram_cs_n),
    .nRAS(sdram_ras_n), .nCAS(sdram_cas_n), .nWE(sdram_we_n), .CKE(sdram_cke),
    .CLK(~clk_mem), .clk(clk_mem)
);

initial begin
    force dut.mclk = clk_core;
    force dut.fclk = clk_mem;
    force dut.sys_resetn = resetn;
    force dut.dot_clk_ce = clkref;
    force dut.loading = 0;
    force dut.image_valid = 0;
    force dut.game_reset = 0;
    force dut.game_pause = 0;
    force dut.rv_valid = 0;
    force dut.rv_addr = 0;
    force dut.rv_wdata = 0;
    force dut.rv_wstrb = 0;
    force dut.ROM_CE_N = 1;
    force dut.ROM_ADDR = 0;
    force dut.ROM_WORD = 0;
    force dut.WRAM_CE_N = 1;
    force dut.WRAM_RD_N = 1;
    force dut.WRAM_WE_N = 1;
    force dut.WRAM_D = 0;
    force dut.WRAM_ADDR = 0;
    force dut.BSRAM_CE_N = save_read_n & save_write_n;
    force dut.BSRAM_RD_N = save_read_n;
    force dut.BSRAM_WE_N = save_write_n;
    force dut.BSRAM_ADDR = save_addr;
    force dut.BSRAM_D = save_data;
    force dut.ARAM_CE_N = 1;
    force dut.ARAM_OE_N = 1;
    force dut.ARAM_WE_N = 1;
    force dut.ARAM_ADDR = 0;
    force dut.VRAM1_ADDR = 0;
    force dut.VRAM1_DO = 0;
    force dut.VRAM1_WE_N = 1;
    force dut.VRAM2_ADDR = 0;
    force dut.VRAM2_DO = 0;
    force dut.VRAM2_WE_N = 1;
    force dut.VRAM_OE_N = vram_read_n;
    repeat (8) @(negedge clk_core);
    resetn = 1;
    wait(dut.sdram_busy === 0);
    repeat (8) @(negedge clk_core);

    drive_host(1, 23'h5e0000, 32'h89abcdef, 4'hf);
    wait(dut.rv_ready === 1);
    @(negedge clk_core);
    drive_host(0, 23'h5e0000, 32'h89abcdef, 4'hf);
    repeat (3) @(negedge clk_core);
    if (memory.mem[SAVE_BASE >> 2] !== 32'h89abcdef)
        $fatal(1, "Host save window physical address wrong layout=%0d", VIDEO_RAM_LAYOUT);
    drive_host(1, 23'h5e0000, 32'h0, 4'h0);
    wait(dut.rv_ready === 1);
    #1;
    if (dut.rv_rdata !== 32'h89abcdef)
        $fatal(1, "Host save readback wrong layout=%0d data=%h", VIDEO_RAM_LAYOUT, dut.rv_rdata);
    @(negedge clk_core);
    drive_host(0, 23'h5e0000, 32'h0, 4'h0);

    memory.mem[23'h002000 >> 2] = 32'h78563412;
    memory.mem[23'h002004 >> 2] = 32'h78563412;
    memory.mem[23'h002008 >> 2] = 32'h78563412;
    memory.mem[23'h00200c >> 2] = 32'h78563412;
    memory.mem[23'h002010 >> 2] = 32'h11223344;
    memory.mem[(WRAM_BASE + 23'h002000) >> 2] = 32'hfedcba98;
    memory.mem[(WRAM_BASE + 23'h002004) >> 2] = 32'hfedcba98;
    memory.mem[(WRAM_BASE + 23'h002008) >> 2] = 32'hfedcba98;
    memory.mem[(WRAM_BASE + 23'h00200c) >> 2] = 32'hfedcba98;
    for (index = 0; index < 8; index = index + 1) begin
        drive_rom(0, 24'h002000 + index);
        drive_wram(1, 1, 1, 0, 0);
        repeat (6) @(posedge clk_core);
        if (dut.ROM_Q[7:0] !== ((32'h78563412 >> ((index & 3) * 8)) & 8'hff))
            $fatal(1, "ROM read wrong layout=%0d index=%0d data=%h", VIDEO_RAM_LAYOUT, index, dut.ROM_Q[7:0]);
        drive_rom(1, 24'h002000 + index);
        drive_wram(0, 0, 1, 17'h02000 + index, 0);
        repeat (6) @(posedge clk_core);
        if (dut.wram_sd_q !== ((32'hfedcba98 >> ((index & 3) * 8)) & 8'hff))
            $fatal(1, "WRAM read wrong layout=%0d index=%0d data=%h", VIDEO_RAM_LAYOUT, index, dut.wram_sd_q);
        drive_wram(1, 1, 1, 17'h02000 + index, 0);
    end

    drive_wram(0, 1, 0, 17'h02040, 8'h5a);
    drive_rom(0, 24'h002010);
    repeat (8) @(negedge clk_core);
    drive_wram(1, 1, 1, 17'h02040, 8'h5a);
    drive_rom(1, 24'h002010);
    repeat (5) @(negedge clk_core);
    if (memory.mem[(WRAM_BASE + 23'h002040) >> 2][7:0] !== 8'h5a)
        $fatal(1, "Concurrent ROM/WRAM DMA destination lost layout=%0d", VIDEO_RAM_LAYOUT);
    if (dut.ROM_Q[7:0] !== 8'h44)
        $fatal(1, "Concurrent ROM/WRAM DMA source lost layout=%0d data=%h", VIDEO_RAM_LAYOUT, dut.ROM_Q[7:0]);

    if (!VIDEO_RAM_LAYOUT && !UPSTREAM_RAM_LAYOUT) begin
        @(negedge clk_core);
        force dut.ARAM_CE_N = 0;
        force dut.ARAM_OE_N = 0;
        force dut.ARAM_ADDR = 16'h0100;
        drive_wram(0, 0, 1, 17'h02000, 0);
        wait(dut.wram_request != dut.wram_ack);
        #1;
        wram_wait_cycles = 0;
        while (dut.wram_request != dut.wram_ack_settled && wram_wait_cycles < 16) begin
            if (WRAM_WAIT && dut.wram_wait !== 1'b1)
                $fatal(1, "WRAM wait released before the response settled");
            @(negedge clk_core);
            wram_wait_cycles = wram_wait_cycles + 1;
        end
        $display("Concurrent ARAM/WRAM: WRAM acknowledgement after %0d master clocks", wram_wait_cycles);
        repeat (2) @(negedge clk_core);
        if (dut.wram_sd_q !== 8'h98)
            $fatal(1, "WRAM read under ARAM contention returned %h", dut.wram_sd_q);
        drive_wram(1, 1, 1, 17'h02000, 0);
        force dut.ARAM_CE_N = 1;
        force dut.ARAM_OE_N = 1;
    end

    if (VIDEO_RAM_LAYOUT) begin
        save_addr = 0;
        force dut.BSRAM_CE_N = 0;
        force dut.BSRAM_RD_N = 0;
        force dut.BSRAM_WE_N = 1;
        force dut.BSRAM_ADDR = 0;
        wait(dut.bsram_req_ack == dut.bsram_req);
        repeat (4) @(negedge clk_core);
        if (dut.bsram_dout !== 8'hef)
            $fatal(1, "SNES SRAM window differs from host save mapping: %h", dut.bsram_dout);
        force dut.BSRAM_CE_N = 1;
        force dut.BSRAM_RD_N = 1;
    end

    for (index = 0; index < 4; index = index + 1) begin
        @(negedge clk_core);
        drive_vram(16'h0100 + index, 8'h40 + index, 8'h80 + index, 1, 0);
        repeat (5) @(negedge clk_core);
        drive_vram(16'h0100 + index, 8'h40 + index, 8'h80 + index, 0, 1);
        repeat (5) @(negedge clk_core);
        if (dut.VRAM1_DI !== (8'h40 + index) || dut.VRAM2_DI !== (8'h80 + index))
            $fatal(1, "VRAM readback wrong layout=%0d index=%0d data=%h/%h", VIDEO_RAM_LAYOUT, index, dut.VRAM1_DI, dut.VRAM2_DI);
    end
    if (VIDEO_RAM_LAYOUT) begin
        memory.mem[(WRAM_BASE + 23'h003000) >> 2] = 32'h89abcdef;
        drive_vram(15'h0200, 0, 0, 0, 1);
        drive_wram(0, 0, 1, 17'h03000, 0);
        wait(dut.wram_request != dut.wram_ack);
        for (index = 0; index < 128; index = index + 1) begin
            drive_vram(15'h0300 + index, 0, 0, 0, 1);
            @(negedge clk_core);
            if (dut.wram_request == dut.wram_ack)
                index = 128;
        end
        if (dut.wram_ack != dut.wram_request)
            $fatal(1, "WRAM request starved behind continuous VRAM traffic");
        repeat (3) @(negedge clk_core);
        if (dut.wram_sd_q !== 8'hef)
            $fatal(1, "WRAM data wrong during VRAM traffic: %h", dut.wram_sd_q);
        drive_wram(1, 1, 1, 17'h03000, 0);
        drive_vram(15'h0400, 0, 0, 1, 1);
    end
    $display("tb_snes_vram_stream PASSED: layout=%0d 4MiB ROM map, host SRAM, DMA and VRAM", VIDEO_RAM_LAYOUT);
    $finish;
end
initial begin
    #3000000;
    $fatal(1, "SNES memory layout test timeout");
end
endmodule

module tb_snes_port_diag;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg diagnostic_reset = 0;
reg sample_read = 0;
reg write_n = 1;
wire request;
wire [1:0] errors;
wire [7:0] writes;
wire [15:0] first_failure;
snes_vram_port #(.DIAGNOSTIC(1)) dut (
    .clk(clk), .resetn(resetn), .address(15'h123), .data(8'h5a), .read_n(1'b0),
    .write_n(write_n), .ack(1'b0), .request(request),
    .diagnostic_reset(diagnostic_reset), .sample_read(sample_read),
    .diagnostic_errors(errors), .diagnostic_writes(writes), .diagnostic_first(first_failure)
);
initial begin
    repeat (2) @(negedge clk);
    resetn = 1;
    repeat (2) @(negedge clk);
    sample_read = 1;
    @(negedge clk);
    sample_read = 0;
    if (errors !== 2'b01)
        $fatal(1, "Pending read not reported");
    if (first_failure !== {2'b10, 7'h23, 7'h23})
        $fatal(1, "First failure address/request state incorrect: %h", first_failure);
    write_n = 0;
    @(negedge clk);
    write_n = 1;
    @(negedge clk);
    write_n = 0;
    @(negedge clk);
    write_n = 1;
    if (errors !== 2'b11 || writes !== 8'd2)
        $fatal(1, "Queue overflow/write count not reported errors=%b writes=%d", errors, writes);
    diagnostic_reset = 1;
    @(negedge clk);
    if (errors !== 0 || writes !== 0 || first_failure !== 0)
        $fatal(1, "Diagnostic reset failed");
    $display("tb_snes_port_diag PASSED: read pending, write overflow, counters and reset");
    $finish;
end
endmodule
