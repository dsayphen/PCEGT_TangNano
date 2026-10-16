`timescale 1ns / 1ps
module tb_snes_iosys_memory;
reg clk = 0;
always #5 clk = ~clk;
reg resetn = 0;
reg rv_req = 0;
reg aram_req = 0;
reg [22:1] rv_addr = 0;
reg [15:0] aram_addr = 0;
reg cpu_req = 0;
reg cpu_port = 0;
reg [22:1] cpu_addr = 0;
reg bsram_req = 0;
reg [19:0] bsram_addr = 0;
reg cpu_we = 0;
reg [15:0] cpu_din = 0;
wire cpu_ack;
wire [15:0] cpu_q0, cpu_q1;
reg rv_we = 0;
reg [15:0] rv_din = 0;
wire rv_ack;
wire [15:0] rv_q;
wire bsram_ack;
wire aram_ack;
wire [7:0] bsram_q;
reg [14:0] vram_addr = 0;
reg [14:0] vram2_addr = 0;
reg vram1_req = 0, vram2_req = 0;
reg vram_we = 0;
reg [7:0] vram1_din = 0, vram2_din = 0;
wire vram1_ack, vram2_ack;
wire [7:0] vram1_q, vram2_q;
wire busy;
wire [10:0] memory_addr;
wire [1:0] memory_bank;
wire [3:0] memory_mask;
wire memory_cs, memory_ras, memory_cas, memory_we, memory_cke;
wire [31:0] dq;
sdram_snes #(.SHARED_IOSYS(1), .FREQ(1000000)) dut (
    .clk(clk), .mclk(clk), .clkref(1'b0), .resetn(resetn), .SDRAM_DQ(dq),
    .SDRAM_A(memory_addr), .SDRAM_BA(memory_bank), .SDRAM_DQM(memory_mask),
    .SDRAM_nCS(memory_cs), .SDRAM_nRAS(memory_ras), .SDRAM_nCAS(memory_cas),
    .SDRAM_nWE(memory_we), .SDRAM_CKE(memory_cke), .busy(busy),
    .cpu_din(cpu_din), .cpu_port(cpu_port), .cpu_addr(cpu_addr), .cpu_req(cpu_req),
    .cpu_we(cpu_we), .cpu_ds(2'b11), .cpu_req_ack(cpu_ack), .cpu_port0(cpu_q0), .cpu_port1(cpu_q1),
    .bsram_addr(bsram_addr), .bsram_din(8'd0), .bsram_req(bsram_req), .bsram_we(1'b0),
    .bsram_req_ack(bsram_ack), .bsram_dout(bsram_q),
    .aram_16(1'b0), .aram_addr(aram_addr), .aram_din(16'd0), .aram_req(aram_req), .aram_we(1'b0),
    .aram_req_ack(aram_ack),
    .vram1_addr(vram_addr), .vram1_din(vram1_din), .vram1_req(vram1_req), .vram1_we(vram_we),
    .vram2_addr(vram2_addr), .vram2_din(vram2_din), .vram2_req(vram2_req), .vram2_we(vram_we),
    .vram1_ack(vram1_ack), .vram2_ack(vram2_ack), .vram1_dout(vram1_q), .vram2_dout(vram2_q),
    .rv_addr(rv_addr), .rv_din(rv_din), .rv_ds(2'b11), .rv_req(rv_req), .rv_we(rv_we),
    .rv_req_ack(rv_ack), .rv_dout(rv_q)
);
sdram_model #(.READ_HOLD_CYCLES(1)) memory (
    .DQ(dq), .A(memory_addr), .BA(memory_bank), .nCS(memory_cs), .nRAS(memory_ras),
    .nCAS(memory_cas), .nWE(memory_we), .DQM(memory_mask), .CKE(memory_cke),
    .CLK(~clk), .clk(clk)
);
task cpu_transfer(input port_select, input write_enable, input [22:0] address,
                  input [15:0] value);
    @(negedge clk);
    cpu_port = port_select;
    cpu_addr = address >> 1;
    cpu_we = write_enable;
    cpu_din = value;
    cpu_req = ~cpu_req;
    wait(cpu_ack == cpu_req);
    repeat (5) @(negedge clk);
    if (!write_enable && (port_select ? cpu_q1 : cpu_q0) !== value) begin
        $fatal(1, "CPU read address=%h expected=%h got=%h", address, value, port_select ? cpu_q1 : cpu_q0);
    end
endtask
task rv_transfer(input write_enable, input [22:0] address, input [15:0] value);
    @(negedge clk);
    rv_addr = address >> 1;
    rv_we = write_enable;
    rv_din = value;
    rv_req = ~rv_req;
    wait(rv_ack == rv_req);
    repeat (5) @(negedge clk);
    if (!write_enable && rv_q !== value)
        $fatal(1, "RV read address=%h expected=%h got=%h", address, value, rv_q);
endtask
task vram_transfer(input write_enable, input [14:0] address, input [15:0] value);
    @(negedge clk);
    vram_addr = address;
    vram2_addr = address;
    vram_we = write_enable;
    {vram2_din, vram1_din} = value;
    vram1_req = ~vram1_req;
    vram2_req = ~vram2_req;
    wait(vram1_ack == vram1_req && vram2_ack == vram2_req);
    repeat (5) @(negedge clk);
    if (!write_enable && {vram2_q, vram1_q} !== value)
        $fatal(1, "VRAM read address=%h expected=%h got=%h", address, value, {vram2_q, vram1_q});
endtask
task vram_split_read(input [14:0] address1, input [14:0] address2, input [15:0] expected);
    @(negedge clk);
    vram_addr = address1;
    vram2_addr = address2;
    vram_we = 0;
    vram1_req = ~vram1_req;
    vram2_req = ~vram2_req;
    wait(vram1_ack == vram1_req && vram2_ack == vram2_req);
    repeat (5) @(negedge clk);
    if ({vram2_q, vram1_q} !== expected)
        $fatal(1, "Split VRAM read a=%h b=%h expected=%h got=%h", address1, address2, expected, {vram2_q, vram1_q});
endtask
task check_address(input [22:0] expected);
    #1;
    if (dut.next_addr[1] !== expected)
        $fatal(1, "address got=%h expected=%h", dut.next_addr[1], expected);
endtask
task check_wram_audio_contention;
    @(negedge clk);
    cpu_port = 1;
    cpu_addr = 23'h7e0000 >> 1;
    cpu_we = 0;
    cpu_req = ~cpu_req;
    aram_req = ~aram_req;
    fork
        begin : audio_stream
            repeat (8) begin
                wait(aram_ack == aram_req);
                repeat (4) @(negedge clk);
                aram_addr = aram_addr + 1'b1;
                aram_req = ~aram_req;
            end
            wait(aram_ack == aram_req);
        end
        begin : wram_progress
            repeat (128) @(negedge clk);
            if (cpu_ack != cpu_req || cpu_q1 !== 16'h1234)
                $fatal(1, "WRAM failed to complete after finite audio burst");
        end
    join
    repeat (8) @(negedge clk);
endtask
task check_audio_wram_contention;
    @(negedge clk);
    cpu_port = 1;
    cpu_addr = 23'h7e0000 >> 1;
    cpu_we = 0;
    cpu_req = ~cpu_req;
    aram_req = ~aram_req;
    fork
        begin : wram_stream
            repeat (8) begin
                wait(cpu_ack == cpu_req);
                repeat (5) @(negedge clk);
                cpu_req = ~cpu_req;
            end
            wait(cpu_ack == cpu_req);
            repeat (5) @(negedge clk);
        end
        begin : audio_deadline
            repeat (32) @(negedge clk);
            if (aram_ack != aram_req)
                $fatal(1, "Audio request starved under WRAM traffic");
        end
    join
    repeat (8) @(negedge clk);
endtask
task check_audio_fixed_slot;
    @(negedge clk);
    aram_req = ~aram_req;
    wait(aram_ack == aram_req);
    repeat (6) @(negedge clk);
    cpu_port = 1;
    cpu_addr = 23'h7e0000 >> 1;
    cpu_we = 0;
    cpu_req = ~cpu_req;
    aram_req = ~aram_req;
    #1;
    if (dut.next_port[1] != dut.PORT_ARAM)
        $fatal(1, "Audio fixed-latency slot stolen by WRAM despite pending ARAM read");
    wait(aram_ack == aram_req);
    wait(cpu_ack == cpu_req);
    repeat (8) @(negedge clk);
endtask
initial begin
    repeat (2) @(negedge clk);
    resetn = 1;
    rv_req = 1;
    rv_addr = 23'h400000 >> 1;
    check_address(23'h400000);
    rv_addr = 23'h590000 >> 1;
    check_address(23'h590000);
    rv_addr = 23'h5e1234 >> 1;
    check_address(23'h5e1234);
    rv_req = 0;
    aram_req = 1;
    aram_addr = 16'h1234;
    check_address(23'h5a1234);
    aram_req = 0;
    cpu_port = 1;
    cpu_req = 1;
    cpu_addr = 23'h7e1234 >> 1;
    check_address(23'h5c1234);
    cpu_req = 0;
    bsram_req = 1;
    bsram_addr = 20'h01234;
    check_address(23'h5e1234);
    bsram_req = 0;
    cpu_port = 0;
    cpu_req = 1;
    cpu_addr = 23'h3ffffe >> 1;
    #1;
    if (dut.next_addr[0] !== 23'h3ffffe)
        $fatal(1, "Last ROM word is not addressable without RAM alias");
    @(negedge clk);
    dut.normal = 1;
    dut.setup = 0;
    dut.cycle = 17'd1;
    cpu_req = 1;
    cpu_port = 0;
    cpu_addr = 0;
    force dq = 32'h456789ab;
    @(posedge clk);
    repeat (2) @(posedge clk);
    #1 cpu_port = 1;
    repeat (3) @(posedge clk);
    #1;
    if (dut.cpu_port0 !== 16'h89ab)
        $fatal(1, "ROM response followed live CPU selector instead of accepted transaction");
    release dq;
    @(negedge clk);
    resetn = 0;
    cpu_req = 0;
    rv_req = 0;
    aram_req = 0;
    bsram_req = 0;
    repeat (3) @(negedge clk);
    resetn = 1;
    wait(!busy);
    cpu_transfer(0, 1, 23'h3ffffe, 16'hcafe);
    cpu_transfer(1, 1, 23'h7e0000, 16'h1234);
    cpu_transfer(1, 1, 23'h7ffffe, 16'h5678);
    rv_transfer(1, 23'h5e0000, 16'h9abc);
    rv_transfer(1, 23'h5ffffe, 16'hdef0);
    cpu_transfer(0, 0, 23'h3ffffe, 16'hcafe);
    cpu_transfer(1, 0, 23'h7e0000, 16'h1234);
    cpu_transfer(1, 0, 23'h7ffffe, 16'h5678);
    rv_transfer(0, 23'h5e0000, 16'h9abc);
    rv_transfer(0, 23'h5ffffe, 16'hdef0);
    @(negedge clk);
    bsram_addr = 0;
    bsram_req = ~bsram_req;
    wait(bsram_ack == bsram_req);
    repeat (5) @(negedge clk);
    if (bsram_q !== 8'hbc)
        $fatal(1, "SRAM firmware/core views differ");
    check_audio_fixed_slot();
    check_wram_audio_contention();
    check_audio_wram_contention();
    vram_transfer(1, 15'h0000, 16'h3210);
    vram_transfer(1, 15'h0001, 16'h7654);
    vram_transfer(1, 15'h7fff, 16'hfedc);
    vram_transfer(0, 15'h0000, 16'h3210);
    vram_transfer(0, 15'h0001, 16'h7654);
    vram_transfer(0, 15'h7fff, 16'hfedc);
    vram_split_read(15'h0000, 15'h0001, 16'h7610);
    vram_split_read(15'h7fff, 15'h0000, 16'h32dc);
    $display("tb_snes_iosys_memory PASSED: firmware, stack, BSRAM and ARAM mapping");
    $finish;
end
initial begin
    #2000000;
    $fatal(1, "SNES memory transaction timeout");
end
endmodule